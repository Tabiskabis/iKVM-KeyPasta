package keypasta;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.security.AccessController;
import java.security.PrivilegedAction;

/**
 * The viewer's native keyboard and LED calls land here (Patch.redirectNatives, every OS), and go
 * on by the Toggle keys setting (KeyPasta Preferences, Config.TOGGLE), the same on every system
 * and for CapsLock, NumLock and ScrollLock (USB 57, 83, 71):
 *
 * - unaltered (Unaltered behavior): every call goes on unchanged, as without the agent (macOS: the
 *   crash prevented, see below).
 * - passthrough: no LED calls; a toggle key sent as the physical key goes, down when it's pressed
 *   and up only when it's released, no state (see physicalKey; the viewer's own calls: plain).
 * - both (Toggle both sides): no LED calls; the remote's lock brought to the local one's new
 *   state at each press (see bothKey).
 *
 * How iKVM sends a toggle key: not as a press and a release but as the state wanted, by the local
 * LED: 0x39 (on) or 0xff39 (off) for CapsLock. The BMC presses the key on the remote only when
 * that differs from the remote's LED. USB keyboards have no such state, only the key: the codes
 * are iKVM's, between the library and the BMC. Tried and dropped: both codes per press, "on" then
 * "off" per press (each left a Linux text console or an X desktop stuck on), and a menu to toggle
 * a lock (back to back, the BMC took only the first code: it could only turn a lock on); the local
 * lock toggled back after the key (toggle remote only), the local lock following the remote's
 * reported lights (follow remote), the local lock's new state sent per press (toggle both + sync):
 * each confused one side's state or toggled the remote anyway. The BMC
 * reports the remote's lights when they change (changeLEDstate; logged in every mode), but only
 * lights: a Debian text console's Caps key toggles a shift lock without one.
 *
 * macOS: iKVM's library reads and sets the keyboard LEDs by opening the keyboard as a USB HID
 * device, which macOS allows only with a permission (Input Monitoring); refused, the library
 * calls exit(1): the viewer quits, no crash report. It does so whenever the viewer loses or gets
 * the focus (Viewer.focusLost/focusGained: opening any dialog), on the BMC's LED reports, and in
 * keyboardAction for the toggle keys. MacHid prevents that exit before the first call (every
 * mode): the library's LED read then fails quietly (lock state off, NumLock by its own count of
 * presses), all else unchanged. Passthrough makes no LED call anyway. The guard can't be put in
 * place (logged loudly): no LED call in any mode (see unaltered()).
 *
 * Linux, unaltered: changeLEDstate (the BMC reported LEDs other than the local ones; the viewer
 * got the focus) sets the local lock state by typing the lock key (XTestFakeKeyEvent,
 * libiKVM64.so), which reaches the viewer and the remote too. Left so: unaltered is iKVM's own.
 */
public final class Native {
    /** The Toggle keys setting in use: unaltered, both or passthrough (see Config.applyHost). */
    static volatile String toggle = "both";
    /** The toggle keys pressed (down 1) and not released yet: their repeats send nothing. The
     *  viewer sends Windows' and Linux's toggle keys as other keys (RemoteVideo.QueryOS < 2: in its
     *  "stable" keyboard mode a whole key, down 2, at the release; held, down 1, then 0), macOS'
     *  as one whole key per event (a Mac reports CapsLock turning on as a press, off as a
     *  release; the keypad's Clear, NumLock here, only as a press: see KeyFix). */
    private static final java.util.Set<Integer> held = new java.util.HashSet<Integer>();
    /** Passthrough: the toggle keys physically held, sent down to the remote (see physicalKey). */
    private static final java.util.Set<Integer> physical = new java.util.HashSet<Integer>();
    /** Toggle both sides: the remote's lock states as the keys sent made them, for bothViewer. */
    private static final java.util.Map<Integer, Boolean> remote = new java.util.HashMap<Integer, Boolean>();
    private static Object bothViewer;
    private static volatile Method keyboardAction, changeLEDstate, getLEDstate, setLEDstate;

    private Native() {
    }

    /**
     * Unaltered behavior, and the viewer's LED calls are safe: on macOS only with MacHid's guard
     * in place (else, without Input Monitoring, the library would quit the viewer); unguarded,
     * the toggle keys go as Passthrough's plain calls and no LED call is made.
     */
    private static boolean unaltered() {
        if (!"unaltered".equals(toggle))
            return false;
        if (Config.MAC)
            MacHid.guard();
        return MacHid.guarded();
    }

    static boolean passthrough() {
        return "passthrough".equals(toggle);
    }

    static boolean both() {
        return "both".equals(toggle);
    }

    /**
     * Toggle both sides, from KeyFix once the local lock has its new state (the key's release;
     * macOS: every Caps Lock event, Clear's press): the remote's lock is brought to that state.
     * The remote's state is what the keys sent here made it (`remote`, per viewer): while both are
     * in step every press toggles both; after the local lock changed in another program, the next
     * press here changes only the local one, and both are in step again. Unknown at first: taken
     * as in step before this press (the key is sent). Changes on the remote's side aren't seen.
     * The key goes as a press and a release at once. Local state unknown (macOS' Num Lock: a Mac
     * has none): sent every time.
     */
    static synchronized void bothKey(Object viewer, int scanKey, Boolean local) {
        if (viewer != bothViewer) {
            remote.clear();
            bothViewer = viewer;
        }
        if (local == null) {
            send(viewer, scanKey, 1);
            send(viewer, scanKey, 0);
            Log.d("toggle key " + scanKey + " sent (local state unknown)");
            return;
        }
        Boolean r = remote.get(scanKey);
        if (r == null)
            r = !local;                             // in step before this press
        if (r.booleanValue() == local.booleanValue()) {
            Log.d("toggle key " + scanKey + " not sent: local now " + (local ? "on" : "off") + ", as the remote already");
            return;
        }
        send(viewer, scanKey, 1);
        send(viewer, scanKey, 0);
        remote.put(scanKey, local);
        Log.d("toggle key " + scanKey + " sent: local now " + (local ? "on" : "off") + ", the remote too");
    }

    static boolean isToggle(int scanKey) {
        return scanKey == 57 || scanKey == 83 || scanKey == 71;
    }

    /**
     * Passthrough, from KeyFix, before the viewer sees the key: the toggle key (USB 57, 83, 71)
     * down on the remote at the physical press, up at the physical release, as any key of a USB
     * keyboard. The viewer itself can't: in its "stable" keyboard mode (Windows, Linux) it sends
     * a quick press only at the release, as down and up at once. Key repeats send nothing, a
     * release without a press sent (held when the viewer got the focus) neither. macOS' Caps Lock:
     * the key's own down and up from the keyboard (MacCapsKey), else wholeKey. Sent as the key |
     * 0x10000 (see plain); virtualKey is the USB code too, as the viewer passes it; extended 0.
     */
    static synchronized void physicalKey(Object viewer, int scanKey, boolean press) {
        if (press ? !physical.add(scanKey) : !physical.remove(scanKey))
            return;                                 // a repeat, or a release whose press wasn't sent
        send(viewer, scanKey, press ? 1 : 0);
        Log.d("toggle key " + scanKey + " sent as the key: " + (press ? "down" : "up"));
    }

    /** Passthrough, macOS' Caps Lock without the keyboard's own reports (see MacCapsKey): a press and a release. */
    static void wholeKey(Object viewer, int scanKey) {
        send(viewer, scanKey, 1);
        send(viewer, scanKey, 0);
        Log.d("toggle key " + scanKey + " sent as the key: down and up (macOS: one event per toggle)");
    }

    /** Passthrough: the viewer lost the focus, the release goes elsewhere: the held toggle keys up. */
    static synchronized void releasePhysical(Object viewer) {
        for (Integer k : physical) {
            send(viewer, k, 0);
            Log.d("toggle key " + k + " sent as the key: up (focus lost)");
        }
        physical.clear();
    }

    private static void send(Object viewer, int scanKey, int down) {
        call(method(viewer, "keyboardAction"), viewer, scanKey, scanKey | 0x10000, 0, down, 0, 0, 0);
    }

    /**
     * Whether the viewer sends keys now (RemoteVideo.processKeyEvent: OptionInfo.isToogleKeyboard,
     * not isPlayback), as physicalKey goes past its check; can't tell: true.
     */
    static boolean keyboardOn(final Object viewer) {
        try {
            return AccessController.doPrivileged(new PrivilegedAction<Boolean>() {
                @Override
                public Boolean run() {
                    try {
                        java.lang.reflect.Field f = null;
                        for (Class<?> c = viewer.getClass(); c != null && f == null; c = c.getSuperclass())
                            try {
                                f = c.getDeclaredField("kvmInfoRepository");
                            } catch (NoSuchFieldException e) {
                                // the superclass
                            }
                        f.setAccessible(true);
                        Object repo = f.get(viewer);
                        Object option = repo.getClass().getMethod("getOptinoInfo").invoke(repo);
                        return (Boolean) option.getClass().getMethod("isToogleKeyboard").invoke(option)
                            && !(Boolean) option.getClass().getMethod("isPlayback").invoke(option);
                    } catch (Exception e) {
                        return true;
                    }
                }
            });
        } catch (RuntimeException e) {
            return true;
        }
    }

    public static void keyboardAction(Object viewer, int virtualKey, int scanKey, int extended, int down,
                                      int numLock, int capsLock, int scrollLock) {
        if (!unaltered() && isToggle(scanKey)) {
            plain(viewer, virtualKey, scanKey, extended, down, numLock, capsLock, scrollLock);
            return;
        }
        call(method(viewer, "keyboardAction"), viewer, virtualKey, scanKey, extended, down, numLock, capsLock, scrollLock);
    }

    /** Pressed (down 1, 2), released (down 0, 2): {press, release} to send, by the viewer's down. */
    private static synchronized boolean[] edges(int scanKey, int down) {
        boolean whole = Config.MAC || down == 2;
        if (whole)
            return new boolean[] {true, true};
        if (down == 1)
            return new boolean[] {held.add(scanKey), false};
        return new boolean[] {false, held.remove(scanKey)};
    }

    /**
     * Passthrough, the viewer's own toggle key calls (physical keys KeyFix sends itself, see
     * physicalKey; what's left: the virtual keyboard, the Mac keypad's Clear): the key itself, no
     * state. Sent as the key | 0x10000, which the library passes on unchanged (it puts the LED
     * state in only for exactly 57/83/71) and the BMC reads as the key. A whole key (macOS: every
     * event; the stable keyboard mode: down 2) as a press and a release at once.
     */
    private static void plain(Object viewer, int virtualKey, int scanKey, int extended, int down,
                              int numLock, int capsLock, int scrollLock) {
        boolean[] e = edges(scanKey, down);
        int key = scanKey | 0x10000;
        if (e[0])
            call(method(viewer, "keyboardAction"), viewer, virtualKey, key, extended, 1, numLock, capsLock, scrollLock);
        if (e[1])
            call(method(viewer, "keyboardAction"), viewer, virtualKey, key, extended, 0, numLock, capsLock, scrollLock);
        if (both() && viewer == bothViewer && e[0])
            synchronized (Native.class) {         // the virtual keyboard toggled the remote alone
                Boolean r = remote.get(scanKey);
                if (r != null)
                    remote.put(scanKey, !r);
            }
        if (e[0] || e[1])
            Log.d("toggle key " + scanKey + " sent as the key: " + (e[0] && e[1] ? "down and up" : e[0] ? "down" : "up"));
    }

    public static void changeLEDstate(Object viewer, int virtualKey, int scanKey, int extended, int down,
                                      int numLock, int capsLock, int scrollLock) {
        // logged in every mode: whether a BMC reports the remote's lights at all
        Log.d("LED report from the viewer: key " + scanKey + " down " + down + ", num " + numLock + " caps " + capsLock
            + " scroll " + scrollLock + (unaltered() ? "" : " (not passed on)"));
        if (unaltered())
            call(method(viewer, "changeLEDstate"), viewer, virtualKey, scanKey, extended, down, numLock, capsLock, scrollLock);
    }

    /** The local lights, as the viewer compares them with the remote's; passthrough: none. */
    public static int getLEDstate(Object viewer) {
        return unaltered() ? (Integer) call(method(viewer, "getLEDstate"), viewer) : 0;
    }

    public static void setLEDstate(Object viewer) {
        if (unaltered())
            call(method(viewer, "setLEDstate"), viewer);
    }

    private static Method method(Object viewer, final String name) {
        Method m = name.equals("keyboardAction") ? keyboardAction : name.equals("changeLEDstate") ? changeLEDstate
            : name.equals("getLEDstate") ? getLEDstate : setLEDstate;
        if (m != null)
            return m;
        if (Config.MAC)
            MacHid.guard();                     // before the first call into the library
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
