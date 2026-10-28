package keypasta;

/**
 * macOS 27: the menu bar isn't redrawn when an app changes the menus in it (Java does that item by
 * item whenever a window becomes key, CMenuBar activate); the menus are in NSApp.mainMenu but not
 * shown until the pointer goes to the menu bar or the app is switched (also seen by FlatLaf, its
 * PR 1154: plain Swing on JDK 17 and 24 too; re-setting the menu bar from Java doesn't help).
 * Setting the app's main menu again (nil, then back) has macOS redraw it. That takes AppKit, so it
 * is native code: in java-launcher (mac/launcher-app/java-launcher.c), the program the Mac app
 * runs IPMIView and the viewers in (as "IPMIView", "iKVM Viewer"). It's a JNI library built into
 * that program (JNI_OnLoad_keypasta, Java 8+ static libraries: System.loadLibrary finds it in the
 * running program), so no file of its own. Not run through java-launcher (plain java, an older
 * app): nothing done, logged once.
 *
 * watch: the native part watches the menu bar itself (AppKit's notifications: menus changed, the
 * app in front, windows becoming key or main) and redraws it when what it shows changed. It keeps
 * the menu bar's state for the log whenever that changes, taken from here once a second.
 *
 * Also there: noQuitShortcut, the viewer's Quit without Cmd+Q (it quit the viewer instead of
 * reaching the remote; the menus take a shortcut before the window gets the key).
 */
final class MacMenuBar {
    private static int state;           // 0 not tried, 1 loaded, -1 not there
    private static boolean watching;

    private MacMenuBar() {
    }

    private static native void watch0();

    private static native String takeLog0();

    private static native void noQuitShortcut0();

    private static boolean loaded() {
        if (state == 0) {
            try {
                System.loadLibrary("keypasta");
                state = 1;
            } catch (Throwable t) {
                state = -1;
                Log.d("Mac menu bar: no native part, the viewer doesn't run in java-launcher with it (" + t + ")");
            }
        }
        return state == 1;
    }

    /** The viewer's menus without the Cmd+Q shortcut (the item still quits when clicked). */
    static synchronized void noQuitShortcut() {
        if (!loaded())
            return;
        try {
            noQuitShortcut0();
            Log.d("Cmd+Q: no longer Quit's shortcut, it goes to the remote");
        } catch (Throwable t) {
            Log.d("Cmd+Q still quits: " + t);       // an older java-launcher: not fatal
        }
    }

    /** The menu bar redrawn whenever its menus change, from now on; its state logged. Once. */
    static synchronized void watch() {
        if (watching || !loaded())
            return;
        watching = true;
        try {
            watch0();
        } catch (Throwable t) {
            Log.d("Mac menu bar not watched: " + t);  // an older java-launcher
            return;
        }
        Log.d("Mac menu bar watched: redrawn whenever what it shows changes");
        final javax.swing.Timer t = new javax.swing.Timer(1000, null);
        t.addActionListener(e -> {
            try {
                String lines = takeLog0();
                if (lines != null)
                    for (String line : lines.split("\n"))
                        Log.d(line);
            } catch (Throwable ex) {
                t.stop();
                Log.d("Mac menu bar log stopped: " + ex);
            }
        });
        t.start();
    }
}
