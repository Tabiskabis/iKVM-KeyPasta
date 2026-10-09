package keypasta;

import java.awt.EventQueue;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;
import java.security.ProtectionDomain;
import java.util.Collections;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Java agent for the Supermicro/ATEN iKVM Java viewer, loaded into every Java program through
 * JAVA_TOOL_OPTIONS=-javaagent:...: does nothing until the viewer's key handling class
 * (tw.com.aten.ikvm.ui.RemoteVideo) is loaded, then installs KeyFix. Changes no class.
 *
 * Java Web Start (.jnlp from the BMC's web interface: OpenWebStart, IcedTea-Web, Oracle javaws)
 * runs the viewer under a security manager, which gives code from the class path no permissions
 * (no clipboard, no window events, no reflection, no log file), installed before premain on
 * IcedTea-Web. So the manifest puts the jar on the bootstrap class path (Boot-Class-Path, by its
 * file name: renamed, the agent works only without a security manager): all agent classes load
 * from there, with all permissions like the JDK's, and Privileged keeps less privileged callers
 * from mattering.
 */
public final class Agent {
    private Agent() {
    }

    static final String VIEWER_CLASS = "tw.com.aten.ikvm.ui.RemoteVideo";
    private static final AtomicBoolean STARTED = new AtomicBoolean();
    private static Config config;
    private static Instrumentation instrumentation;

    public static void premain(String args, Instrumentation inst) {
        start(args, inst);
    }

    public static void agentmain(String args, Instrumentation inst) {
        start(args, inst);
    }

    /** Never throws: an exception from premain stops the JVM, with whatever program it was. */
    private static void start(String args, Instrumentation inst) {
        try {
            startUnchecked(args, inst);
        } catch (Throwable t) {
            System.err.println("iKVM-KeyPasta agent not started: " + t);
        }
    }

    private static void startUnchecked(String args, Instrumentation inst) {
        config = Config.parse(args);
        Log.path = config.log;
        instrumentation = inst;
        inst.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
                                    ProtectionDomain domain, byte[] bytes) {
                if ("tw/com/aten/ikvm/ui/RemoteVideo".equals(name))
                    install();
                return null;    // nothing changed
            }
        });
        for (Class<?> c : inst.getAllLoadedClasses())
            if (c.getName().equals(VIEWER_CLASS))
                install();
    }

    /**
     * Once, outside the class loading that triggered it, on the event dispatch thread. Nothing of
     * AWT is touched before: other programs (some without AWT at all) never get that far.
     */
    private static void install() {
        if (STARTED.getAndSet(true))
            return;
        Privileged.run(new Runnable() {     // the viewer's class loading code is on the stack
            @Override
            public void run() {
                startInstallThread();
            }
        });
    }

    private static void startInstallThread() {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                openKeyEvent(instrumentation);
                EventQueue.invokeLater(new Runnable() {
                    @Override
                    public void run() {
                        Privileged.run(new Runnable() {
                            @Override
                            public void run() {
                                KeyFix.install(config);
                            }
                        });
                    }
                });
            }
        }, "iKVM-KeyPasta");
        t.setDaemon(true);
        t.start();
    }

    /**
     * Java 9+: the key position lives in private fields of java.awt.event.KeyEvent (scancode on
     * Windows, rawCode on Linux), so open that package to this agent. Java 8 needs nothing.
     */
    @SuppressWarnings({"unchecked", "rawtypes"})
    private static void openKeyEvent(Instrumentation inst) {
        try {
            Method getModule = Class.class.getMethod("getModule");
            Object desktop = getModule.invoke(java.awt.event.KeyEvent.class);
            Object self = getModule.invoke(Agent.class);
            Class<?> moduleClass = Class.forName("java.lang.Module");
            Method redefine = Instrumentation.class.getMethod("redefineModule", moduleClass, Set.class,
                Map.class, Map.class, Set.class, Map.class);
            Map opens = Collections.singletonMap("java.awt.event", Collections.singleton(self));
            redefine.invoke(inst, desktop, Collections.emptySet(), Collections.emptyMap(), opens,
                Collections.emptySet(), Collections.emptyMap());
        } catch (NoSuchMethodException e) {
            // Java 8
        } catch (Exception e) {
            Log.d("opening java.awt.event failed: " + e);
        }
    }
}
