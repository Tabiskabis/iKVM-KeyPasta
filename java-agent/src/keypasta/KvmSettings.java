package keypasta;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Locale;
import java.util.Map;

/**
 * IPMIView on Linux and macOS hands the viewer its user name, password and ports in a file,
 * <tmp>/<BMC>.temp, written with the default permissions (world-readable with the usual umask)
 * and deleted by the viewer only after it has read it. Here no such file is written: the settings
 * go through the viewer's standard input instead (not on disk, not in the process list, not in
 * the environment).
 *
 * IPMIView side (IPMIView20/iKVMLunchar): its FileWriter class reference is renamed to
 * KvmSettings.Writer (Patch.renameClass), which keeps the text in memory; LaunchTiming.exec
 * starts the viewer with the environment variable KEYPASTA_KVM_SETTINGS=stdin (a flag only)
 * and writes the text to its standard input. Viewer side (tw/com/aten/ikvm/KVMMain): with that
 * flag, its FileReader becomes KvmSettings.Reader, which reads standard input, and File.exists
 * and File.delete of the .temp file (Patch.redirectKvmSettings) answer as if it were there and
 * deleted. Only when the viewer will run with the agent too (JAVA_TOOL_OPTIONS or
 * JDK_JAVA_OPTIONS name it: the Mac app, the Linux setup in the README); else the file as before.
 */
public final class KvmSettings {
    static final String FLAG = "KEYPASTA_KVM_SETTINGS";
    private static String pending;
    private static String received;

    private KvmSettings() {
    }

    /** IPMIView: whether the viewer it starts will have the agent (same Java options). */
    static boolean viewerHasAgent() {
        for (String name : new String[] {"JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS"}) {
            String v = System.getenv(name);
            if (v != null && v.contains("-javaagent:") && v.toLowerCase(Locale.ROOT).contains("keypasta"))
                return true;
        }
        return false;
    }

    /** The settings written for the next viewer start, once. */
    static synchronized String takePending() {
        String s = pending;
        pending = null;
        return s;
    }

    /** LaunchTiming.exec: the viewer started with the settings on its standard input. */
    static Process execWithSettings(Runtime runtime, String command, String settings) throws IOException {
        Map<String, String> env = new java.util.HashMap<String, String>(System.getenv());
        env.put(FLAG, "stdin");
        String[] envp = new String[env.size()];
        int i = 0;
        for (Map.Entry<String, String> e : env.entrySet())
            envp[i++] = e.getKey() + "=" + e.getValue();
        Process p = runtime.exec(command, envp);
        OutputStream in = p.getOutputStream();
        try {
            in.write(settings.getBytes("UTF-8"));
        } finally {
            in.close();
        }
        Log.d("KVM launch: settings passed to the viewer through its standard input (no file)");
        return p;
    }

    /** Viewer: started with the settings on its standard input. */
    static boolean fromStdin() {
        try {
            return "stdin".equals(System.getenv(FLAG));
        } catch (SecurityException e) {
            return false;
        }
    }

    private static boolean isSettingsFile(File f) {
        return f != null && f.getName().endsWith(".temp") && fromStdin();
    }

    /** Viewer (KVMMain): File.exists. */
    public static boolean exists(File f) {
        return isSettingsFile(f) || f.exists();
    }

    /** Viewer (KVMMain): File.delete. */
    public static boolean delete(File f) {
        return isSettingsFile(f) || f.delete();
    }

    private static synchronized String received() throws IOException {
        if (received == null) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            InputStream in = System.in;
            byte[] buf = new byte[1024];
            for (int n; (n = in.read(buf)) > 0; )
                out.write(buf, 0, n);
            received = out.toString("UTF-8");
            Log.d("viewer: settings read from its standard input (no file)");
        }
        return received;
    }

    /** IPMIView's FileWriter for the .temp file: in memory (or the file, if the viewer has no agent). */
    public static final class Writer extends java.io.FileWriter {
        private final StringBuilder text = new StringBuilder();
        private final java.io.FileWriter file;

        public Writer(String path) throws IOException {
            super(new java.io.FileDescriptor());
            file = path.endsWith(".temp") && viewerHasAgent() ? null : new java.io.FileWriter(path);
        }

        @Override
        public void write(int c) throws IOException {
            if (file != null) file.write(c); else text.append((char) c);
        }

        @Override
        public void write(char[] c, int off, int len) throws IOException {
            if (file != null) file.write(c, off, len); else text.append(c, off, len);
        }

        @Override
        public void write(String s, int off, int len) throws IOException {
            if (file != null) file.write(s, off, len); else text.append(s, off, off + len);
        }

        @Override
        public void write(String s) throws IOException {
            write(s, 0, s.length());
        }

        @Override
        public void flush() throws IOException {
            if (file != null) file.flush();
        }

        @Override
        public void close() throws IOException {
            if (file != null) {
                file.close();
                return;
            }
            synchronized (KvmSettings.class) {
                pending = text.toString();
            }
        }
    }

    /** The viewer's FileReader for the .temp file: its standard input, when started that way. */
    public static final class Reader extends java.io.FileReader {
        private final java.io.Reader in;

        public Reader(String path) throws IOException {
            super(new java.io.FileDescriptor());
            in = path.endsWith(".temp") && fromStdin() ? new java.io.StringReader(received()) : new java.io.FileReader(path);
        }

        @Override
        public int read() throws IOException {
            return in.read();
        }

        @Override
        public int read(char[] c, int off, int len) throws IOException {
            return in.read(c, off, len);
        }

        @Override
        public boolean ready() throws IOException {
            return in.ready();
        }

        @Override
        public void close() throws IOException {
            in.close();
        }
    }
}
