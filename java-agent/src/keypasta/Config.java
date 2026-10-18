package keypasta;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.util.Locale;
import java.util.prefs.Preferences;

/**
 * Agent options: -javaagent:iKVM-KeyPasta-agent.jar=name=value,name=value
 *   paste=alt+shift+V      paste hotkey: modifiers (ctrl, alt, shift, meta/cmd) and a key, by
 *                          its letter like Ctrl+V (wherever the local layout has it); default
 *                          Alt+Shift+V (macOS: Option+Shift+V; Cmd+Shift+V never reached the agent)
 *   pasteNonAscii=ask      characters typed as alt codes: ask, always, never
 *   remoteOs=linux         linux (console) or windows: alt codes of Windows-1252 128-159
 *   remoteLayout=auto      default layout of the remotes for fast paste: us, de-CH, fr-CH, de-DE,
 *                          other (Alt codes), auto (Swiss German); the dialog's default and a
 *                          BMC's own layout win over it
 *   localLayout=auto       macOS only (Java doesn't pass key positions there): de-CH, fr-CH,
 *                          de-DE, us, auto (the current input source)
 *   keyDelay=2             ms between keys when pasting
 *   mouseRate=60           mouse moves sent to the BMC per second at most (see MouseRate); 0: all
 *   swapAltCmd=false       Alt and Command swapped (macOS; elsewhere Alt and the Windows key, which
 *                          is Command on a Mac keyboard in the container's browser view): Command
 *                          the remote's Alt (right: AltGr), Alt/Option its Windows key. The
 *                          default; the dialog's default and a BMC's own setting win over it
 *   log=path               debug log file (no key contents)
 *   macLed=fallback        macOS: native = the viewer's own keyboard LED code (needs the Input
 *                          Monitoring permission, else it quits the viewer); fallback = none of
 *                          it, lock key states from Java (see Native). The launcher app passes
 *                          native once the permission is granted.
 */
final class Config {
    static final boolean MAC = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("mac");
    static final boolean LINUX = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("linux");

    // (constants only: KeyEvent's own code would load AWT into every Java program, see resolvePaste)
    int pasteKey = KeyEvent.VK_V;
    int pasteMods = InputEvent.ALT_DOWN_MASK | InputEvent.SHIFT_DOWN_MASK;   // macOS too: Option+Shift+V
    /** macOS, default hotkey: Cmd+Shift+V too (with Option and Command swapped, e.g. by Karabiner); -1: none. */
    int pasteModsAlt = MAC ? InputEvent.META_DOWN_MASK | InputEvent.SHIFT_DOWN_MASK : -1;
    private String pasteKeyName;    // paste= key, resolved by resolvePaste
    private int pasteKeyMods;
    String pasteNonAscii = "ask";
    boolean remoteWindows = false;
    String remoteLayout = "de-CH";            // in use (see applyLayout)
    /** The remote's layout said by the user (remoteLayout= or the dialog): fast paste doesn't ask. */
    boolean remoteLayoutChosen = false;
    /** The BMC remoteLayout, remoteLayoutChosen and pasteSafe are for (see useBmc); null: none yet. */
    private String bmc;
    /** Default remote layout (a code of Layouts.CODES or "other": Alt codes), and whether said. */
    String defaultLayout = "de-CH";
    boolean defaultSaid;
    /** The current BMC's own layout (code or "other"); null: the default. */
    String bmcLayout;
    String localLayout = "auto";
    int keyDelay = 2;
    int mouseRate = 60;
    String log = "";
    boolean macLedNative = false;

    // Settings shown in the viewer's Options -> KeyPasta dialog, persisted across runs.
    boolean enablePaste = true;    // the paste hotkey
    boolean enableKeyFix = true;   // the keyboard position / Ctrl / lock-key fixes
    boolean pasteSafe = false;     // false = fast (remoteLayout), true = safe (alt codes, any layout)
    /** Alt and Command (Windows key) swapped: the default for all BMCs, and whether said. */
    boolean swapDefault = false;
    boolean swapSaid;
    /** The current BMC's own swap setting; null: the default. */
    Boolean bmcSwap;

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
                if (name.equals("paste"))
                    c.setPaste(value);
                else if (name.equals("pasteNonAscii"))
                    c.pasteNonAscii = oneOf(value, "ask", "always", "never");
                else if (name.equals("remoteOs"))
                    c.remoteWindows = oneOf(value, "linux", "windows").equals("windows");
                else if (name.equals("remoteLayout")) {
                    String v = oneOf(value, "auto", "de-CH", "fr-CH", "de-DE", "us", "other");
                    if (!v.equals("auto")) {
                        c.defaultLayout = v;
                        c.defaultSaid = true;
                    }
                }
                else if (name.equals("localLayout"))
                    c.localLayout = oneOf(value, "auto", "de-CH", "fr-CH", "de-DE", "us");
                else if (name.equals("keyDelay"))
                    c.keyDelay = Integer.parseInt(value);
                else if (name.equals("mouseRate"))
                    c.mouseRate = Math.max(0, Integer.parseInt(value));
                else if (name.equals("log"))
                    c.log = value;
                else if (name.equals("swapAltCmd"))
                    c.swapDefault = oneOf(value, "true", "false").equals("true");
                else if (name.equals("macLed"))
                    c.macLedNative = oneOf(value, "native", "fallback").equals("native");
                else
                    throw new IllegalArgumentException("unknown option");
            } catch (RuntimeException e) {
                System.err.println("iKVM-KeyPasta agent: ignoring option " + part + ": " + e);
            }
        }
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
     * The paste= key's key code, once AWT runs (KeyFix): KeyEvent's own code loads AWT, which
     * in premain would happen in every Java program (headless ones included). Unknown key: the
     * default hotkey stays.
     */
    void resolvePaste() {
        if (pasteKeyName == null)
            return;
        String key = pasteKeyName;
        pasteKeyName = null;
        int vk;
        if (key.length() == 1)
            vk = KeyEvent.getExtendedKeyCodeForChar(key.charAt(0));
        else {
            try {
                vk = KeyEvent.class.getField("VK_" + key.toUpperCase(Locale.ROOT)).getInt(null);
            } catch (Exception e) {
                vk = KeyEvent.VK_UNDEFINED;
            }
        }
        if (vk == KeyEvent.VK_UNDEFINED) {
            System.err.println("iKVM-KeyPasta agent: ignoring option paste: unknown key " + key);
            return;
        }
        pasteKey = vk;
        pasteMods = pasteKeyMods;
        pasteModsAlt = -1;                  // said: exactly that one
    }

    private static Preferences prefs() {
        return Preferences.userRoot().node("iKVM-KeyPasta");
    }

    void loadPrefs() {
        try {
            Preferences p = prefs();
            enablePaste = p.getBoolean("enablePaste", enablePaste);
            enableKeyFix = p.getBoolean("enableKeyFix", enableKeyFix);
            String d = p.get("defaultLayout", null);            // said in the dialog: wins over the option
            if (validLayout(d)) {
                defaultLayout = d;
                defaultSaid = true;
            }
            String s = p.get("swapAltCmd", null);               // said in the dialog: wins over the option
            if (s != null) {
                swapDefault = Boolean.parseBoolean(s);
                swapSaid = true;
            }
            pasteNonAscii = p.get("pasteNonAscii", pasteNonAscii);
            remoteWindows = p.getBoolean("remoteWindows", remoteWindows);
            applyLayout();
        } catch (Throwable t) {
            Log.d("reading preferences failed: " + t);     // security manager, etc.
        }
    }

    /**
     * The remote layout: the BMC's own (the viewer window title's [host], see KeyFix.bmcOf), if said
     * in the dialog (prefs node remoteLayout, key: the BMC, value: a code of Layouts.CODES or other),
     * else the default (dialog, prefs defaultLayout; else remoteLayout=; else Swiss German). Said
     * (either): fast paste doesn't ask about line breaks and AltGr characters.
     */
    void useBmc(String b) {
        if (b == null)
            b = "";
        if (b.equals(bmc))
            return;
        bmc = b;
        bmcLayout = null;
        bmcSwap = null;
        try {
            String v = prefs().node("remoteLayout").get(bmcKey(b), null);
            if (validLayout(v))
                bmcLayout = v;
            String s = prefs().node("swapAltCmd").get(bmcKey(b), null);
            if (s != null)
                bmcSwap = Boolean.valueOf(s);
        } catch (Throwable t) {
            Log.d("reading the BMC's settings failed: " + t);
        }
        applyLayout();
        Log.d("BMC \"" + b + "\": remote layout " + (bmcLayout != null ? bmcLayout : "default " + defaultLayout)
            + ", Alt and Command " + (swapAltCmd() ? "swapped" : "not swapped") + (bmcSwap == null ? " (default)" : ""));
    }

    /** Alt and Command (Windows key) swapped for the current BMC. */
    boolean swapAltCmd() {
        return bmcSwap != null ? bmcSwap : swapDefault;
    }

    /** remoteLayout, pasteSafe and remoteLayoutChosen from defaultLayout and bmcLayout. */
    void applyLayout() {
        String l = bmcLayout != null ? bmcLayout : defaultLayout;
        pasteSafe = l.equals("other");
        remoteLayout = pasteSafe ? (defaultLayout.equals("other") ? "de-CH" : defaultLayout) : l;
        remoteLayoutChosen = bmcLayout != null || defaultSaid;
    }

    static boolean validLayout(String v) {
        return v != null && (v.equals("other") || java.util.Arrays.asList(Layouts.CODES).contains(v));
    }

    String bmc() {
        return bmc == null ? "" : bmc;
    }

    /** A preferences key: at most 80 characters, "-" for an unknown BMC. */
    private static String bmcKey(String b) {
        return b.isEmpty() ? "-" : b.length() > Preferences.MAX_KEY_LENGTH ? b.substring(0, Preferences.MAX_KEY_LENGTH) : b;
    }

    void savePrefs() {
        try {
            Preferences p = prefs();
            p.putBoolean("enablePaste", enablePaste);
            p.putBoolean("enableKeyFix", enableKeyFix);
            p.remove("pasteSafe");                              // before the layout was per BMC
            p.remove("remoteLayout");
            if (defaultSaid)
                p.put("defaultLayout", defaultLayout);
            if (swapSaid)
                p.put("swapAltCmd", String.valueOf(swapDefault));
            if (bmc != null) {
                if (bmcLayout != null)
                    p.node("remoteLayout").put(bmcKey(bmc), bmcLayout);
                else
                    p.node("remoteLayout").remove(bmcKey(bmc));
                if (bmcSwap != null)
                    p.node("swapAltCmd").put(bmcKey(bmc), String.valueOf(bmcSwap));
                else
                    p.node("swapAltCmd").remove(bmcKey(bmc));
            }
            p.put("pasteNonAscii", pasteNonAscii);
            p.putBoolean("remoteWindows", remoteWindows);
            p.flush();
        } catch (Throwable t) {
            Log.d("saving preferences failed: " + t);
        }
    }
}
