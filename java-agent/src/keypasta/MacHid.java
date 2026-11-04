package keypasta;

/**
 * macOS: keeps iKVM's library from quitting the viewer when it can't read the keyboard's LEDs
 * (no Input Monitoring: its find_led_cookies calls exit(1)). Its LED code then fails the way it
 * does for a Mac without a keyboard, quietly, and everything else stays as the library does it.
 * The native part is in java-launcher.c (guard0), found like MacMenuBar's; it covers the library
 * whether it's loaded yet or not. Once per program, before the first call into the library.
 * Not installed (no native part, IOKit not found, refused): Native makes no LED call at all then
 * (see Native.unguarded), and the log says so loudly.
 */
final class MacHid {
    private static boolean done;
    /** The guard is in place (or not needed: not macOS). */
    private static volatile boolean guarded = !Config.MAC;

    private MacHid() {
    }

    /** 0 done, -1 IOKit not found. */
    private static native int guard0();

    static boolean guarded() {
        return guarded;
    }

    static synchronized void guard() {
        if (done)
            return;
        done = true;
        final String[] failure = new String[1];
        try {
            // with the agent's own permissions: under a Web Start security manager the viewer's
            // code on the stack would get the library load refused
            Privileged.run(new Runnable() {
                public void run() {
                    try {
                        System.loadLibrary("keypasta");
                        if (guard0() == 0)
                            guarded = true;
                        else
                            failure[0] = "IOKit not found";
                    } catch (Throwable t) {
                        failure[0] = String.valueOf(t);
                    }
                }
            });
        } catch (Throwable t) {
            failure[0] = String.valueOf(t);
        }
        if (!guarded)
            Log.d("!!!!! WARNING: iKVM's LED code NOT guarded (" + failure[0] + "): without Input Monitoring it would"
                + " quit the viewer, so the agent makes no LED call at all now; toggle keys go as plain keys"
                + " (not in step with the local lights) even in \"Unaltered behavior\" !!!!!");
    }
}
