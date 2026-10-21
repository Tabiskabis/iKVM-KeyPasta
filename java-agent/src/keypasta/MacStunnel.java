package keypasta;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.Set;
import java.util.WeakHashMap;

/**
 * macOS: IPMIView's encrypted KVM console. IPMIView has the Mac code for it (MACStunnel: stunnel
 * and stunnel.conf from BMCSecurity/mac/, which ipmiview-keypasta.sh provides), but its
 * StunnelFacotry.createStunnel refuses on macOS: "The function can't support on mac".
 * StunnelUtility's call of it goes to com.supermicro.ipmi.stunnel.KeyPastaStunnel instead
 * (Patch.redirectStunnel), which tries IPMIView's own first and only replaces that refusal (see
 * there). That class has to be IPMIView's class loader's (it returns IPMIView's BaseStunnel, which
 * the agent's own classes, on the boot class path, can't name): defined there from the jar's
 * KeyPastaStunnel.bin, when StunnelUtility loads.
 */
public final class MacStunnel {
    private static final String HOOK = "com.supermicro.ipmi.stunnel.KeyPastaStunnel";
    private static final Set<ClassLoader> defined = Collections.newSetFromMap(new WeakHashMap<ClassLoader, Boolean>());

    private MacStunnel() {
    }

    /** The hook class in IPMIView's class loader. False: not there (the redirect is left out). */
    static synchronized boolean define(ClassLoader loader) {
        if (loader == null)
            return false;
        if (defined.contains(loader))
            return true;
        try {
            InputStream in = MacStunnel.class.getResourceAsStream("KeyPastaStunnel.bin");
            if (in == null)
                throw new IllegalStateException("KeyPastaStunnel.bin missing in the jar");
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try {
                byte[] buf = new byte[4096];
                for (int n; (n = in.read(buf)) > 0; )
                    out.write(buf, 0, n);
            } finally {
                in.close();
            }
            byte[] b = out.toByteArray();
            Agent.openBase("java.lang");            // Java 9+: ClassLoader.defineClass by reflection
            Method m = ClassLoader.class.getDeclaredMethod("defineClass", String.class, byte[].class, int.class, int.class);
            m.setAccessible(true);
            m.invoke(loader, HOOK, b, 0, b.length);
            defined.add(loader);
            return true;
        } catch (Throwable t) {
            Log.d("macOS encrypted console: hook not defined: " + t);
            return false;
        }
    }

    /** For KeyPastaStunnel (IPMIView's class loader): a line in the log. */
    public static void note(String text) {
        Log.d(text);
    }
}
