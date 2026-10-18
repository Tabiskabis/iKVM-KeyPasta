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
