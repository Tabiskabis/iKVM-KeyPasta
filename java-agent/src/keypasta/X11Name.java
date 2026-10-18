package keypasta;

import java.awt.Toolkit;
import java.lang.reflect.Field;

/**
 * Linux: the window class (WM_CLASS) of IPMIView's and the viewer's windows, by which a desktop
 * (GNOME, KDE, ...) ties windows to their launcher (StartupWMClass in linux/IPMIView.desktop):
 * name and icon in the dock, the windows grouped. Java takes it from the class at the bottom of
 * the stack that created its window toolkit (XToolkit.awtAppClassName): IPMIView's launcher gave
 * "com-zerog-lax-LAX", the agent's own thread "java-lang-Thread". Set to "IPMIView" and
 * "iKVM-Viewer" right after the toolkit exists, from a thread of its own started when the main
 * class loads, before the program shows a window (it's read when a window is created).
 */
final class X11Name {
    private X11Name() {
    }

    static void start(final String name) {
        if (!Config.LINUX)
            return;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                set(name);
            }
        }, "iKVM-KeyPasta window class");
        t.setDaemon(true);
        t.start();
    }

    private static void set(String name) {
        try {
            Toolkit toolkit = Toolkit.getDefaultToolkit();
            if (!toolkit.getClass().getName().equals("sun.awt.X11.XToolkit"))
                return;
            Agent.openDesktop("sun.awt.X11");
            Field f = toolkit.getClass().getDeclaredField("awtAppClassName");
            f.setAccessible(true);
            Object before = f.get(null);
            f.set(null, name);
            Log.d("window class " + name + " (was " + before + ")");
        } catch (Throwable t) {
            Log.d("window class unchanged: " + t);
        }
    }
}
