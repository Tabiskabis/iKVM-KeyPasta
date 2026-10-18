package keypasta;

import java.awt.im.InputContext;
import java.util.Locale;

/**
 * The viewer switches the local input method to a locale: Viewer.getInputContext to its own
 * "Keyboard layout" setting (from the BMC, else Java's default locale), the virtual keyboard to
 * its language. On macOS that switches the Mac's keyboard layout (input source), e.g. to ABC/US
 * for English, and back on other occasions: a Swiss keyboard then types QWERTY into the viewer,
 * and the keyboard fixes, which read the local layout, map the wrong keys (Y/Z swapped, the ISO
 * key arriving as the key left of 1). With the keyboard fixes on, the switch is left out
 * (Patch.redirectInputSwitch); off: the viewer's own behaviour.
 */
public final class InputSwitch {
    private static volatile boolean logged;

    private InputSwitch() {
    }

    private static InputContext kept;

    /**
     * Viewer.getInputContext's InputContext.getInstance(): a new context on every call, i.e. on
     * every input event (an input method activated anew each time; and nothing to end a dead key's
     * composition with, see KeyFix.endMacComposition). One kept context instead, for all of the
     * viewer's windows, like a window's own (Patch.redirectInputSwitch).
     */
    public static synchronized InputContext getInstance() {
        Config c = ViewerLayout.config;
        if (c != null && !c.enableKeyFix)
            return InputContext.getInstance();      // keyboard fixes off: the viewer's own way
        if (kept == null) {
            kept = InputContext.getInstance();
            Log.d("viewer's input context: one kept one instead of a new one per call");
        }
        return kept;
    }

    public static boolean selectInputMethod(InputContext context, Locale locale) {
        Config c = ViewerLayout.config;
        if (c == null || c.enableKeyFix) {
            if (!logged) {
                logged = true;
                Log.d("viewer's switch of the local input method to " + locale + " left out");
            }
            return false;
        }
        return context.selectInputMethod(locale);
    }
}
