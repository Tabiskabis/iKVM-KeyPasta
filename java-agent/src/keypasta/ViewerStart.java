package keypasta;

/**
 * The viewer's start (tw.com.aten.ikvm.KVMMain), timed in the log, and its 5 s pause left out.
 *
 * Started by IPMIView on Linux and macOS (option --FR), the viewer reads user, password and
 * ports from a file IPMIView wrote (<tmp>/<BMC>.temp), then sleeps 5 seconds, then deletes the
 * file; only then does it connect. Nothing else reads that file (only KVMMain and IPMIView's
 * launchers, which write it, mention .temp), so the pause is pure waiting: KVMMain's
 * Thread.sleep(5000) lands here (Patch.redirectViewerStart) and returns at once; the file is
 * deleted right away (sooner than before: it holds the password). Other sleeps in KVMMain
 * (connection retries, stopping stunnel) are unchanged. On Windows IPMIView passes the values as
 * arguments: no file, no pause.
 * Milestones (Agent, by class loading): KVMMain (started), RMConnection (connecting), Viewer
 * (connected and logged in, building the window); then ViewerWatch: window shown, video started.
 *
 * Window shown: the file KEYPASTA_VIEWER_OPENED names is created (opened). The .jnlp launchers
 * set it for their start, and remove the .jnlp from where the browser saved it only once it's
 * there: a viewer window has opened, so the console works.
 */
public final class ViewerStart {
    private ViewerStart() {
    }

    public static void sleep(long ms) throws InterruptedException {
        if (ms == 5000L) {
            Log.d("viewer: read its settings file; its 5 s pause before deleting it left out");
            return;
        }
        Thread.sleep(ms);
    }

    /** The viewer's window is showing: KEYPASTA_VIEWER_OPENED's file created, if set. */
    static void opened() {
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                String f = null;
                try {
                    f = System.getenv("KEYPASTA_VIEWER_OPENED");
                    if (f == null || f.isEmpty())
                        return;
                    java.io.File file = new java.io.File(f);
                    if (file.createNewFile() || file.isFile())
                        Log.d("viewer: window shown, " + f + " created");
                } catch (Exception e) {
                    Log.d("viewer: window shown, " + f + " not created: " + e);
                }
            }
        });
    }

    /** Agent: a class of the viewer is being loaded; the milestones are logged. */
    static void loading(String name) {
        if ("tw/com/aten/ikvm/KVMMain".equals(name))
            Log.d("viewer: started");
        else if ("tw/com/aten/ikvm/jni/RMConnection".equals(name))
            Log.d("viewer: connecting");
        else if ("tw/com/aten/ikvm/ui/Viewer".equals(name))
            Log.d("viewer: connected and logged in, building its window");
    }
}
