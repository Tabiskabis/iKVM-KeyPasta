package keypasta;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.util.Locale;

/**
 * Agent options: -javaagent:iKVM-KeyPasta-agent.jar=name=value,name=value
 *   paste=alt+shift+V      paste hotkey: modifiers (ctrl, alt, shift, meta/cmd) and a key, by
 *                          its letter like Ctrl+V (wherever the local layout has it); default
 *                          Alt+Shift+V, on macOS Cmd+Shift+V
 *   pasteNonAscii=ask      characters typed as alt codes: ask, always, never
 *   remoteOs=linux         linux (console) or windows: alt codes of Windows-1252 128-159
 *   remoteLayout=auto      layout the remote uses for fast paste: de-CH, fr-CH, auto (local
 *                          Swiss French: fr-CH, else de-CH)
 *   localLayout=auto       macOS only (Java doesn't pass key positions there): de-CH, fr-CH,
 *                          us, auto (from the input locale)
 *   keyDelay=2             ms between keys when pasting
 *   log=path               debug log file (no key contents)
 */
final class Config {
    static final boolean MAC = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("mac");

    // (constants only: KeyEvent's own code would load AWT into every Java program, see resolvePaste)
    int pasteKey = KeyEvent.VK_V;
    int pasteMods = (MAC ? InputEvent.META_DOWN_MASK : InputEvent.ALT_DOWN_MASK) | InputEvent.SHIFT_DOWN_MASK;
    private String pasteKeyName;    // paste= key, resolved by resolvePaste
    private int pasteKeyMods;
    String pasteNonAscii = "ask";
    boolean remoteWindows = false;
    String remoteLayout = "auto";
    String localLayout = "auto";
    int keyDelay = 2;
    String log = "";

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
                else if (name.equals("remoteLayout"))
                    c.remoteLayout = oneOf(value, "auto", "de-CH", "fr-CH");
                else if (name.equals("localLayout"))
                    c.localLayout = oneOf(value, "auto", "de-CH", "fr-CH", "us");
                else if (name.equals("keyDelay"))
                    c.keyDelay = Integer.parseInt(value);
                else if (name.equals("log"))
                    c.log = value;
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
    }
}
