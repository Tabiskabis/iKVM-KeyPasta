package keypasta;

import java.awt.EventQueue;

/**
 * macOS, Toggle keys Passthrough: the Caps Lock key's real press and release. AppKit (and so Java)
 * reports Caps Lock only as the lock changing, a press when it goes on and a release when it goes
 * off; the keyboard itself reports the key down and up. The native part (java-launcher.c, start0
 * and next0, found like MacMenuBar's) reads those reports, which needs the Input Monitoring
 * permission (the Mac app asks for it, once per version; never from here). While it works
 * (`active`) and Passthrough is in use, KeyFix drops Java's Caps Lock events and these go to the
 * viewer instead; without it, each Java event is sent as a press and a release. Started once per
 * program, as the agent installs into a viewer (KeyFix.install), in every mode: a BMC's own
 * setting is known only from its first key on.
 */
final class MacCapsKey {
    /** The keyboard reports come in. */
    static volatile boolean active;
    private static boolean started;
    /** IOHIDManagerOpen's kIOReturnExclusiveAccess: some keyboards seized elsewhere, the others open. */
    private static final int EXCLUSIVE = 0xe00002c5;
    /** System.nanoTime of the last report from a keyboard (only once `reported`). */
    private static volatile long lastReport;
    private static volatile boolean reported;
    private static boolean fallbackLogged;

    /**
     * A Caps Lock event from Java while active: a keyboard should have reported the key by now or
     * very soon (the report and AppKit's event come from the same press). None from 400 ms before
     * to 200 ms after it (the keyboard is one of those held by another program): this toggle as a
     * press and a release.
     */
    static void javaEvent(final Object viewer) {
        final long at = System.nanoTime();
        javax.swing.Timer t = new javax.swing.Timer(200, new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                if (reported && at - lastReport < 400000000L)
                    return;                         // reported within 400 ms before, or since
                if (!fallbackLogged) {
                    fallbackLogged = true;
                    Log.d("Caps Lock: no report from the keyboards for this toggle (its keyboard held by another program?)");
                }
                Native.wholeKey(viewer, 57);
            }
        });
        t.setRepeats(false);
        t.start();
    }

    private MacCapsKey() {
    }

    /** 0 open, 1 Input Monitoring not granted, -1 IOKit not usable, else IOHIDManagerOpen's error. */
    private static native int start0();

    /** The next Caps Lock report (blocks): 1 down, 0 up. */
    private static native int next0();

    static synchronized void start(final KeyFix fix) {
        if (started)
            return;
        started = true;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                Privileged.run(new Runnable() {     // the library under Java Web Start
                    @Override
                    public void run() {
                        listen(fix);
                    }
                });
            }
        }, "iKVM-KeyPasta Caps Lock");
        t.setDaemon(true);
        t.start();
    }

    private static void listen(final KeyFix fix) {
        int r;
        try {
            System.loadLibrary("keypasta");
            r = start0();
        } catch (Throwable e) {
            // no native part (not in java-launcher, or an older one)
            Log.d("Caps Lock key not readable: " + e + "; sent as a press and a release per toggle");
            return;
        }
        if (r != 0 && r != EXCLUSIVE) {
            Log.d("Caps Lock key not readable: " + (r == 1 ? "no Input Monitoring permission"
                : r == -1 ? "IOKit not usable" : "keyboards not opened, error 0x" + Integer.toHexString(r))
                + "; sent as a press and a release per toggle");
            return;
        }
        active = true;
        Log.d(r == 0 ? "Caps Lock key read from the keyboard: down and up as pressed"
            : "Caps Lock key read from the keyboards not held by another program (e.g. Karabiner-Elements): "
                + "down and up as pressed; a toggle none of them reports is sent as a press and a release");
        while (true) {
            final boolean down = next0() != 0;
            lastReport = System.nanoTime();
            if (!reported) {
                reported = true;
                Log.d("Caps Lock: first report from the keyboard");
            }
            EventQueue.invokeLater(new Runnable() {
                @Override
                public void run() {
                    fix.capsKey(down);
                }
            });
        }
    }
}
