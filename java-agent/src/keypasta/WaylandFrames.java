package keypasta;

import java.awt.AWTEvent;
import java.awt.Dialog;
import java.awt.Frame;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.AWTEventListener;
import java.awt.event.WindowEvent;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;

/**
 * Linux under Wayland (WSLg included: its window manager is Weston's): no window is made
 * non-resizable. Under Weston, a window Java makes non-resizable (fixed size hints) keeps the
 * size its frame had (window manager frame insets 59/38/38/38 included) and Java loses track of
 * where it is: the viewer showed wide empty margins right and below the video, its menus opened
 * at the window's first position and clicks landed off, and every resize moved the window back
 * there. The viewer does it all the time (setResizable(true), pack, setResizable(false) on each
 * new resolution). Reproduced under weston --backend=headless --xwayland: non-resizable after
 * pack: shell window stuck at its old size, Java's location off by the frame; left resizable:
 * shell = content, Java's location right. Making it resizable again right after (property
 * listener) was too late: the short fixed-size moment was enough to keep the old size. So the
 * viewer's own setResizable calls (Patch.redirectResizable, all tw/com/aten classes) land in
 * setResizable here, which passes false on as true; and as a fallback for other windows, every
 * Frame and Dialog that becomes non-resizable (property "resizable", or already so when it opens)
 * is made resizable again.
 */
public final class WaylandFrames {
    private static boolean installed;
    private static boolean logged;

    private WaylandFrames() {
    }

    /** The viewer's setResizable calls (any receiver type: Frame, Dialog, their subclasses). */
    public static void setResizable(Object window, boolean resizable) {
        if (!resizable && needed()) {
            if (!logged) {
                logged = true;
                Log.d("Wayland/WSL: " + window.getClass().getName() + " kept resizable");
            }
            resizable = true;
        }
        if (window instanceof Frame)
            ((Frame) window).setResizable(resizable);
        else if (window instanceof Dialog)
            ((Dialog) window).setResizable(resizable);
    }

    private static Boolean needed;

    /** Linux with Wayland (WAYLAND_DISPLAY) or WSL. */
    static boolean needed() {
        if (needed == null) {
            boolean n = false;
            try {
                n = Config.LINUX && (System.getenv("WAYLAND_DISPLAY") != null || System.getenv("WSL_DISTRO_NAME") != null
                    || System.getenv("WSL_INTEROP") != null || ViewerWatch.TAB);   // a tab's window must stay maximizable
            } catch (SecurityException e) {
                n = false;
            }
            needed = n;
        }
        return needed;
    }

    /** On the event dispatch thread. */
    static synchronized void install() {
        if (installed || !needed())
            return;
        installed = true;
        final PropertyChangeListener resizable = new PropertyChangeListener() {
            @Override
            public void propertyChange(PropertyChangeEvent e) {
                if (Boolean.FALSE.equals(e.getNewValue()))
                    resizable((Window) e.getSource());
            }
        };
        Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
            @Override
            public void eventDispatched(AWTEvent event) {
                if (event.getID() != WindowEvent.WINDOW_OPENED)
                    return;
                Window w = ((WindowEvent) event).getWindow();
                if (!(w instanceof Frame) && !(w instanceof Dialog))
                    return;
                w.removePropertyChangeListener("resizable", resizable);
                w.addPropertyChangeListener("resizable", resizable);
                resizable(w);
            }
        }, AWTEvent.WINDOW_EVENT_MASK);
        for (Window w : Window.getWindows())
            if (w instanceof Frame || w instanceof Dialog) {
                w.addPropertyChangeListener("resizable", resizable);
                resizable(w);
            }
        Log.d("Wayland/WSL: windows stay resizable (fixed-size windows lose their size and position there)");
    }

    private static void resizable(Window w) {
        if (w instanceof Frame && !((Frame) w).isResizable())
            ((Frame) w).setResizable(true);
        else if (w instanceof Dialog && !((Dialog) w).isResizable())
            ((Dialog) w).setResizable(true);
        else
            return;
        if (!logged) {
            logged = true;
            Log.d("Wayland/WSL: " + w.getClass().getName() + " made resizable again");
        }
    }
}
