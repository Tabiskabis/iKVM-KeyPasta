package keypasta;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

import javax.swing.Timer;

/**
 * The viewer sends every mouse movement Java reports to the BMC as its own packet (RemoteVideo's
 * native mouseAction, called from mouseMoved/mouseDragged on the event dispatch thread): with a
 * fast mouse or trackpad several hundred a second. The user: moving the mouse makes the frame
 * rate drop, more the longer it moves, and it needs a while without movement to recover, which
 * looks like a queue filling up (presumably the BMC's: it hands mouse reports to its USB mouse at
 * a fixed rate, and its video waits meanwhile). Moves (only the position changed) are sent at most
 * mouseRate= times a second here, the latest position (with absolute or normal mouse mode the
 * viewer passes positions, so the ones in between can be left out); a button or wheel change
 * goes at once, a held-back last position after the interval. Single mouse mode passes
 * movements instead (deltas, smm_cursor_hide): unchanged. Calls come from Patch.redirectMouse.
 * With log=: per burst of movement, how many moves Java reported, how many were sent, and the
 * longest native call (a call that blocks holds up the viewer's drawing too).
 */
public final class MouseRate {
    /** Moves per second at most; 0: all, as the viewer does. Set by the agent (mouseRate=). */
    static volatile int rate = 60;

    private static Method native_;
    private static Field singleMode;
    private static long lastSent;
    private static int lastState = -1;
    private static Object pendingViewer;
    private static int pendingX, pendingY, pendingState;
    private static Timer timer;
    // burst statistics
    private static long burstStart, burstLast;
    private static int reported, sent;
    private static long longestCall;

    private MouseRate() {
    }

    public static void mouseAction(Object viewer, int x, int y, int state, int wheel) {
        long now = System.nanoTime();
        int interval = rate > 0 ? 1000 / rate : 0;
        if (wheel != 0 || state != lastState || interval == 0 || deltas(viewer)) {
            pendingViewer = null;
            send(viewer, x, y, state, wheel, now);
            return;
        }
        count(now);
        long waited = (now - lastSent) / 1000000;
        if (waited >= interval) {
            pendingViewer = null;
            send(viewer, x, y, state, 0, now);
            return;
        }
        pendingViewer = viewer;          // the latest position, after the interval
        pendingX = x;
        pendingY = y;
        pendingState = state;
        if (timer == null) {
            timer = new Timer(interval, e -> {
                if (pendingViewer != null) {
                    Object v = pendingViewer;
                    pendingViewer = null;
                    send(v, pendingX, pendingY, pendingState, 0, System.nanoTime());
                }
            });
            timer.setRepeats(false);
        }
        if (!timer.isRunning()) {
            timer.setInitialDelay((int) Math.max(1, interval - waited));
            timer.start();
        }
    }

    private static void count(long now) {
        if (burstStart == 0 || (now - burstLast) / 1000000 > 1000) {
            report();
            burstStart = now;
            reported = 0;
            sent = 0;
            longestCall = 0;
        }
        burstLast = now;
        reported++;
    }

    /** The previous burst, when a new one starts (no timer of its own: nothing runs while idle). */
    private static void report() {
        if (burstStart == 0 || reported < 20)
            return;
        double s = Math.max(1, burstLast - burstStart) / 1e9;
        Log.d(String.format("mouse: %d moves in %.1f s (%.0f/s), %d sent (%.0f/s), longest send %.1f ms",
            reported, s, reported / s, sent, sent / s, longestCall / 1e6));
    }

    private static void send(Object viewer, int x, int y, int state, int wheel, long now) {
        lastSent = now;
        lastState = state;
        long t0 = System.nanoTime();
        try {
            if (native_ == null) {
                for (Class<?> c = viewer.getClass(); c != null && native_ == null; c = c.getSuperclass())
                    for (Method m : c.getDeclaredMethods())
                        if (m.getName().equals("mouseAction") && m.getParameterCount() == 4) {     // the native one (calls redirected, not it)
                            m.setAccessible(true);
                            native_ = m;
                            break;
                        }
            }
            native_.invoke(viewer, x, y, state, wheel);
        } catch (java.lang.reflect.InvocationTargetException e) {
            Throwable c = e.getCause();
            if (c instanceof RuntimeException)
                throw (RuntimeException) c;
            if (c instanceof Error)
                throw (Error) c;
            throw new RuntimeException(c);
        } catch (IllegalAccessException e) {
            throw new IllegalStateException(e);
        }
        long took = System.nanoTime() - t0;
        if (wheel == 0) {
            sent++;
            if (took > longestCall)
                longestCall = took;
        }
    }

    /** Single mouse mode with the hidden cursor: the viewer passes movements, not positions. */
    private static boolean deltas(Object viewer) {
        try {
            if (singleMode == null) {
                Field f = viewer.getClass().getDeclaredField("smm_cursor_hide");
                f.setAccessible(true);
                singleMode = f;
            }
            return singleMode.getInt(viewer) == 1;
        } catch (Exception e) {
            return true;            // can't tell: everything as the viewer does
        }
    }
}
