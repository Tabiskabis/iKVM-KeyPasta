package keypasta;

import java.awt.im.InputContext;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/**
 * The local keyboard layouts, as codes of Layouts.CODES (null: none of them):
 * - current: the one typing now. macOS: the input source's ID (defaults read com.apple.HIToolbox),
 *   as Java's input locale may be a language only, or the system region's country. Elsewhere and
 *   as a fallback: Java's input locale (Windows: the keyboard layout's language and country).
 * - installed: macOS: the enabled input sources; Windows: the input language list
 *   (HKCU\Keyboard Layout\Preload); else the current one.
 * Found once, the first time asked; nothing of this is ever written.
 */
final class LocalLayouts {
    private LocalLayouts() {
    }

    private static boolean done;
    private static String current;
    private static final Set<String> installed = new LinkedHashSet<String>();

    static synchronized String current() {
        detect();
        return current;
    }

    /**
     * macOS: the current input source read again (it can change while the viewer runs); the
     * code, or null if it's none of Layouts.CODES or unreadable. Not on the event dispatch thread.
     */
    static String readMacCurrent() {
        final String[] r = new String[1];
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                try {
                    r[0] = macCurrentNow();
                } catch (Exception e) {
                    Log.d("current input source not readable: " + e);
                }
            }
        });
        synchronized (LocalLayouts.class) {
            if (r[0] != null)
                current = r[0];
        }
        return r[0];
    }

    /** The default for the remote: the first of Layouts.CODES installed here, else Swiss German. */
    static synchronized String remoteDefault() {
        detect();
        for (String code : Layouts.CODES)
            if (installed.contains(code))
                return code;
        return "de-CH";
    }

    private static void detect() {
        if (done)
            return;
        done = true;
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                try {
                    if (Config.MAC) {
                        current = macCurrentNow();
                        for (String name : layoutNames("AppleEnabledInputSources"))
                            add(macName(name));
                    } else if (System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows")) {
                        for (String line : command("reg", "query", "HKCU\\Keyboard Layout\\Preload")) {
                            String[] parts = line.trim().split("\\s+");
                            if (parts.length == 3 && parts[1].equals("REG_SZ"))
                                add(windowsKlid(parts[2]));
                        }
                    }
                } catch (Exception e) {
                    Log.d("local layouts not readable: " + e);
                }
            }
        });
        if (current == null)
            current = fromLocale(inputLocale());
        if (current != null)
            add(current);
        else if (!installed.isEmpty())
            current = installed.iterator().next();      // the first installed one of Layouts.CODES
        Log.d("local layout " + current + ", installed " + installed);
    }

    private static boolean loggedRaw;

    /**
     * macOS: the current keyboard layout, as code: AppleCurrentKeyboardLayoutInputSourceID (not on
     * every macOS), else the keyboard layout among AppleSelectedInputSources; null: neither known.
     * Their raw values are logged once (layout names only).
     */
    private static String macCurrentNow() throws Exception {
        java.util.List<String> id = command("/usr/bin/defaults", "read", "com.apple.HIToolbox",
            "AppleCurrentKeyboardLayoutInputSourceID");
        String code = macId(first(id));
        java.util.List<String> selected = layoutNames("AppleSelectedInputSources");
        if (!loggedRaw) {
            loggedRaw = true;
            Log.d("macOS current layout ID " + (id.isEmpty() ? "-" : first(id)) + ", selected " + selected);
        }
        if (code != null)
            return code;
        for (String name : selected)
            if (macName(name) != null)
                return macName(name);
        return null;
    }

    /** The "KeyboardLayout Name" values of a com.apple.HIToolbox array (Swiss German, ABC, ...). */
    private static java.util.List<String> layoutNames(String key) throws Exception {
        java.util.List<String> names = new ArrayList<String>();
        for (String line : command("/usr/bin/defaults", "read", "com.apple.HIToolbox", key)) {
            // "KeyboardLayout Name" = "Swiss German";  or  "KeyboardLayout Name" = ABC;
            int i = line.indexOf("KeyboardLayout Name");
            if (i >= 0)
                names.add(line.substring(line.indexOf('=', i) + 1).replaceAll("[\";]", "").trim());
        }
        return names;
    }

    private static void add(String code) {
        if (code != null)
            installed.add(code);
    }

    /** com.apple.keylayout.SwissGerman, ...German, ...ABC, ...US */
    static String macId(String id) {
        if (id == null)
            return null;
        String n = id.substring(id.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT).replaceAll("[^a-z]", "");
        if (n.startsWith("swissgerman"))
            return "de-CH";
        if (n.startsWith("swissfrench"))
            return "fr-CH";
        if (n.startsWith("german"))
            return "de-DE";
        if (n.equals("us") || n.equals("abc") || n.startsWith("usinternational") || n.equals("usextended")
                || n.equals("abcextended"))
            return "us";
        return null;
    }

    /** The name in AppleEnabledInputSources: Swiss German, German, ABC, U.S. */
    static String macName(String name) {
        return macId("com.apple.keylayout." + name.replace(".", ""));
    }

    /** KLID like 00000807, or a substitute's d0010807: the layout's low four digits. */
    static String windowsKlid(String klid) {
        if (klid.length() < 4)
            return null;
        String low = klid.substring(klid.length() - 4).toLowerCase(Locale.ROOT);
        return low.equals("0807") ? "de-CH" : low.equals("100c") ? "fr-CH" : low.equals("0407") ? "de-DE"
            : low.equals("0409") ? "us" : null;
    }

    static String fromLocale(Locale locale) {
        String lang = locale.getLanguage(), country = locale.getCountry();
        if (country.equals("CH"))
            return lang.equals("fr") ? "fr-CH" : lang.equals("de") ? "de-CH" : null;
        if (lang.equals("de") && (country.equals("DE") || country.equals("AT")))
            return "de-DE";
        if (lang.equals("en") && country.equals("US"))
            return "us";
        return null;
    }

    /**
     * Java's input locale: Windows reports the keyboard layout's language and country. macOS
     * may report a language only, Linux the system locale: then the country of the system locale.
     */
    static Locale inputLocale() {
        Locale locale = null;
        try {
            locale = InputContext.getInstance().getLocale();
        } catch (RuntimeException ignored) {
        }
        if (locale == null)
            return Locale.getDefault();
        if (locale.getCountry().isEmpty())
            return new Locale(locale.getLanguage(), Locale.getDefault().getCountry());
        return locale;
    }

    private static String first(List<String> lines) {
        return lines.isEmpty() ? null : lines.get(0).trim();
    }

    /** A command's output lines; empty after 3 s or on failure. */
    private static List<String> command(String... command) throws Exception {
        List<String> lines = new ArrayList<String>();
        Process p = new ProcessBuilder(command).redirectErrorStream(true).start();
        BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), "UTF-8"));
        try {
            for (String line; (line = r.readLine()) != null; )
                lines.add(line);
        } finally {
            r.close();
        }
        if (!p.waitFor(3, TimeUnit.SECONDS)) {
            p.destroy();
            return new ArrayList<String>();
        }
        return p.exitValue() == 0 ? lines : new ArrayList<String>();
    }
}
