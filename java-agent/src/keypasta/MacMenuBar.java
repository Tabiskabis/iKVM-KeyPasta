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
 * app): no redraw, logged once.
 */
final class MacMenuBar {
    private static int state;           // 0 not tried, 1 loaded, -1 not there

    private MacMenuBar() {
    }

    private static native void redraw0();

    static synchronized void redraw() {
        if (state == 0) {
            try {
                System.loadLibrary("keypasta");
                state = 1;
            } catch (Throwable t) {
                state = -1;
                Log.d("Mac menu bar not redrawn: the viewer doesn't run in java-launcher with it (" + t + ")");
            }
        }
        if (state != 1)
            return;
        try {
            redraw0();
            Log.d("Mac menu bar redrawn");
        } catch (Throwable t) {
            state = -1;
            Log.d("Mac menu bar not redrawn: " + t);
        }
    }
}
