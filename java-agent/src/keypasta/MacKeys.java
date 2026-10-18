package keypasta;

import java.awt.event.KeyEvent;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * macOS: the physical key of every key event. Java's macOS key handling gets it from the system
 * (NSEvent keyCode, "kVK_" code) but drops it: letters, digits and dead keys get the key code of
 * the character they type, so the position depends on the local layout. Two calls are redirected
 * here (Patch.redirectMacKeys): in sun.lwawt.macosx.CPlatformResponder.handleKeyEvent the
 * conversion NSEvent.nsToJavaKeyInfo / nsKeyModifiersToJavaKeyInfo, whose input holds that code,
 * and in sun.lwawt.LWWindowPeer.notifyKeyEvent the setting of the new KeyEvent's extended key
 * code, which also puts the code into the event's rawCode (unused on macOS), as 0x10000 + code.
 * Both run on the AppKit thread, one right after the other, for every key event.
 *
 * Needs java.desktop to read the agent's module and to open sun.lwawt.macosx to it (prepare, from
 * premain, before AWT loads); not possible: nothing redirected, KeyFix uses the local layout.
 */
public final class MacKeys {
    static final int MARK = 0x10000;
    private static volatile boolean ready;
    private static Method nsToJavaKeyInfo, nsKeyModifiersToJavaKeyInfo;
    private static Field rawCode, extendedKeyCode;
    private static volatile int lastKey = -1;

    private MacKeys() {
    }

    static boolean ready() {
        return ready;
    }

    /** From premain (macOS, module access already granted): finds what the hooks need. */
    static void prepare() {
        try {
            Class<?> ns = Class.forName("sun.lwawt.macosx.NSEvent", false, null);
            nsToJavaKeyInfo = ns.getDeclaredMethod("nsToJavaKeyInfo", int[].class, int[].class);
            nsKeyModifiersToJavaKeyInfo = ns.getDeclaredMethod("nsKeyModifiersToJavaKeyInfo", int[].class, int[].class);
            nsToJavaKeyInfo.setAccessible(true);
            nsKeyModifiersToJavaKeyInfo.setAccessible(true);
            rawCode = KeyEvent.class.getDeclaredField("rawCode");
            extendedKeyCode = KeyEvent.class.getDeclaredField("extendedKeyCode");
            rawCode.setAccessible(true);
            extendedKeyCode.setAccessible(true);
            ready = true;
        } catch (Throwable t) {
            Log.d("macOS physical keys not available: " + t);
        }
    }

    // in = {character, dead?, modifier flags, kVK code}
    public static boolean nsToJavaKeyInfo(int[] in, int[] out) throws Exception {
        lastKey = in.length > 3 ? in[3] & 0xFFFF : -1;
        boolean r = (Boolean) nsToJavaKeyInfo.invoke(null, in, out);
        // A key that types nothing with its modifiers (e.g. Option+Shift+V on the Swiss layouts)
        // has empty characters, which Java takes for a dead key; finding no dead character, it
        // drops the key event entirely (CPlatformResponder: testChar 0, return). It still has a
        // key code: give it its unmodified character, so the event is posted.
        if (in.length > 1 && in[1] != 0 && out.length > 2 && out[2] == 0 && in[0] != 0
                && out[0] != KeyEvent.VK_UNDEFINED) {
            out[2] = in[0];
            if (!loggedEmpty) {
                loggedEmpty = true;
                Log.d("macOS key without character kept (Java drops it otherwise)");
            }
        }
        return r;
    }

    private static volatile boolean loggedEmpty;

    // in = {modifier flags, kVK code}
    public static void nsKeyModifiersToJavaKeyInfo(int[] in, int[] out) throws Exception {
        lastKey = in.length > 1 ? in[1] & 0xFFFF : -1;
        nsKeyModifiersToJavaKeyInfo.invoke(null, in, out);
    }

    /** Instead of AWTAccessor.getKeyEventAccessor().setExtendedKeyCode(e, code): both fields. */
    public static void setExtendedKeyCode(Object accessor, KeyEvent e, long code) throws Exception {
        extendedKeyCode.setLong(e, code);
        int key = lastKey;
        if (key >= 0)
            rawCode.setLong(e, MARK | key);
    }

    /** The kVK code of a key event, -1 if it has none. */
    static int kvk(KeyEvent e) {
        if (!ready)
            return -1;
        try {
            long r = rawCode.getLong(e);
            return (r & MARK) != 0 ? (int) (r & 0xFFFF) : -1;
        } catch (IllegalAccessException ex) {
            return -1;
        }
    }

    /** Copies the kVK code to another event (KeyFix.retarget). */
    static void copy(KeyEvent from, KeyEvent to) {
        try {
            if (ready)
                rawCode.setLong(to, rawCode.getLong(from));
        } catch (IllegalAccessException ignored) {
        }
    }

    /**
     * kVK code -> position (PC scan code), the main block. Not the key left of 1 and the ISO key
     * (0x0A, 0x32): which is which depends on the keyboard type (macOS swaps them on ISO
     * keyboards), their character tells (Layouts.macBackQuotePosition).
     */
    static int position(int kvk) {
        return kvk >= 0 && kvk < KVK_TO_PC.length ? KVK_TO_PC[kvk] : -1;
    }

    private static final int[] KVK_TO_PC = new int[0x32];

    static {
        java.util.Arrays.fill(KVK_TO_PC, -1);
        int[] pairs = {
            0x00, 0x1E, 0x01, 0x1F, 0x02, 0x20, 0x03, 0x21, 0x04, 0x23, 0x05, 0x22, 0x06, 0x2C, 0x07, 0x2D,
            0x08, 0x2E, 0x09, 0x2F, 0x0B, 0x30, 0x0C, 0x10, 0x0D, 0x11, 0x0E, 0x12, 0x0F, 0x13, 0x10, 0x15,
            0x11, 0x14, 0x12, 0x02, 0x13, 0x03, 0x14, 0x04, 0x15, 0x05, 0x16, 0x07, 0x17, 0x06, 0x18, 0x0D,
            0x19, 0x0A, 0x1A, 0x08, 0x1B, 0x0C, 0x1C, 0x09, 0x1D, 0x0B, 0x1E, 0x1B, 0x1F, 0x18, 0x20, 0x16,
            0x21, 0x1A, 0x22, 0x17, 0x23, 0x19, 0x25, 0x26, 0x26, 0x24, 0x27, 0x28, 0x28, 0x25, 0x29, 0x27,
            0x2A, 0x2B, 0x2B, 0x33, 0x2C, 0x35, 0x2D, 0x31, 0x2E, 0x32, 0x2F, 0x34,
        };
        for (int i = 0; i < pairs.length; i += 2)
            KVK_TO_PC[pairs[i]] = pairs[i + 1];
    }
}
