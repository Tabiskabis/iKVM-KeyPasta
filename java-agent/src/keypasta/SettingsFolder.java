package keypasta;

import java.io.File;
import java.io.IOException;

/**
 * IPMIView's settings folder for every settings file. The starters (Linux, macOS) run IPMIView in
 * its own folder and give it a settings folder of the user's (IPMIView's second argument,
 * IPMIView20.propertyFolder; the Windows launcher too, with %APPDATA%\IPMIView). IPMIView uses
 * that folder for the BMC list, logins and a few more, but opens some settings files by their bare
 * name, in the folder it runs in: sort.properties (read; written to the settings folder, so "Do not
 * show this dialog next time" never stuck), language.properties (read before the arguments are
 * looked at: the language chosen never stuck), smcrakp.properties (written on every start),
 * update.properties, version.properties (in a folder ".\" on Linux and macOS), email.properties
 * without a settings folder. That would write into IPMIView's folder (or fail where the user may
 * not write it, e.g. /opt).
 *
 * These files, opened by a name without a folder (or in "." / ".\"), are opened in the settings
 * folder instead: IPMIView20's propertyFolder once set, before that (and without one) the
 * KEYPASTA_IPMIVIEW_SETTINGS environment variable the starters set. Neither: nothing changes.
 * In IPMIView20, update.CheckUpdate: FileReader/FileWriter become Reader/Writer (Patch.renameClass),
 * File.exists/isFile/createNewFile land here (Patch.redirectSettingsFolder). In ConfigAccessor
 * (only used for settings files; stunnel.properties goes through com.supermicro.ipmi's own):
 * File becomes Folder (also its folder "." / ".\" itself, which it creates), FileReader becomes Reader. Other files (stunnel.properties, ikvm.properties,
 * the program's own) stay where IPMIView looks for them.
 */
public final class SettingsFolder {
    /** IPMIView's settings files (not its configuration like stunnel.properties). */
    private static final java.util.Set<String> NAMES = new java.util.HashSet<String>(java.util.Arrays.asList(
        "IPMIView.properties", "account.properties", "email.properties", "language.properties", "proxy.properties",
        "smcrakp.properties", "sort.properties", "timeout.properties", "update.properties", "version.properties"));

    static volatile ClassLoader loader;      // IPMIView's (Agent, when IPMIView20 loads)
    private static volatile boolean logged;

    private SettingsFolder() {
    }

    /** The settings folder, or null: IPMIView's propertyFolder, else KEYPASTA_IPMIVIEW_SETTINGS. */
    static String folder() {
        try {
            if (loader != null) {
                Object f = Class.forName("IPMIView20.IPMIView20", false, loader).getField("propertyFolder").get(null);
                if (f instanceof String && ((String) f).length() > 0)
                    return (String) f;
            }
        } catch (Throwable t) {
            // not yet loaded, or another IPMIView: the variable
        }
        String env = System.getenv("KEYPASTA_IPMIVIEW_SETTINGS");
        return env == null || env.isEmpty() ? null : env;
    }

    /** "x" "./x" ".\x" (also as one name on Linux/macOS: ".\/x"): true. */
    private static boolean here(String parent) {
        return parent == null || parent.equals(".") || parent.equals(".\\") || parent.equals("." + File.separator);
    }

    /** A settings file by its bare name: the same in the settings folder. Else unchanged. */
    public static String map(String path) {
        return map(path, false);
    }

    private static String map(String path, boolean folders) {
        if (path == null)
            return null;
        File f = new File(path);
        if (f.isAbsolute() || !here(f.getParent()))
            return path;
        String name = f.getName();
        boolean dir = name.equals(".") || name.equals(".\\");
        if (dir ? !folders : !NAMES.contains(name))
            return path;
        String folder = folder();
        if (folder == null)
            return path;
        String to = dir ? new File(folder).getPath() : new File(folder, name).getPath();
        if (!logged) {
            logged = true;
            Log.d("IPMIView's settings files opened by name go to " + folder + " (first: " + path + ")");
        }
        return to;
    }

    public static boolean exists(File f) {
        return new File(map(f.getPath())).exists();
    }

    public static boolean isFile(File f) {
        return new File(map(f.getPath())).isFile();
    }

    public static boolean createNewFile(File f) throws IOException {
        return new File(map(f.getPath())).createNewFile();
    }

    /** IPMIView's FileReader. */
    public static final class Reader extends java.io.FileReader {
        public Reader(String path) throws IOException {
            super(map(path));
        }

        public Reader(File file) throws IOException {
            super(map(file.getPath()));
        }
    }

    /** IPMIView's FileWriter. */
    public static final class Writer extends java.io.FileWriter {
        public Writer(String path) throws IOException {
            super(map(path));
        }

        public Writer(String path, boolean append) throws IOException {
            super(map(path), append);
        }

        public Writer(File file) throws IOException {
            super(map(file.getPath()));
        }

        public Writer(File file, boolean append) throws IOException {
            super(map(file.getPath()), append);
        }
    }

    /** ConfigAccessor's File: the settings files, and its folder "." / ".\\" (it creates it), in the settings folder. */
    public static final class Folder extends File {
        public Folder(String path) {
            super(map(path, true));
        }

        public Folder(String parent, String child) {
            super(map(new File(parent, child).getPath(), true));
        }

        public Folder(File parent, String child) {
            super(map(new File(parent, child).getPath(), true));
        }
    }
}
