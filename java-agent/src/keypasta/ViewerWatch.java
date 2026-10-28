package keypasta;

import java.awt.Component;
import java.awt.Dialog;
import java.awt.GraphicsEnvironment;
import java.awt.KeyboardFocusManager;
import java.awt.Window;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * Twice a second, for each showing window: KeyFix.widenPreferences. For each showing viewer window:
 * - New remote resolution: the .jnlp viewer resizes its window to it only if the window is active
 *   (RemoteVideo: resolChange, done in Viewer.focusGained); a window in the background stayed
 *   at 320x240 until it was activated. Done here right away, as the viewer would (pack).
 * - A window with auto-resize on (then not resizable) bigger than its content needs: packed again
 *   (Linux under WSLg: wide empty margins right and below the video; cause unknown, see the log).
 *   At most twice per size, in case the window manager keeps it from shrinking. Logged once per
 *   window when the window is much bigger than the video: sizes, insets, resizable.
 * - macOS: the window state, logged whenever it changes: focused/active, the focus owner (class
 *   only), Java's modal blocker (Window.modalBlocker), the native peer's (LWWindowPeer.blocker),
 *   the peer's skipNextFocusChange.
 * - macOS: the viewer's app in front but none of its windows focused (after the launch, after
 *   Preferences closed, after Record's dialogs): keys went nowhere and the Mac menu bar was grey,
 *   until the mouse moved over the viewer or the app was switched. See focusWhenNoneIs. (macOS
 *   rejects focus requests while the app isn't in front: CPlatformWindow.rejectFocusRequest.)
 *   Redrawing the Mac menu bar when its menus change is MacMenuBar.watch's, natively.
 */
final class ViewerWatch {
    /**
     * The Mac app's container with "Open iKVM Viewer windows in separate browser tabs": the
     * viewer runs on a desktop of its own, shown in a browser tab, its window maximized without a
     * frame (openbox). Set by the container's start script (KEYPASTA_VIEWER_TAB=1). The viewer
     * resizes its window itself (on connecting, on every new resolution: setSize, pack), which
     * undid the maximizing: a viewer window that isn't maximized is maximized again, its windows
     * stay resizable (WaylandFrames.needed, else they couldn't be maximized), and the size fixes
     * (resize, refit, placeholder) are off.
     */
    static final boolean TAB = tabMode();

    private static boolean tabMode() {
        try {
            return Config.LINUX && "1".equals(System.getenv("KEYPASTA_VIEWER_TAB"));
        } catch (SecurityException e) {
            return false;
        }
    }

    private static Field modalBlocker, peerField, peerBlocker, skipNextFocusChange;
    private static boolean quitShortcutGone;
    private static final Map<Window, String> lastState = new WeakHashMap<Window, String>();

    private ViewerWatch() {
    }

    static void install(final boolean mac) {
        if (mac) {
            macFields();
            MacMenuBar.watch();
        }
        javax.swing.Timer t = new javax.swing.Timer(500, new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                for (Window w : Window.getWindows()) {
                    try {
                        KeyFix.widenPreferences(w);
                        if (!w.isShowing() || !KeyFix.isViewerWindow(w))
                            continue;
                        timing(w);
                        if (mac && !quitShortcutGone) {
                            quitShortcutGone = true;
                            MacMenuBar.noQuitShortcut();
                        }
                        if (TAB) {
                            keepMaximized(w);
                        } else {
                            resize(w);
                            refit(w);
                        }
                        if (modalBlocker != null)
                            modalState(w);
                        if (mac)
                            focusWhenNoneIs(w, "viewer");
                    } catch (Throwable ex) {
                        Log.d("viewer watch failed: " + ex);
                    }
                }
            }
        });
        t.start();
    }

    private static void resize(Window w) throws Exception {
        Component v = KeyFix.viewerOfWindow(w);
        if (v == null)
            return;
        Field f;
        try {
            f = v.getClass().getField("resolChange");
        } catch (NoSuchFieldException e) {
            return;                                 // a viewer that resizes right away
        }
        if (!f.getBoolean(v))
            return;
        Method adjust = v.getClass().getMethod("isAdjustSize");
        if (!(Boolean) adjust.invoke(v))
            return;
        boolean resizable = ((java.awt.Frame) w).isResizable();
        ((java.awt.Frame) w).setResizable(true);
        w.pack();
        ((java.awt.Frame) w).setResizable(resizable);
        f.setBoolean(v, false);
        Log.d("viewer window resized to the new remote resolution in the background: " + w.getWidth() + "x" + w.getHeight());
    }

    private static void modalState(Window w) throws Exception {
        Dialog javaBlocker = (Dialog) modalBlocker.get(w);
        Object peer = peerField.get(w);
        Object nativeBlocker = null;
        Object skip = null;
        if (peer != null) {
            if (peerBlocker == null) {
                try {
                    peerBlocker = peer.getClass().getDeclaredField("blocker");
                    peerBlocker.setAccessible(true);
                    skipNextFocusChange = peer.getClass().getDeclaredField("skipNextFocusChange");
                    skipNextFocusChange.setAccessible(true);
                } catch (Throwable t) {
                    Log.d("viewer watch: no peer state: " + t);
                    modalBlocker = null;
                    return;
                }
            }
            nativeBlocker = peerBlocker.get(peer);
            skip = skipNextFocusChange.get(peer);
        }
        Component owner = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
        String state = "focused=" + w.isFocused() + " active=" + w.isActive()
            + " focusOwner=" + (owner == null ? "-" : owner.getClass().getSimpleName() + inWindow(owner, w))
            + " javaBlocker=" + (javaBlocker == null ? "-" : javaBlocker.getClass().getSimpleName() + "/" + javaBlocker.isVisible())
            + " peerBlocker=" + (nativeBlocker == null ? "-" : "set") + " skipFocusChange=" + skip;
        if (!state.equals(lastState.put(w, state)))
            Log.d("viewer window state: " + state);
    }

    private static void macFields() {
        try {
            modalBlocker = Window.class.getDeclaredField("modalBlocker");
            modalBlocker.setAccessible(true);
            peerField = Component.class.getDeclaredField("peer");
            peerField.setAccessible(true);
        } catch (Throwable t) {
            Log.d("viewer watch: no modal state: " + t);
            modalBlocker = null;
        }
    }

    /**
     * macOS, IPMIView's own process: its menus were missing from the Mac menu bar after it started
     * (the app menu only), as the viewer's after its launch. The menu bar is watched (MacMenuBar),
     * and its main window (a showing frame with a menu bar, not a viewer's) gets the viewer's
     * focusWhenNoneIs every 500 ms. Event dispatch thread.
     */
    static void installIpmiview() {
        macFields();
        MacMenuBar.watch();
        javax.swing.Timer t = new javax.swing.Timer(500, new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                for (Window w : Window.getWindows()) {
                    try {
                        if (!w.isShowing() || !(w instanceof java.awt.Frame) || KeyFix.isViewerWindow(w)
                            || ((java.awt.Frame) w).getMenuBar() == null)
                            continue;
                        focusWhenNoneIs(w, "IPMIView");
                    } catch (Throwable ex) {
                        Log.d("IPMIView watch failed: " + ex);
                    }
                }
            }
        });
        t.start();
    }

    /** " in <class>" when c is in another window than w (the focus owner in a dialog, say). */
    private static String inWindow(Component c, Window w) {
        Window cw = c instanceof Window ? (Window) c : javax.swing.SwingUtilities.getWindowAncestor(c);
        return cw == w ? "" : " in " + (cw == null ? "-" : cw.getClass().getName());
    }

    private static Method applicationActive;
    private static boolean focusOff;
    private static String lastFocusNote;
    private static int focusTries;

    /**
     * macOS: the viewer's app in front, none of its windows focused (after the launch, after
     * Preferences, after Record's dialogs: focused=false active=false focusOwner=- with no blocker
     * left, until another app was activated and this one again). requestFocus first; if the window
     * still isn't focused a second later and macOS has it as its key window (after Record's
     * dialogs it does), the activation Java dropped is delivered (deliverFocus), and once focused
     * its menus are rebuilt (afterFocusBack: they were grey). Why it holds back or what it did is
     * logged when that changes.
     */
    private static void focusWhenNoneIs(Window w, String who) throws Exception {
        if (w.isFocused() || KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusedWindow() != null) {
            focusTries = 0;
            focusNote(null);
            return;
        }
        for (Window other : Window.getWindows())
            if (other != w && other.isShowing() && (other instanceof java.awt.Frame || other instanceof Dialog)) {
                focusTries = 0;
                focusNote(who + " not focused: another window is showing (" + other.getClass().getName() + ")");
                return;
            }
        if (focusOff)
            return;
        try {
            if (applicationActive == null) {
                applicationActive = java.awt.Toolkit.getDefaultToolkit().getClass().getDeclaredMethod("isApplicationActive");
                applicationActive.setAccessible(true);
            }
            if (!(Boolean) applicationActive.invoke(java.awt.Toolkit.getDefaultToolkit())) {
                focusTries = 0;
                focusNote(who + " not focused: its app isn't in front");
                return;
            }
        } catch (Throwable t) {
            focusOff = true;
            Log.d(who + " focus watch off: " + t);
            return;
        }
        Component v = KeyFix.viewerOfWindow(w);
        focusTries++;
        if (focusTries == 1) {
            (v != null ? v : w).requestFocus();
            focusNote(who + " focused: its app was in front with no window focused (requestFocus)");
        } else if (focusTries == 3) {                                 // after a second
            String key = nativeKey(w);
            if ("true".equals(key) && deliverFocus(w)) {
                focusNote(who + " still not focused, but macOS has it as key window: activation delivered to Java");
                afterFocusBack(w, who);
            } else {
                focusNote(who + " still not focused (macOS has it as key window? " + key + ")");
            }
        }
    }

    /**
     * What macOS's windowDidBecomeKey does on the Java side (CPlatformWindow.deliverWindowFocusEvent,
     * private): after Record's dialogs macOS made the viewer key while Java still had it blocked
     * by the closing dialog, Java dropped that activation, and no other came (it stayed key).
     */
    private static boolean deliverFocus(Window w) {
        try {
            Object peer = peerField.get(w);
            Object platform = peer.getClass().getMethod("getPlatformWindow").invoke(peer);
            Method m = null;
            for (Class<?> c = platform.getClass(); c != null && m == null; c = c.getSuperclass())
                for (Method d : c.getDeclaredMethods())
                    if (d.getName().equals("deliverWindowFocusEvent") && d.getParameterCount() == 2)
                        m = d;
            if (m == null)
                throw new NoSuchMethodException("deliverWindowFocusEvent");
            m.setAccessible(true);
            m.invoke(platform, true, null);
            return true;
        } catch (Throwable t) {
            Log.d("viewer activation not delivered: " + t);
            return false;
        }
    }

    /**
     * Once the viewer has the focus again (100 ms polls, at most 3 s): its menus rebuilt
     * (menuBarAgain: they were grey); MacMenuBar's watch redraws the menu bar for that.
     */
    private static void afterFocusBack(final Window w, final String who) {
        final long since = System.currentTimeMillis();
        final javax.swing.Timer t = new javax.swing.Timer(100, null);
        t.addActionListener(e -> {
            long waited = System.currentTimeMillis() - since;
            if (!w.isFocused() && waited < 3000)
                return;
            t.stop();
            Log.d(who + " focused=" + w.isFocused() + " after " + waited + " ms (key window for macOS: " + nativeKey(w) + ")");
            if (!w.isFocused())
                return;
            menuBarAgain(w, who);
        });
        t.start();
    }

    /**
     * The viewer's menus anew in the Mac menu bar. macOS AWT puts a window's menus there when it
     * becomes key (AWTWindow activateWindowMenuBar), greyed if the window is disabled then: after
     * Record's dialogs it still was (grey menus). Taken away and given back (Aqua's ScreenMenuBar,
     * the frame's AWT MenuBar) its menus are made anew, enabled, for the key window (macOS 27
     * draws them once the menu bar is redrawn: MacMenuBar's watch sees the change).
     */
    private static void menuBarAgain(Window w, String who) {
        if (!(w instanceof java.awt.Frame))
            return;
        java.awt.Frame f = (java.awt.Frame) w;
        java.awt.MenuBar mb = f.getMenuBar();
        if (mb == null) {
            Log.d(who + ": no Mac menu bar to put back");
            return;
        }
        f.setMenuBar(null);
        f.setMenuBar(mb);
        Log.d(who + ": Mac menu bar rebuilt (" + mb.getMenuCount() + " menus, focused=" + w.isFocused() + ")");
    }

    /** Whether macOS has w as its key window (CWrapper.NSWindow.isKeyWindow), or "?" if Java won't say. */
    private static String nativeKey(Window w) {
        try {
            Object peer = peerField.get(w);
            Object platform = peer.getClass().getMethod("getPlatformWindow").invoke(peer);
            Field ptrField = null;
            for (Class<?> c = platform.getClass(); c != null && ptrField == null; c = c.getSuperclass())
                try {
                    ptrField = c.getDeclaredField("ptr");
                } catch (NoSuchFieldException e) {
                    // up
                }
            ptrField.setAccessible(true);
            long ptr = ptrField.getLong(platform);
            Class<?> ns = Class.forName("sun.lwawt.macosx.CWrapper$NSWindow");
            Method isKey = ns.getDeclaredMethod("isKeyWindow", long.class);
            isKey.setAccessible(true);
            return String.valueOf(isKey.invoke(null, ptr));
        } catch (Throwable t) {
            return "? (" + t.getClass().getSimpleName() + ")";
        }
    }

    private static void focusNote(String note) {
        if (note != null && !note.equals(lastFocusNote))
            Log.d(note);
        lastFocusNote = note;
    }

    private static boolean shownLogged, videoLogged;

    /** For the launch timing (LaunchTiming, in IPMIView's log lines): window shown, video started. */
    private static void timing(Window w) {
        if (!shownLogged) {
            shownLogged = true;
            Log.d("viewer: window shown");
            ViewerStart.opened();
        }
        if (!videoLogged && w instanceof java.awt.Frame && String.valueOf(((java.awt.Frame) w).getTitle()).contains("Resolution")) {
            videoLogged = true;
            Log.d("viewer: video started");
        }
    }

    private static final Map<Window, String> refits = new WeakHashMap<Window, String>();
    private static final Map<Window, Boolean> loggedBig = new WeakHashMap<Window, Boolean>();

    private static boolean loggedTab;

    private static void keepMaximized(Window w) {
        if (!(w instanceof java.awt.Frame))
            return;
        java.awt.Frame f = (java.awt.Frame) w;
        if ((f.getExtendedState() & java.awt.Frame.MAXIMIZED_BOTH) == java.awt.Frame.MAXIMIZED_BOTH)
            return;
        if (!f.isResizable())
            f.setResizable(true);
        f.setExtendedState(f.getExtendedState() | java.awt.Frame.MAXIMIZED_BOTH);
        if (!loggedTab) {
            loggedTab = true;
            Log.d("viewer in a browser tab: its window kept maximized");
        }
    }

    private static final Map<Window, String> placeholderSeen = new WeakHashMap<Window, String>();

    /**
     * On connecting and on a new remote resolution the viewer sets its window to 320x240, then
     * (invokeLater) fits it to the picture (pack). In the Mac app's container (Xvnc, openbox) the
     * window stayed at 320x240 with the picture running (the user's screenshot: scroll bars, title
     * with FPS). Still that size on two ticks in a row (a second: the viewer's own fit had its
     * turn) with the picture running and a bigger preferred size: packed, at most to the desktop's
     * usable bounds. Once per preferred size; a size the user chose is never 320x240 exactly.
     */
    private static boolean placeholder(java.awt.Frame f, java.awt.Dimension pref) {
        if (Math.abs(f.getWidth() - 320) > 2 || Math.abs(f.getHeight() - 240) > 2
                || (pref.width < 400 && pref.height < 300) || !String.valueOf(f.getTitle()).contains("FPS")) {
            placeholderSeen.remove(f);
            return false;
        }
        String key = pref.width + "x" + pref.height;
        String seen = placeholderSeen.put(f, key + "#1");
        if (seen == null || !seen.startsWith(key + "#"))
            return true;                            // first tick: the viewer's own fit may still come
        if (seen.equals(key + "#done")) {
            placeholderSeen.put(f, seen);
            return true;
        }
        placeholderSeen.put(f, key + "#done");
        boolean resizable = f.isResizable();
        f.setResizable(true);
        f.pack();
        java.awt.Rectangle max = GraphicsEnvironment.getLocalGraphicsEnvironment().getMaximumWindowBounds();
        if (f.getWidth() > max.width || f.getHeight() > max.height)
            f.setBounds(max);
        f.setResizable(resizable);
        Log.d("viewer window left at 320x240 by the viewer: fitted to " + f.getWidth() + "x" + f.getHeight() + " (wants " + key + ")");
        return true;
    }

    private static void refit(Window w) throws Exception {
        Component v = KeyFix.viewerOfWindow(w);
        if (!(w instanceof java.awt.Frame) || v == null)
            return;
        java.awt.Frame f = (java.awt.Frame) w;
        if (f.getExtendedState() != java.awt.Frame.NORMAL || w.getGraphicsConfiguration().getDevice().getFullScreenWindow() == w)
            return;
        java.awt.Dimension pref = w.getPreferredSize();
        if ((w.getWidth() > v.getWidth() + 40 || w.getHeight() > v.getHeight() + 120) && loggedBig.put(w, Boolean.TRUE) == null)
            Log.d("viewer window " + w.getWidth() + "x" + w.getHeight() + ", video " + v.getWidth() + "x" + v.getHeight()
                + " (wants " + v.getPreferredSize().width + "x" + v.getPreferredSize().height + "), window wants "
                + pref.width + "x" + pref.height + ", insets " + w.getInsets() + ", resizable " + f.isResizable());
        if (placeholder(f, pref))
            return;
        if (f.isResizable())
            return;                                 // auto-resize off: the user's size
        try {
            if (!(Boolean) v.getClass().getMethod("isAdjustSize").invoke(v))
                return;
        } catch (NoSuchMethodException e) {
            return;
        }
        if (Math.abs(w.getWidth() - pref.width) <= 2 && Math.abs(w.getHeight() - pref.height) <= 2)
            return;
        String key = pref.width + "x" + pref.height;
        String tried = refits.get(w);
        if ((key + "#2").equals(tried))
            return;
        refits.put(w, key + ((key + "#1").equals(tried) ? "#2" : "#1"));
        String before = w.getWidth() + "x" + w.getHeight();
        f.setResizable(true);
        w.pack();
        f.setResizable(false);
        Log.d("viewer window " + before + " packed to " + w.getWidth() + "x" + w.getHeight());
    }
}
