package keypasta;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.AccessController;
import java.security.PrivilegedAction;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.StringTokenizer;

/**
 * macOS: the viewer's Runtime.exec and ProcessBuilder.start calls land here (Patch.redirectSpawn).
 *
 * A viewer that tunnels the console (stunnel) brings its own stunnel and starts it from wherever
 * it unpacked it, a new place for every viewer: for a firewall such as LuLu a new program every
 * time, asked about every time. So a stunnel the viewer starts runs from a fixed place, with the
 * viewer's arguments: Homebrew's stunnel (the one ipmiview-keypasta.sh uses for IPMIView), else a
 * copy of the viewer's own in ~/Library/Application Support/iKVM-KeyPasta/stunnel/, replaced only
 * when the viewer brings a different one (with any .dylib next to it). Copying fails: the viewer's
 * own, unchanged. Other programs: unchanged. Every program the viewer starts is logged (log=).
 *
 * The .jnlp viewer stops its stunnel by name when it closes (killall -9 1792082932580_stunnel):
 * that name no longer exists, so the stunnel started for that name is stopped here, before the
 * viewer's killall runs (which then finds nothing).
 */
public final class Spawn {
    private static final String[] STUNNELS = {"/opt/homebrew/bin/stunnel", "/usr/local/bin/stunnel"};
    /** Redirected stunnels by the file name the viewer gave them (for its killall). */
    private static final java.util.Map<String, List<Process>> started = new java.util.HashMap<String, List<Process>>();

    private Spawn() {
    }

    public static Process exec(Runtime r, String command) throws IOException {
        return exec(r, split(command), null, null);
    }

    public static Process exec(Runtime r, String command, String[] env) throws IOException {
        return exec(r, split(command), env, null);
    }

    public static Process exec(Runtime r, String command, String[] env, File dir) throws IOException {
        return exec(r, split(command), env, dir);
    }

    public static Process exec(Runtime r, String[] command) throws IOException {
        return exec(r, command, null, null);
    }

    public static Process exec(Runtime r, String[] command, String[] env) throws IOException {
        return exec(r, command, env, null);
    }

    public static Process exec(Runtime r, String[] command, String[] env, File dir) throws IOException {
        String[] f = fixed(command, dir);
        return started(command, f, r.exec(f, env, dir));
    }

    public static Process start(ProcessBuilder b) throws IOException {
        List<String> command = b.command();
        if (command != null && !command.isEmpty()) {
            String[] c = command.toArray(new String[0]);
            String[] f = fixed(c, b.directory());
            if (f != c)
                b.command(new ArrayList<String>(Arrays.asList(f)));
            return started(c, f, b.start());
        }
        return b.start();
    }

    /** Remembers a redirected stunnel under the viewer's name for it. */
    private static Process started(String[] command, String[] fixed, Process p) {
        if (fixed != command && command != null && command.length > 0) {
            String name = new File(command[0]).getName();
            synchronized (started) {
                List<Process> l = started.get(name);
                if (l == null)
                    started.put(name, l = new ArrayList<Process>());
                l.add(p);
            }
        }
        return p;
    }

    /** killall [-signal] name...: stops the redirected stunnels started under those names. */
    private static void kill(String[] command) {
        if (!"killall".equals(new File(command[0]).getName()))
            return;
        for (int i = 1; i < command.length; i++) {
            List<Process> l;
            synchronized (started) {
                l = started.remove(command[i]);
            }
            if (l == null)
                continue;
            for (Process p : l)
                p.destroyForcibly();
            Log.d("stopped the stunnel started as " + command[i] + " (" + l.size() + ")");
        }
    }

    /** As Runtime.exec(String) splits a command. */
    private static String[] split(String command) {
        if (command == null)
            return null;    // Runtime.exec throws its own exception
        StringTokenizer t = new StringTokenizer(command);
        String[] r = new String[t.countTokens()];
        for (int i = 0; i < r.length; i++)
            r[i] = t.nextToken();
        return r;
    }

    /** The command to run: stunnel replaced (a copy), anything else as it is. */
    static String[] fixed(String[] command, File dir) {
        if (command == null || command.length == 0 || command[0] == null)
            return command;
        kill(command);
        String program = command[0];
        String to = isStunnel(program) ? fixedStunnel(program, dir) : null;
        Log.d("viewer starts: " + Arrays.toString(command) + (to != null ? " -> as " + to : ""));
        if (to == null)
            return command;
        String[] r = command.clone();
        r[0] = to;
        return r;
    }

    private static boolean isStunnel(String program) {
        String name = new File(program).getName().toLowerCase(java.util.Locale.ROOT);
        // e.g. stunnel, stunnel-4.56, or as the .jnlp viewer unpacks it, 1792082932580_stunnel
        return name.matches("([^/]*[-_.])?stunnel([-_.]?[0-9][0-9.]*)?");
    }

    /** Homebrew's stunnel, else the fixed copy; null: none (the program is one already, or failed). */
    private static String fixedStunnel(final String program, final File dir) {
        return AccessController.doPrivileged(new PrivilegedAction<String>() {
            @Override
            public String run() {
                try {
                    for (String s : STUNNELS)
                        if (s.equals(program))
                            return null;
                    for (String s : STUNNELS)
                        if (new File(s).canExecute())
                            return s;
                    return copy(program, dir);
                } catch (Exception e) {
                    Log.d("stunnel unchanged: " + e);
                    return null;
                }
            }
        });
    }

    /** The viewer's stunnel (and any .dylib next to it) in the fixed folder; that copy's path. */
    private static String copy(String program, File dir) throws IOException {
        File src = new File(program);
        if (!src.isAbsolute())
            src = new File(dir != null ? dir : new File(System.getProperty("user.dir")), program);
        src = src.getCanonicalFile();
        File to = new File(System.getProperty("user.home"), "Library/Application Support/iKVM-KeyPasta/stunnel");
        if (src.getParentFile().equals(to.getCanonicalFile()))
            return null;
        if (!src.isFile())
            throw new IOException("not found: " + src);
        if (!to.isDirectory() && !to.mkdirs())
            throw new IOException("can't create " + to);
        File[] dylibs = src.getParentFile().listFiles();
        if (dylibs != null)
            for (File f : dylibs)
                if (f.isFile() && f.getName().endsWith(".dylib"))
                    put(f, new File(to, f.getName()));
        File exe = new File(to, "stunnel");
        put(src, exe);
        if (!exe.canExecute() && !exe.setExecutable(true, false))
            throw new IOException("can't make " + exe + " executable");
        return exe.getPath();
    }

    /** Copies when different: under another name first, then renamed (two viewers may start at once). */
    private static void put(File from, File to) throws IOException {
        byte[] b = Files.readAllBytes(from.toPath());
        if (to.isFile() && to.length() == b.length && Arrays.equals(b, Files.readAllBytes(to.toPath())))
            return;
        File tmp = File.createTempFile(to.getName(), ".tmp", to.getParentFile());
        try {
            Files.write(tmp.toPath(), b);
            if (from.canExecute())
                tmp.setExecutable(true, false);
            Files.move(tmp.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } finally {
            tmp.delete();
        }
        Log.d("stunnel copy updated: " + to);
    }
}
