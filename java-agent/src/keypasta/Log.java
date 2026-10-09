package keypasta;

import java.io.FileWriter;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;

/** Debug log (option log=path): decisions only, never which keys were typed. */
final class Log {
    private Log() {
    }

    static String path = "";

    static synchronized void d(final String message) {
        if (path.isEmpty())
            return;
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                try (FileWriter w = new FileWriter(path, true)) {
                    w.write(new SimpleDateFormat("HH:mm:ss.SSS").format(new Date()) + " " + message + "\n");
                } catch (IOException ignored) {
                }
            }
        });
    }
}
