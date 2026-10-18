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
 * (tw.com.aten.ikvm.ui.RemoteVideo) is loaded, then installs KeyFix and patches that class (Patch).
 * macOS: IPMIView's Dock icon and font when IPMIView's main class loads (Icons, Fonts); the viewer's own stunnel
 * from a fixed place (Spawn).
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
        // macOS: the menu bar of every window (the viewers', IPMIView's) in the Mac's menu bar
        if (Config.MAC && System.getProperty("apple.laf.useScreenMenuBar") == null)
            System.setProperty("apple.laf.useScreenMenuBar", "true");
        // Linux: text antialiased (Java takes it from the desktop's settings; with none, e.g. WSLg,
        // it drew without: IPMIView's PMingLiU as jagged bitmaps). Not if set otherwise.
        if (Config.LINUX && System.getProperty("awt.useSystemAAFontSettings") == null)
            System.setProperty("awt.useSystemAAFontSettings", "on");
        if (Config.LINUX && System.getProperty("swing.aatext") == null)
            System.setProperty("swing.aatext", "true");
        String program = System.getProperty("sun.java.command", "").trim().split("\\s+")[0];
        Log.d("agent started in " + program.substring(Math.max(program.lastIndexOf('/'), program.lastIndexOf('\\')) + 1));
        if (Config.MAC && openDesktopForMacKeys(inst))
            MacKeys.prepare();
        inst.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String name, Class<?> redefined,
                                    ProtectionDomain domain, byte[] bytes) {
                if (Icons.IPMIVIEW_MAIN.equals(name)) {
                    Privileged.run(new Runnable() {     // IPMIView's class loading is on the stack
                        @Override
                        public void run() {
                            X11Name.start("IPMIView");          // Linux: the desktop launcher's windows
                            Icons.ipmiviewDock();
                            try {
                                StunnelNote.install();
                            } catch (Throwable t) {
                                Log.d("stunnel note not installed: " + t);
                            }
                            try {
                                Widen.install();
                            } catch (Throwable t) {
                                Log.d("widen not installed: " + t);
                            }
                        }
                    });
                    byte[] out = Config.MAC || Config.LINUX ? Patch.redirectFonts(bytes) : null;   // its font (see Fonts)
                    byte[] quit = Patch.redirectQuit(out != null ? out : bytes);    // no quit question (see Quit)
                    if (quit != null)
                        out = quit;
                    byte[] delete = Patch.redirectDeviceDelete(out != null ? out : bytes);   // its account too (IPMIViewLogin)
                    return delete != null ? delete : out;
                }
                if ("IPMIView20/iKVMLunchar".equals(name)) {
                    // timed (see LaunchTiming); the viewer's settings not in a file (see KvmSettings)
                    byte[] out = Patch.redirectLaunch(bytes, name);
                    byte[] renamed = Patch.renameClass(out != null ? out : bytes, "java/io/FileWriter", "keypasta/KvmSettings$Writer");
                    return renamed != null ? renamed : out;
                }
                if (LOCAL_HOST_USERS.contains(name))
                    return Patch.redirectLocalHost(bytes);      // loopback instead of the own address lookup (see LocalHost)
                if ("IPMIView20/IPMISession".equals(name))
                    return Patch.redirectSensorsTab(bytes);     // sensors in the text view (see IPMIViewLogin)
                if ("com/supermicro/ipmi/stunnel/StunnelUtility".equals(name))
                    return Patch.redirectLaunch(bytes, name);  // timed, the stunnel wait shortened (see LaunchTiming)
                if (Config.MAC && MacKeys.ready() && ("sun/lwawt/macosx/CPlatformResponder".equals(name)
                        || "sun/lwawt/LWWindowPeer".equals(name)))
                    return Patch.redirectMacKeys(bytes, name);  // the physical key (see MacKeys)
                if (name == null || !name.startsWith("tw/com/aten/"))
                    return null;    // nothing changed
                byte[] out = null;
                ViewerStart.loading(name);                  // milestones of its start (log)
                if ("tw/com/aten/ikvm/KVMMain".equals(name)) {
                    X11Name.start("iKVM-Viewer");               // Linux: its window class (see X11Name)
                    out = Patch.redirectViewerStart(bytes);   // no 5 s pause (see ViewerStart)
                    if (KvmSettings.fromStdin()) {            // its settings from IPMIView, not a file (see KvmSettings)
                        byte[] checks = Patch.redirectKvmSettings(out != null ? out : bytes);
                        if (checks != null)
                            out = checks;
                        byte[] renamed = Patch.renameClass(out != null ? out : bytes, "java/io/FileReader", "keypasta/KvmSettings$Reader");
                        if (renamed != null)
                            out = renamed;
                    }
                }
                if ("tw/com/aten/ikvm/ui/RemoteVideo".equals(name)) {
                    install();
                    out = Patch.noAlwaysOnTop(bytes);            // stop the viewer forcing itself on top
                    byte[] layout = Patch.redirectKbLayout(out != null ? out : bytes);   // see ViewerLayout
                    if (layout != null)
                        out = layout;
                    MouseRate.rate = config.mouseRate;
                    if (config.mouseRate > 0) {
                        // moves sent at most mouseRate= a second (see MouseRate)
                        byte[] mouse = Patch.redirectMouse(out != null ? out : bytes);
                        if (mouse != null)
                            out = mouse;
                    }
                    if (Config.MAC || Config.LINUX) {
                        // macOS: its LED code quits the viewer without Input Monitoring; Linux: its
                        // LED sync types lock keys locally, which reached the remote (see Native)
                        if (Config.MAC) {
                            Native.ledFallback = !config.macLedNative;
                            Log.d("macOS keyboard LEDs: " + (config.macLedNative ? "native" : "fallback"));
                        }
                        byte[] redirected = Patch.redirectNatives(out != null ? out : bytes);
                        if (redirected != null)
                            out = redirected;
                    }
                }
                if (WaylandFrames.needed()) {
                    // Wayland/WSL: windows stay resizable (see WaylandFrames)
                    byte[] redirected = Patch.redirectResizable(out != null ? out : bytes);
                    if (redirected != null)
                        out = redirected;
                }
                {
                    // no switching of the local input method (see InputSwitch)
                    byte[] redirected = Patch.redirectInputSwitch(out != null ? out : bytes);
                    if (redirected != null)
                        out = redirected;
                }
                if (Config.MAC) {
                    // its own stunnel from a fixed place (see Spawn)
                    byte[] redirected = Patch.redirectSpawn(out != null ? out : bytes);
                    if (redirected != null)
                        out = redirected;
                }
                return out;
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
     * Java 9+: a package of java.desktop exported to this agent, e.g. com.apple.laf for FlatTabs.
     * Java 8: nothing to do (true).
     */
    @SuppressWarnings({"unchecked", "rawtypes"})
    static boolean exportDesktop(String pkg) {
        try {
            Method getModule = Class.class.getMethod("getModule");
            Object desktop = getModule.invoke(java.awt.Component.class);
            Object self = getModule.invoke(Agent.class);
            Class<?> moduleClass = Class.forName("java.lang.Module");
            Method redefine = Instrumentation.class.getMethod("redefineModule", moduleClass, Set.class,
                Map.class, Map.class, Set.class, Map.class);
            Map exports = Collections.singletonMap(pkg, Collections.singleton(self));
            redefine.invoke(instrumentation, desktop, Collections.emptySet(), exports, Collections.emptyMap(),
                Collections.emptySet(), Collections.emptyMap());
            return true;
        } catch (NoSuchMethodException e) {
            return true;                                   // Java 8
        } catch (Exception e) {
            Log.d("exporting " + pkg + " failed: " + e);
            return false;
        }
    }

    /**
     * Java 9+: the key position lives in private fields of java.awt.event.KeyEvent (scancode on
     * Windows, rawCode on Linux), so open that package to this agent. Java 8 needs nothing.
     */
    @SuppressWarnings({"unchecked", "rawtypes"})
    /**
     * macOS, before AWT loads: java.desktop reads the agent's module (its patched classes call
     * MacKeys) and opens sun.lwawt.macosx to it (MacKeys calls NSEvent's natives). Java 8: no
     * modules, nothing to do.
     */
    /** IPMIView's classes that look up the own address for every connection or packet but don't need it (see LocalHost). */
    private static final java.util.Set<String> LOCAL_HOST_USERS = new java.util.HashSet<String>(java.util.Arrays.asList(
        "IPMIView20/UDPSocket", "IPMIView20/SOLUDPSocket20", "IPMIView20/UOLUDPHandler", "com/supermicro/ipmi/UDPSocket"));

    private static boolean openDesktopForMacKeys(Instrumentation inst) {
        try {
            Method getModule = Class.class.getMethod("getModule");
            Object desktop = getModule.invoke(java.awt.Component.class);
            Object self = getModule.invoke(Agent.class);
            Class<?> moduleClass = Class.forName("java.lang.Module");
            Method redefine = Instrumentation.class.getMethod("redefineModule", moduleClass, Set.class,
                Map.class, Map.class, Set.class, Map.class);
            Map<String, Set<Object>> opens = new java.util.HashMap<String, Set<Object>>();
            opens.put("sun.lwawt.macosx", Collections.singleton(self));
            opens.put("java.awt.event", Collections.singleton(self));   // MacKeys sets KeyEvent's fields
            opens.put("java.awt", Collections.singleton(self));         // ViewerWatch: Window.modalBlocker, peer
            opens.put("java.awt.peer", Collections.singleton(self));    // ViewerWatch: WindowPeer.setModalBlocked
            opens.put("sun.lwawt", Collections.singleton(self));        // ViewerWatch: LWWindowPeer's state
            redefine.invoke(inst, desktop, Collections.singleton(self), Collections.emptyMap(), opens,
                Collections.emptySet(), Collections.emptyMap());
            return true;
        } catch (NoSuchMethodException e) {
            return true;                                   // Java 8
        } catch (Exception e) {
            Log.d("macOS physical keys: module access failed: " + e);
            return false;
        }
    }

    /** Java 9+: a package of java.desktop opened to this agent (private members by reflection). */
    static void openDesktop(String pkg) {
        try {
            Method getModule = Class.class.getMethod("getModule");
            Object desktop = getModule.invoke(java.awt.Component.class);
            Object self = getModule.invoke(Agent.class);
            Class<?> moduleClass = Class.forName("java.lang.Module");
            Method redefine = Instrumentation.class.getMethod("redefineModule", moduleClass, Set.class,
                Map.class, Map.class, Set.class, Map.class);
            Map opens = Collections.singletonMap(pkg, Collections.singleton(self));
            redefine.invoke(instrumentation, desktop, Collections.emptySet(), Collections.emptyMap(), opens,
                Collections.emptySet(), Collections.emptyMap());
        } catch (NoSuchMethodException e) {
            // Java 8
        } catch (Exception e) {
            Log.d("opening " + pkg + " failed: " + e);
        }
    }

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
