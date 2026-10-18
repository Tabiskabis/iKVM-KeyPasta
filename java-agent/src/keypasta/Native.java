package keypasta;

import java.awt.Toolkit;
import java.awt.event.KeyEvent;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.security.AccessController;
import java.security.PrivilegedAction;

/**
 * macOS: the viewer's native keyboard and LED calls land here (Patch.redirectNatives).
 *
 * iKVM's macOS library reads and sets the keyboard LEDs by opening the keyboard as a USB HID
 * device. Without the Input Monitoring permission macOS refuses, and the library then calls
 * exit(1): the viewer quits, no crash report. It does so whenever the viewer loses or gets the
 * focus (Viewer.focusLost/focusGained: opening any dialog), on the BMC's LED reports, and in
 * keyboardAction for the lock keys (USB 57 CapsLock, 83 NumLock, 71 ScrollLock): it sends their
 * state, from the local LED, as the key (57: LED on, 0xff39: LED off).
 *
 * With the permission (the launcher app checks it and passes macLed=native) everything goes to
 * the library unchanged. Without it (ledFallback): no LED calls at all, and a lock key gets its
 * state from Java instead: off as the library sends it (0xff00 added), on with 0x10000 added,
 * which keeps the library from reading the LED (it only does for exactly 57/71/83), and which
 * the BMC gets as 0x00010039 (the library sends the key as 32 bits; for the BMC it's 57).
 *
 * Linux: changeLEDstate (the BMC reported LEDs other than the local ones; the viewer got the
 * focus) sets the local lock state by typing the lock key (XTestFakeKeyEvent, libiKVM64.so). That
 * key goes to the focused window, the viewer, which sent it to the remote: its lock toggled back
 * (CapsLock seemed to work every second time, depending on when the remote reports its LEDs). The
 * time and key are noted here; KeyFix drops that lock key's press and release right after
 * (syncKey), as it does Windows' own (isCapsSyncKey).
 */
public final class Native {
    /** Set by the agent before the viewer class is defined. */
    static volatile boolean ledFallback;
    private static int numLockTaps;
    private static volatile Method keyboardAction, changeLEDstate, getLEDstate, setLEDstate;
    /** Linux: the lock key the viewer's LED sync typed last, and when (see changeLEDstate). */
    private static volatile int syncKey;
    private static volatile long syncAt;
    private static final int SYNC_KEY_MS = 300;

    /** Linux: a lock key event typed by the viewer's LED sync (its press, then its release). */
    static boolean isSyncKey(KeyEvent e) {
        if (syncKey == 0 || e.getKeyCode() != syncKey || System.currentTimeMillis() - syncAt > SYNC_KEY_MS)
            return false;
        if (e.getID() == KeyEvent.KEY_RELEASED)
            syncKey = 0;                            // both seen
        return true;
    }

    private Native() {
    }

    public static void keyboardAction(Object viewer, int virtualKey, int scanKey, int extended, int down,
                                      int numLock, int capsLock, int scrollLock) {
        if (ledFallback)
            scanKey = lockKey(scanKey);
        call(method(viewer, "keyboardAction"), viewer, virtualKey, scanKey, extended, down, numLock, capsLock, scrollLock);
    }

    public static void changeLEDstate(Object viewer, int virtualKey, int scanKey, int extended, int down,
                                      int numLock, int capsLock, int scrollLock) {
        if (ledFallback)
            return;
        if (Config.LINUX) {
            int vk = scanKey == 57 ? KeyEvent.VK_CAPS_LOCK : scanKey == 83 ? KeyEvent.VK_NUM_LOCK
                : scanKey == 71 ? KeyEvent.VK_SCROLL_LOCK : 0;
            if (vk != 0) {
                syncKey = vk;
                syncAt = System.currentTimeMillis();
                Log.d("LED sync: the viewer types " + KeyEvent.getKeyText(vk) + " locally (not for the remote)");
            }
        }
        call(method(viewer, "changeLEDstate"), viewer, virtualKey, scanKey, extended, down, numLock, capsLock, scrollLock);
    }

    public static int getLEDstate(Object viewer) {
        if (ledFallback)
            return 0;
        return (Integer) call(method(viewer, "getLEDstate"), viewer);
    }

    public static void setLEDstate(Object viewer) {
        if (ledFallback)
            return;
        call(method(viewer, "setLEDstate"), viewer);
    }

    /** The lock key as the library would send it, the state from Java instead of the LED. */
    static synchronized int lockKey(int scanKey) {
        boolean on;
        switch (scanKey) {
            case 57:
                on = capsLockOn();
                break;
            case 83:
                on = (++numLockTaps & 1) == 1;      // like the library: alternates
                break;
            case 71:
                on = false;                          // ScrollLock: no state to read on macOS
                break;
            default:
                return scanKey;
        }
        Log.d("lock key " + scanKey + " sent as " + (on ? "on" : "off") + " (no LED access)");
        return on ? scanKey | 0x10000 : scanKey | 0xff00;
    }

    private static boolean capsLockOn() {
        try {
            return Toolkit.getDefaultToolkit().getLockingKeyState(KeyEvent.VK_CAPS_LOCK);
        } catch (RuntimeException e) {
            return false;
        }
    }

    private static Method method(Object viewer, final String name) {
        Method m = name.equals("keyboardAction") ? keyboardAction : name.equals("changeLEDstate") ? changeLEDstate
            : name.equals("getLEDstate") ? getLEDstate : setLEDstate;
        if (m != null)
            return m;
        final Class<?> type = viewer.getClass();
        m = AccessController.doPrivileged(new PrivilegedAction<Method>() {
            @Override
            public Method run() {
                for (Class<?> c = type; c != null; c = c.getSuperclass())
                    for (Method d : c.getDeclaredMethods())
                        if (d.getName().equals(name) && java.lang.reflect.Modifier.isNative(d.getModifiers())) {
                            d.setAccessible(true);
                            return d;
                        }
                throw new IllegalStateException("no native " + name + " in " + type.getName());
            }
        });
        if (name.equals("keyboardAction"))
            keyboardAction = m;
        else if (name.equals("changeLEDstate"))
            changeLEDstate = m;
        else if (name.equals("getLEDstate"))
            getLEDstate = m;
        else
            setLEDstate = m;
        return m;
    }

    private static Object call(Method m, Object viewer, Object... args) {
        try {
            return m.invoke(viewer, args);
        } catch (InvocationTargetException e) {
            Throwable t = e.getCause();
            if (t instanceof RuntimeException)
                throw (RuntimeException) t;
            if (t instanceof Error)
                throw (Error) t;
            throw new IllegalStateException(t);
        } catch (IllegalAccessException e) {
            throw new IllegalStateException(e);
        }
    }
}
