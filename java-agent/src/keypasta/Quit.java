package keypasta;

import java.awt.Component;
import javax.swing.JOptionPane;

/**
 * IPMIView asks "Are you sure to quit ?" before it quits while a BMC's session is open, and "Are
 * you sure to quit ? (You have previously opened the KVM Console window, ...)" while a viewer runs
 * (checkIPMIRunning; the viewers keep running either way). The user wants it to quit right away:
 * its JOptionPane.showConfirmDialog calls (Patch.redirectQuit) land here, and these two questions
 * are answered Yes without being shown. Every other question is asked as before (save the changed
 * configuration, download the server list, ...). The questions are told apart by their text in
 * IPMIView's language (IPMIView20.L.t).
 * Likewise the note on closing a BMC's session after its console was opened ("You have previously
 * opened the KVM Console window, please make sure to close KVM Console after closing the
 * session.", main.A_kvm_connect_warning, a JOptionPane.showMessageDialog with no parent): not
 * shown. Other messages are shown as before.
 */
public final class Quit {
    private static final String[] KEYS = {"main.Are_you_sure_to_quit", "main.Are_you_sure_to_quit_a_kvm_connect"};

    private Quit() {
    }

    public static int showConfirmDialog(Component parent, Object message, String title, int optionType) {
        if (isQuitQuestion(parent, message)) {
            Log.d("IPMIView's quit question left out");
            return JOptionPane.YES_OPTION;
        }
        return JOptionPane.showConfirmDialog(parent, message, title, optionType);
    }

    public static void showMessageDialog(Component parent, Object message) {
        if (is(parent, message, "main.A_kvm_connect_warning")) {
            Log.d("IPMIView's note about the open console on closing a session left out");
            return;
        }
        JOptionPane.showMessageDialog(parent, message);
    }

    private static boolean isQuitQuestion(Component parent, Object message) {
        return is(parent, message, KEYS);
    }

    /** The message is IPMIView's text for one of the keys (its language; L by the parent's or the thread's loader). */
    private static boolean is(Component parent, Object message, String... keys) {
        if (!(message instanceof String))
            return false;
        try {
            ClassLoader loader = parent != null ? parent.getClass().getClassLoader() : Thread.currentThread().getContextClassLoader();
            Class<?> l = Class.forName("IPMIView20.L", true, loader);
            java.lang.reflect.Method t = l.getMethod("t", String.class);
            for (String key : keys)
                if (message.equals(t.invoke(null, key)))
                    return true;
        } catch (Throwable e) {
            Log.d("IPMIView message not recognized: " + e);
        }
        return false;
    }
}
