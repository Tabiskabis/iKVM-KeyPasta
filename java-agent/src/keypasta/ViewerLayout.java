package keypasta;

import java.lang.reflect.Method;
import java.util.Locale;

/**
 * The viewer's own "Keyboard layout" setting (from the BMC, else Java's default locale) moves
 * keys in RemoteVideo.processKeyEvent: German swaps Y and Z, French moves A, Q, W, Z, M, ...
 * The keyboard fixes give every key the US key code of its position already, so with them on the
 * viewer is told US (Patch.redirectKbLayout); off: its own setting, unchanged. The setting itself
 * isn't changed (the virtual keyboard keeps its language).
 */
public final class ViewerLayout {
    static volatile Config config;
    private static volatile Method original;
    private static volatile boolean logged;

    private ViewerLayout() {
    }

    public static Locale getKbLayout(Object optionInfo) {
        Locale own = own(optionInfo);
        Config c = config;
        boolean us = c != null && c.enableKeyFix;
        if (!logged) {
            logged = true;
            Log.d("viewer keyboard layout setting " + own + (us && own != null && !own.equals(Locale.ENGLISH)
                ? ": US for the keys (keyboard fixes on)" : ""));
        }
        return us ? Locale.ENGLISH : own;
    }

    private static Locale own(Object optionInfo) {
        try {
            Method m = original;
            if (m == null)
                original = m = optionInfo.getClass().getMethod("getKbLayout");
            return (Locale) m.invoke(optionInfo);
        } catch (Exception e) {
            Log.d("viewer keyboard layout not readable: " + e);
            return Locale.ENGLISH;
        }
    }
}
