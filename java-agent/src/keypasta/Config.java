package keypasta;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.util.Locale;
import java.io.File;

/**
 * Agent options: -javaagent:iKVM-KeyPasta-agent.jar=name=value,name=value
 *   paste=alt+shift+V      the default paste hotkey: modifiers (ctrl, alt, shift, meta/cmd/win)
 *                          and a key, by its letter like Ctrl+V (wherever the local layout has
 *                          it); default Alt+Shift+V (macOS: Option+Shift+V, also Cmd+Shift+V)
 *   pasteNonAscii=ask      characters typed as alt codes: ask, always, never
 *   remoteOs=linux         linux (console) or windows: alt codes of Windows-1252 128-159
 *   remoteLayout=auto      default layout of the remotes for fast paste: us, de-CH, fr-CH, de-DE,
 *                          other (Alt codes), auto (Swiss German); the dialog's default and a
 *                          BMC's own layout win over it
 *   localLayout=auto       macOS only (Java doesn't pass key positions there): de-CH, fr-CH,
 *                          de-DE, us, auto (the current input source)
 *   keyDelay=2             ms between keys when pasting
 *   loginTrace=false       IPMIView: what its threads do for 20 s after a BMC's view opens, in
 *                          the log (why a login is slow)
 *   mouseRate=60           mouse moves sent to the BMC per second at most (see MouseRate); 0: all
 *   swapAltCmd=false       Alt and Command swapped (macOS; elsewhere Alt and the Windows key, which
 *                          is Command on a Mac keyboard in the container's browser view): Command
 *                          the remote's Alt (right: AltGr), Alt/Option its Windows key. The
 *                          default; the dialog's default and a BMC's own setting win over it
 *   log=path               debug log file (no key contents)
 */
final class Config {
    static final boolean MAC = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("mac");
    static final boolean LINUX = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("linux");

    // (constants only: KeyEvent's own code would load AWT into every Java program, see resolvePaste)
    int pasteKey = KeyEvent.VK_V;
    int pasteMods = InputEvent.ALT_DOWN_MASK | InputEvent.SHIFT_DOWN_MASK;   // macOS too: Option+Shift+V
    /** macOS, default hotkey: Cmd+Shift+V too (with Option and Command swapped, e.g. by Karabiner); -1: none. */
    int pasteModsAlt = MAC ? InputEvent.META_DOWN_MASK | InputEvent.SHIFT_DOWN_MASK : -1;
    private String pasteKeyName;    // the hotkey's key, resolved by resolvePaste
    private int pasteKeyMods;
    private boolean pasteKeyDefault;
    /** AWT runs (KeyFix): the hotkey's key can be resolved (KeyEvent's own code loads AWT). */
    private boolean awt;
    static final String DEFAULT_HOTKEY = "alt+shift+V";
    // In use for the current host (see applyHost): its own value, else the default
    String pasteNonAscii = "ask";
    boolean remoteWindows = false;
    String remoteLayout = "de-CH";
    /** The remote's layout said by the user (remoteLayout= or the dialog): fast paste doesn't ask. */
    boolean remoteLayoutChosen = false;
    /** The host the values in use are for (see useBmc); null: none yet. */
    private String bmc;
    String localLayout = "auto";
    int keyDelay = 2;
    boolean loginTrace = false;
    int mouseRate = 60;
    String log = "";

    boolean enablePaste = true;    // the paste hotkey
    boolean enableKeyFix = true;   // the keyboard position / Ctrl / lock-key fixes
    /** Simplify Caps Lock (Windows, Linux; macOS always): no LED reading or syncing, a CapsLock
     *  press sends the local state once, as on a Mac (see Native). */
    boolean simpleCaps = false;
    boolean pasteSafe = false;     // false = fast (remoteLayout), true = safe (alt codes, any layout)
    private boolean swap = false;  // Alt and Command (Windows key) swapped

    /**
     * The settings of the viewer's KeyPasta Preferences, each with a default and, per host (the
     * BMC in the viewer's title, see KeyFix.bmcOf), a value of its own or none, as text:
     * booleans "true"/"false", the layout a code of Layouts.CODES or "other" (Alt codes), the
     * non-ASCII choice ask/always/never, the hotkey as paste= takes it. Kept in a file, the same
     * on every system (see file()): "setting=value" the default, "setting@host=value" a host's.
     */
    static final String KEY_FIX = "enableKeyFix", SWAP = "swapAltCmd", SIMPLE_CAPS = "simpleCaps",
        PASTE = "enablePaste", HOTKEY = "pasteHotkey", LAYOUT = "remoteLayout", NON_ASCII = "pasteNonAscii",
        REMOTE_WINDOWS = "remoteWindows";
    static final String[] SETTINGS = {KEY_FIX, SWAP, SIMPLE_CAPS, PASTE, HOTKEY, LAYOUT, NON_ASCII, REMOTE_WINDOWS};
    /** The defaults, every setting there. */
    final java.util.Map<String, String> defaults = new java.util.HashMap<String, String>();
    /** The current host's own values (only those it has). */
    final java.util.Map<String, String> own = new java.util.HashMap<String, String>();
    /** The default layout and swap said (the option or the dialog): fast paste doesn't ask. */
    boolean layoutSaid, swapSaid;

    {
        defaults.put(KEY_FIX, "true");
        defaults.put(SWAP, "false");
        defaults.put(SIMPLE_CAPS, "false");
        defaults.put(PASTE, "true");
        defaults.put(HOTKEY, DEFAULT_HOTKEY);
        defaults.put(LAYOUT, "de-CH");
        defaults.put(NON_ASCII, "ask");
        defaults.put(REMOTE_WINDOWS, "false");
    }

    static Config parse(String args) {
        Config c = new Config();
        if (args == null)
            return c;
        for (String part : args.split(",")) {
            if (part.trim().isEmpty())
                continue;
            int eq = part.indexOf('=');
            if (eq < 0) {
                System.err.println("iKVM-KeyPasta agent: ignoring option " + part + ": no name=value");
                continue;
            }
            String name = part.substring(0, eq).trim();
            String value = part.substring(eq + 1).trim();
            try {
                if (name.equals("paste")) {
                    c.setPaste(value);              // (checked)
                    c.defaults.put(HOTKEY, value);
                }
                else if (name.equals("pasteNonAscii"))
                    c.defaults.put(NON_ASCII, oneOf(value, "ask", "always", "never"));
                else if (name.equals("remoteOs"))
                    c.defaults.put(REMOTE_WINDOWS, String.valueOf(oneOf(value, "linux", "windows").equals("windows")));
                else if (name.equals("remoteLayout")) {
                    String v = oneOf(value, "auto", "de-CH", "fr-CH", "de-DE", "us", "other");
                    if (!v.equals("auto")) {
                        c.defaults.put(LAYOUT, v);
                        c.layoutSaid = true;
                    }
                }
                else if (name.equals("localLayout"))
                    c.localLayout = oneOf(value, "auto", "de-CH", "fr-CH", "de-DE", "us");
                else if (name.equals("loginTrace"))
                    c.loginTrace = oneOf(value, "true", "false").equals("true");
                else if (name.equals("keyDelay"))
                    c.keyDelay = Integer.parseInt(value);
                else if (name.equals("mouseRate"))
                    c.mouseRate = Math.max(0, Integer.parseInt(value));
                else if (name.equals("log"))
                    c.log = value;
                else if (name.equals("swapAltCmd")) {
                    c.defaults.put(SWAP, oneOf(value, "true", "false"));
                    c.swapSaid = true;
                }
                else
                    throw new IllegalArgumentException("unknown option");
            } catch (RuntimeException e) {
                System.err.println("iKVM-KeyPasta agent: ignoring option " + part + ": " + e);
            }
        }
        c.applyHost();
        return c;
    }

    /** The value as spelled in values (any case), else an exception. */
    private static String oneOf(String value, String... values) {
        for (String v : values)
            if (v.equalsIgnoreCase(value))
                return v;
        throw new IllegalArgumentException("unknown value");
    }

    private void setPaste(String value) {
        int mods = 0;
        String[] parts = value.split("\\+");
        for (int i = 0; i < parts.length - 1; i++) {
            String m = parts[i].trim().toLowerCase(Locale.ROOT);
            if (m.equals("ctrl") || m.equals("control"))
                mods |= InputEvent.CTRL_DOWN_MASK;
            else if (m.equals("alt") || m.equals("option"))
                mods |= InputEvent.ALT_DOWN_MASK;
            else if (m.equals("shift"))
                mods |= InputEvent.SHIFT_DOWN_MASK;
            else if (m.equals("meta") || m.equals("cmd") || m.equals("win"))
                mods |= InputEvent.META_DOWN_MASK;
            else
                throw new IllegalArgumentException("unknown modifier " + m);
        }
        String key = parts.length == 0 ? "" : parts[parts.length - 1].trim();
        String k = key.toLowerCase(Locale.ROOT);
        if (key.isEmpty() || k.matches("ctrl|control|alt|option|shift|meta|cmd|win|windows|altgr|alt_graph"))
            throw new IllegalArgumentException("no key after the modifiers");
        pasteKeyName = key;
        pasteKeyMods = mods;
    }

    /**
     * The hotkey's key code, once AWT runs (KeyFix; then on every change of host): KeyEvent's own
     * code loads AWT, which in premain would happen in every Java program (headless ones
     * included). An unknown key: the default hotkey.
     */
    void resolvePaste() {
        awt = true;
        if (pasteKeyName == null)
            return;
        String key = pasteKeyName;
        int vk = keyCode(key);
        if (vk == KeyEvent.VK_UNDEFINED) {
            Log.d("paste hotkey: unknown key " + key + ", the default " + DEFAULT_HOTKEY);
            vk = KeyEvent.VK_V;
            pasteKeyMods = InputEvent.ALT_DOWN_MASK | InputEvent.SHIFT_DOWN_MASK;
            pasteKeyDefault = true;
        }
        pasteKey = vk;
        pasteMods = pasteKeyMods;
        // macOS, the default: Cmd+Shift+V too (with Option and Command swapped, e.g. by Karabiner)
        pasteModsAlt = MAC && pasteKeyDefault ? InputEvent.META_DOWN_MASK | InputEvent.SHIFT_DOWN_MASK : -1;
    }

    /** A hotkey's key by its name: one character, or a KeyEvent VK_ name without VK_ (F12, INSERT). */
    static int keyCode(String key) {
        if (key.length() == 1)
            return KeyEvent.getExtendedKeyCodeForChar(key.charAt(0));
        try {
            return KeyEvent.class.getField("VK_" + key.toUpperCase(Locale.ROOT)).getInt(null);
        } catch (Exception e) {
            return KeyEvent.VK_UNDEFINED;
        }
    }

    /** A key code's name for a hotkey (keyCode the other way round); null if it has none. */
    static String keyName(int vk) {
        if ((vk >= KeyEvent.VK_A && vk <= KeyEvent.VK_Z) || (vk >= KeyEvent.VK_0 && vk <= KeyEvent.VK_9))
            return String.valueOf((char) vk);
        if (vk > 0x01000000) {                      // an extended key code: the key's character
            char c = (char) (vk - 0x01000000);
            return c == '+' || Character.isWhitespace(c) ? null : String.valueOf(c);
        }
        for (java.lang.reflect.Field f : KeyEvent.class.getFields())
            try {
                if (f.getName().startsWith("VK_") && f.getType() == int.class && f.getInt(null) == vk)
                    return f.getName().substring(3);
            } catch (IllegalAccessException ignored) {
            }
        return null;
    }

    /** A hotkey's {modifiers, key code}, null if it isn't one. Loads AWT: for the dialog only. */
    static int[] hotkeyKeys(String v) {
        Config c = new Config();
        try {
            c.setPaste(v);
        } catch (RuntimeException e) {
            return null;
        }
        int vk = keyCode(c.pasteKeyName);
        return vk == KeyEvent.VK_UNDEFINED ? null : new int[] {c.pasteKeyMods, vk};
    }

    /** A hotkey in the settings' form: modifiers (ctrl, alt, shift, meta) and the key's name. */
    static String hotkeySpec(int mods, String keyName) {
        StringBuilder b = new StringBuilder();
        if ((mods & InputEvent.CTRL_DOWN_MASK) != 0)
            b.append("ctrl+");
        if ((mods & InputEvent.ALT_DOWN_MASK) != 0)
            b.append("alt+");
        if ((mods & InputEvent.SHIFT_DOWN_MASK) != 0)
            b.append("shift+");
        if ((mods & InputEvent.META_DOWN_MASK) != 0)
            b.append("meta+");
        return b.append(keyName).toString();
    }

    /** A hotkey as paste= takes it: valid? (no AWT: the key itself is checked by resolvePaste) */
    static boolean validHotkey(String v) {
        try {
            new Config().setPaste(v);
            return true;
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** The current host's hotkey in use (applyHost). */
    private void applyHotkey() {
        String h = value(HOTKEY);
        try {
            setPaste(h);
        } catch (RuntimeException e) {
            setPaste(DEFAULT_HOTKEY);
            h = DEFAULT_HOTKEY;
        }
        pasteKeyDefault = h.replace(" ", "").equalsIgnoreCase(DEFAULT_HOTKEY);
        if (awt)
            resolvePaste();
    }

    /**
     * The settings file, agent.properties, in iKVM-KeyPasta's folder of the system: Linux
     * ~/.config/iKVM-KeyPasta ($XDG_CONFIG_HOME), macOS ~/Library/Application Support/iKVM-KeyPasta,
     * Windows %APPDATA%\iKVM-KeyPasta; KEYPASTA_SETTINGS_DIR instead if set (the Mac app's container:
     * the Mac's folder, mounted). A plain file, so it can be copied between people and systems.
     */
    static File file() {
        String dir = env("KEYPASTA_SETTINGS_DIR");
        if (dir == null) {
            String home = System.getProperty("user.home", ".");
            if (MAC)
                dir = home + "/Library/Application Support/iKVM-KeyPasta";
            else if (System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows")) {
                String appData = env("APPDATA");
                dir = (appData != null ? appData : home + "\\AppData\\Roaming") + "\\iKVM-KeyPasta";
            } else {
                String xdg = env("XDG_CONFIG_HOME");
                dir = (xdg != null ? xdg : home + "/.config") + "/iKVM-KeyPasta";
            }
        }
        return new File(dir, "agent.properties");
    }

    private static String env(String name) {
        try {
            String v = System.getenv(name);
            return v == null || v.isEmpty() ? null : v;
        } catch (SecurityException e) {
            return null;
        }
    }

    /** The file's settings (none if it isn't there or can't be read). */
    private static java.util.Properties read() {
        final java.util.Properties p = new java.util.Properties();
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                File f = file();
                if (!f.isFile())
                    return;
                try {
                    java.io.Reader r = new java.io.InputStreamReader(new java.io.FileInputStream(f), "UTF-8");
                    try {
                        p.load(r);
                    } finally {
                        r.close();
                    }
                } catch (Exception e) {
                    Log.d("reading " + f + " failed: " + e);
                }
            }
        });
        return p;
    }

    /** The settings to the file, sorted, through a temporary file renamed over it. */
    private static void write(final java.util.Properties p) {
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                File f = file();
                try {
                    File dir = f.getParentFile();
                    if (dir != null && !dir.isDirectory() && !dir.mkdirs())
                        throw new java.io.IOException("can't create " + dir);
                    File tmp = new File(dir, f.getName() + ".tmp");
                    java.io.Writer w = new java.io.OutputStreamWriter(new java.io.FileOutputStream(tmp), "UTF-8");
                    try {
                        w.write("# iKVM-KeyPasta agent settings (the viewer's Options > KeyPasta Preferences).\n"
                            + "# setting=value: the default; setting@host=value: that host's own.\n");
                        for (String k : new java.util.TreeSet<String>(p.stringPropertyNames()))
                            w.write(escape(k, true) + "=" + escape(p.getProperty(k), false) + "\n");
                    } finally {
                        w.close();
                    }
                    try {
                        java.nio.file.Files.move(tmp.toPath(), f.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                            java.nio.file.StandardCopyOption.ATOMIC_MOVE);
                    } catch (java.io.IOException e) {
                        java.nio.file.Files.move(tmp.toPath(), f.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                    }
                } catch (Exception e) {
                    Log.d("saving " + f + " failed: " + e);
                }
            }
        });
    }

    /** As java.util.Properties reads it back: \, separators and # ! escaped, non-ASCII as \\uXXXX. */
    private static String escape(String s, boolean key) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' || c == '=' || c == ':' || c == '#' || c == '!' || (key && c == ' ') || (i == 0 && c == ' '))
                b.append('\\').append(c);
            else if (c < 0x20 || c > 0x7e)
                b.append(String.format("\\u%04x", (int) c));
            else
                b.append(c);
        }
        return b.toString();
    }

    /** The defaults from the file (they win over the agent's options). */
    void loadPrefs() {
        java.util.Properties p = read();
        for (String k : SETTINGS) {
            String v = p.getProperty(k);
            if (v != null && valid(k, v)) {
                defaults.put(k, v);
                if (k.equals(LAYOUT))
                    layoutSaid = true;
                if (k.equals(SWAP))
                    swapSaid = true;
            }
        }
        Log.d("settings: " + file());
        applyHost();
    }

    static boolean valid(String k, String v) {
        if (k.equals(LAYOUT))
            return validLayout(v);
        if (k.equals(NON_ASCII))
            return v.equals("ask") || v.equals("always") || v.equals("never");
        if (k.equals(HOTKEY))
            return validHotkey(v);
        return v.equals("true") || v.equals("false");
    }

    /** A host's own values, from the file. */
    static java.util.Map<String, String> ownOf(String host) {
        java.util.Map<String, String> m = new java.util.HashMap<String, String>();
        if (host == null || host.isEmpty())
            return m;
        java.util.Properties p = read();
        for (String k : SETTINGS) {
            String v = p.getProperty(k + "@" + host);
            if (v != null && valid(k, v))
                m.put(k, v);
        }
        return m;
    }

    /** The hosts with own settings, sorted. */
    static java.util.List<String> hostsWithOwn() {
        java.util.TreeSet<String> hosts = new java.util.TreeSet<String>(String.CASE_INSENSITIVE_ORDER);
        for (String k : read().stringPropertyNames()) {
            int at = k.indexOf('@');
            if (at > 0 && java.util.Arrays.asList(SETTINGS).contains(k.substring(0, at)))
                hosts.add(k.substring(at + 1));
        }
        return new java.util.ArrayList<String>(hosts);
    }

    /** A host's own values gone: it follows the defaults again. */
    void resetHost(String host) {
        java.util.Properties p = read();
        for (String k : SETTINGS)
            p.remove(k + "@" + host);
        write(p);
        if (host.equals(bmc)) {
            own.clear();
            applyHost();
        }
        Log.d("host \"" + host + "\": own settings removed");
    }

    /**
     * The host the viewer is connected to (the viewer window title's [host], see KeyFix.bmcOf):
     * its own values read, and the values in use set from them and the defaults.
     */
    void useBmc(String b) {
        if (b == null)
            b = "";
        if (b.equals(bmc))
            return;
        bmc = b;
        own.clear();
        own.putAll(ownOf(b));
        applyHost();
        Log.d("host \"" + b + "\": " + (own.isEmpty() ? "the defaults" : "own " + own));
    }

    /** A setting in use for the current host: its own value, else the default. */
    String value(String k) {
        String v = own.get(k);
        return v != null ? v : defaults.get(k);
    }

    /** The values in use from the defaults and the current host's own. */
    void applyHost() {
        enableKeyFix = Boolean.parseBoolean(value(KEY_FIX));
        swap = Boolean.parseBoolean(value(SWAP));
        simpleCaps = Boolean.parseBoolean(value(SIMPLE_CAPS));
        Native.simpleCaps = simpleCaps;
        enablePaste = Boolean.parseBoolean(value(PASTE));
        applyHotkey();
        pasteNonAscii = value(NON_ASCII);
        remoteWindows = Boolean.parseBoolean(value(REMOTE_WINDOWS));
        String l = value(LAYOUT);
        String d = defaults.get(LAYOUT);
        pasteSafe = l.equals("other");
        remoteLayout = pasteSafe ? (d.equals("other") ? "de-CH" : d) : l;
        remoteLayoutChosen = own.containsKey(LAYOUT) || layoutSaid;
    }

    /** Alt and Command (Windows key) swapped for the current host. */
    boolean swapAltCmd() {
        return swap;
    }

    static boolean validLayout(String v) {
        return v != null && (v.equals("other") || java.util.Arrays.asList(Layouts.CODES).contains(v));
    }

    String bmc() {
        return bmc == null ? "" : bmc;
    }

    /**
     * The defaults and the current host's own values, as the dialog left them, into the file as
     * it is now (another viewer may have saved since): the rest of it stays.
     */
    void savePrefs() {
        java.util.Properties p = read();
        for (String k : SETTINGS)
            p.setProperty(k, defaults.get(k));
        layoutSaid = swapSaid = true;
        if (bmc != null && !bmc.isEmpty())
            for (String k : SETTINGS) {
                if (own.containsKey(k))
                    p.setProperty(k + "@" + bmc, own.get(k));
                else
                    p.remove(k + "@" + bmc);
            }
        write(p);
        applyHost();
    }
}
