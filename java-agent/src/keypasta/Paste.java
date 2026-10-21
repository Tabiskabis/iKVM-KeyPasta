package keypasta;

import java.awt.Component;
import java.awt.EventQueue;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.datatransfer.DataFlavor;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import javax.swing.BorderFactory;
import javax.swing.Box;
import javax.swing.BoxLayout;
import javax.swing.ButtonGroup;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JRadioButton;
import javax.swing.SwingUtilities;

/**
 * Paste hotkey (Alt+Shift+V, macOS Option+Shift+V): types the clipboard into the remote, every
 * character on the keyboard as its keys on the remote's layout (see KeyFix.remoteLayout), the rest as alt codes (Alt + numpad
 * digits). With CapsLock on: safe paste, everything as alt codes except line breaks, Tab and
 * Space, which works with any remote layout. Asks first when it matters. Esc or leaving the
 * window stops it.
 */
final class Paste {
    private static final int MODIFIER_MASK = InputEvent.SHIFT_DOWN_MASK | InputEvent.CTRL_DOWN_MASK
        | InputEvent.ALT_DOWN_MASK | InputEvent.META_DOWN_MASK | InputEvent.ALT_GRAPH_DOWN_MASK;
    private static final String TITLE = "iKVM clipboard autotype";

    private final KeyFix fix;
    private final Config config;
    private volatile boolean pasting;
    private volatile boolean abort;
    private boolean pasteKeyHeld;
    /** Keys pressed during a paste (swallowed, key code * 10 + location): their releases are swallowed too. */
    private final Set<Integer> swallowed = new HashSet<Integer>();
    /** Modifier keys the user holds (key code * 10 + location). */
    private final Set<Integer> heldModifiers = java.util.Collections.synchronizedSet(new HashSet<Integer>());

    Paste(KeyFix fix) {
        this.fix = fix;
        this.config = fix.config;
    }

    boolean busy() {
        return pasting;
    }

    private static boolean isModifier(int keyCode) {
        return keyCode == KeyEvent.VK_SHIFT || keyCode == KeyEvent.VK_CONTROL || keyCode == KeyEvent.VK_ALT
            || keyCode == KeyEvent.VK_ALT_GRAPH || keyCode == KeyEvent.VK_META || keyCode == KeyEvent.VK_WINDOWS;
    }

    /** Every key event of the user to the viewer. True: consumed. */
    private int loggedNoHotkey;

    boolean handle(KeyEvent e) {
        int id = e.getID();
        int keyCode = e.getKeyCode();
        int key = keyCode * 10 + e.getKeyLocation();
        boolean repeat = false;     // a modifier's key repeat
        if (isModifier(keyCode)) {
            if (id == KeyEvent.KEY_PRESSED)
                repeat = !heldModifiers.add(key);
            else
                heldModifiers.remove(key);
        }
        boolean isPasteKey = hotkeyKey(e) == config.pasteKey
            || (MacKeys.kvk(e) < 0 && e.getExtendedKeyCode() == config.pasteKey);
        int mods = e.getModifiersEx() & MODIFIER_MASK;
        if (Config.MAC && (mods & InputEvent.ALT_GRAPH_DOWN_MASK) != 0)
            mods &= ~InputEvent.ALT_GRAPH_DOWN_MASK;   // right Option: Alt and AltGr in Java
        // Linux (the container): the Mac's Command comes as the Windows key (Super), for which X
        // gives Java no modifier: held, it is Cmd/meta for the hotkey (cmd+shift+V)
        if (!Config.MAC && windowsKeyHeld())
            mods |= InputEvent.META_DOWN_MASK;
        boolean hotkeyMods = mods == config.pasteMods || mods == config.pasteModsAlt;
        if (id == KeyEvent.KEY_RELEASED && swallowed.remove(key))
            return true;
        // swallowed during the paste and still held: its key repeat reaches the remote now, its
        // release has to as well
        if (id == KeyEvent.KEY_PRESSED && !pasting)
            swallowed.remove(key);
        if (pasteKeyHeld && isPasteKey) {
            // its release is the hotkey's (a press: the release got lost, macOS with Cmd held)
            pasteKeyHeld = false;
            if (id == KeyEvent.KEY_RELEASED)
                return true;
        }
        if (pasting) {
            if (id == KeyEvent.KEY_PRESSED && keyCode == KeyEvent.VK_ESCAPE)
                abort = true;
            // pressed now: neither the press nor the release reaches the remote, modifiers
            // included (their release would land between the paste's own keys)
            if (id == KeyEvent.KEY_PRESSED && !repeat)
                swallowed.add(key);
            // modifiers held since before (the hotkey's): down on the remote, their release goes through
            return !(id == KeyEvent.KEY_RELEASED && isModifier(keyCode));
        }
        if (id == KeyEvent.KEY_PRESSED && isPasteKey && mods != 0
                && (!config.enablePaste || !hotkeyMods)
                && loggedNoHotkey < 5) {
            loggedNoHotkey++;               // (a few: tells why a paste didn't start)
            Log.d("paste key with " + InputEvent.getModifiersExText(mods)
                + ": not the paste hotkey (" + InputEvent.getModifiersExText(config.pasteMods)
                + (config.enablePaste ? "" : ", paste turned off") + ")");
        }
        if (config.enablePaste && id == KeyEvent.KEY_PRESSED && isPasteKey && hotkeyMods) {
            Log.d("paste hotkey");
            pasteKeyHeld = true;
            start(e.getComponent());
            return true;
        }
        return false;
    }

    /**
     * A key event's key as the hotkey sees it (also the dialog's recorder): macOS, the main block,
     * by the physical key, its US key code (with Cmd held, macOS gave V as C on the user's Mac);
     * else the key code, or the extended one if Java has no code for the key.
     */
    static int hotkeyKey(KeyEvent e) {
        int kvk = MacKeys.kvk(e);
        int us = kvk >= 0 ? Layouts.usKey(MacKeys.position(kvk)) : -1;
        if (us >= 0)
            return us;
        return e.getKeyCode() != KeyEvent.VK_UNDEFINED ? e.getKeyCode() : e.getExtendedKeyCode();
    }

    private boolean windowsKeyHeld() {
        synchronized (heldModifiers) {
            for (int k : heldModifiers)
                if (k / 10 == KeyEvent.VK_WINDOWS)
                    return true;
        }
        return false;
    }

    /** The viewer lost the focus: the releases of held keys go elsewhere. Event dispatch thread. */
    void reset() {
        heldModifiers.clear();
        swallowed.clear();
        pasteKeyHeld = false;
    }

    private void start(final Component viewer) {
        config.useBmc(KeyFix.bmcOf(viewer));
        pasting = true;
        abort = false;
        boolean started = false;
        try {
            startThread(viewer);
            started = true;
        } finally {
            if (!started)
                pasting = false;    // else every key would be swallowed from now on
        }
    }

    private void startThread(final Component viewer) {
        // The hotkey's modifiers went down on the remote. Released with nothing in between, the
        // remote sees them alone (Alt+Shift: Windows switches the input language; Alt: menu bars).
        // A Ctrl tap while they're held breaks them up.
        long now = System.currentTimeMillis();
        fix.send(viewer, KeyEvent.KEY_PRESSED, KeyEvent.VK_CONTROL, KeyEvent.KEY_LOCATION_LEFT, 0, now);
        fix.send(viewer, KeyEvent.KEY_RELEASED, KeyEvent.VK_CONTROL, KeyEvent.KEY_LOCATION_LEFT, 0, now);
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                Privileged.run(new Runnable() {     // clipboard access under Java Web Start
                    @Override
                    public void run() {
                        try {
                            paste(viewer);
                        } catch (InterruptedException ignored) {
                        } catch (Exception e) {
                            Log.d("paste failed: " + e);
                        } finally {
                            pasting = false;
                        }
                    }
                });
            }
        }, "iKVM-KeyPasta paste");
        t.setDaemon(true);
        t.start();
    }

    /** One character as keys (position + modifiers) or, if positions is null, as an alt code. */
    private static final class Item {
        final int codePoint;
        final int[] key;

        Item(int codePoint, int[] key) {
            this.codePoint = codePoint;
            this.key = key;
        }
    }

    private static final int ENTER = -1;

    private List<Item> plan(String text, boolean safe) {
        Map<Character, int[]> table = Layouts.table(fix.remoteLayout());
        List<Item> items = new ArrayList<Item>();
        for (int i = 0; i < text.length(); ) {
            int cp = text.codePointAt(i);
            i += Character.charCount(cp);
            int[] key = null;
            if (cp == '\n')
                key = new int[] {ENTER, 0};
            else if (safe) {
                if (cp == '\t')
                    key = new int[] {Layouts.TAB, 0};
                else if (cp == ' ')
                    key = new int[] {Layouts.SPACE, 0};
            } else if (cp <= 0xFFFF && "´`^~¨¦".indexOf(cp) < 0)     // dead keys; ¦: | on Linux
                key = table.get((char) cp);
            items.add(new Item(cp, key));
        }
        return items;
    }

    private void paste(final Component viewer) throws Exception {
        // wait until the hotkey is released, then give the laggy iKVM a moment
        long until = System.currentTimeMillis() + 5000;
        while (!heldModifiers.isEmpty() && !abort && System.currentTimeMillis() < until)
            Thread.sleep(10);
        Thread.sleep(100);

        String text;
        try {
            text = (String) Toolkit.getDefaultToolkit().getSystemClipboard().getData(DataFlavor.stringFlavor);
        } catch (Exception e) {
            Log.d("no text in the clipboard: " + e);
            return;
        }
        if (text == null || text.isEmpty()) {
            Log.d("paste: clipboard empty");
            return;
        }
        text = text.replace("\r\n", "\n").replace('\r', '\n');

        boolean safe = config.pasteSafe || capsLockOn();
        boolean sendNonAscii = !config.pasteNonAscii.equals("never");
        List<Item> items = plan(text, safe);

        int lineBreaks = 0, altGr = 0, control = 0, codepage = 0, unicode = 0, cp1252 = 0, beyond = 0;
        for (Item item : items) {
            int cp = item.codePoint;
            if (item.key != null) {
                if (cp == '\n')
                    lineBreaks++;
                else if ((item.key[1] & Layouts.ALTGR) != 0)
                    altGr++;
                continue;
            }
            if (cp < 32 || cp == 127)
                control++;
            else if ((cp >= 128 && cp <= 255) || (config.remoteWindows && Layouts.CP1252.containsKey(cp)))
                codepage++;
            else if (cp > 255)
                unicode++;
            if (cp > 255) {
                if (Layouts.CP1252.containsKey(cp))
                    cp1252++;
                else
                    beyond++;
            }
        }
        // the remote's layout unknown (not said in the KeyPasta dialog): line breaks and AltGr risky
        boolean askLayout = !safe && !config.remoteLayoutChosen && (lineBreaks > 0 || altGr > 0);
        int slow = control + codepage + unicode;
        boolean askSlow = config.pasteNonAscii.equals("ask") && slow > 0;
        if (askLayout || askSlow) {
            StringBuilder msg = new StringBuilder("<html><body style='width: 330px'>");
            if (askLayout)
                msg.append("• Includes line breaks or AltGr characters (@ # | { } …): if the remote system ")
                    .append("doesn't use the ").append(Layouts.name(fix.remoteLayout()))
                    .append(" layout, garbled commands could run. Safe paste works with any ")
                    .append("layout, but is slower. (Options, KeyPasta Preferences: say this BMC's layout, ")
                    .append("and this isn't asked again.)<br><br>");
            if (askSlow) {
                msg.append("• ").append(slow).append(slow > 1 ? " characters" : " character")
                    .append(" not on the keyboard: typed slowly as Alt + number.");
                if (control > 0)
                    msg.append(" Includes control characters!");
                if (cp1252 + beyond > 0) {
                    msg.append("<br><br>• ").append(cp1252 + beyond).append(" of them depend on the remote's OS, ")
                        .append("choose it below");
                    msg.append(beyond > 0 ? " (" + beyond + " of them likely don't work on Windows at all)." : ".");
                }
            }
            final String[] buttons = askLayout ? new String[] {"Fast paste", "Safe paste", "Cancel"}
                : new String[] {"Paste", "Cancel"};
            final int defaultButton = control > 0 ? buttons.length - 1 : 0;
            final String message = msg.append("</body></html>").toString();
            final boolean osSelector = askSlow && cp1252 + beyond > 0;
            final String[] answer = new String[1];
            EventQueue.invokeAndWait(new Runnable() {
                @Override
                public void run() {
                    answer[0] = ask(viewer, message, buttons, defaultButton, osSelector);
                }
            });
            if (answer[0] == null || answer[0].equals("Cancel"))
                return;
            sendNonAscii = config.pasteNonAscii.equals("ask") || sendNonAscii;
            if (answer[0].equals("Safe paste")) {
                safe = true;
                items = plan(text, true);
            }
            if (!refocus(viewer)) {
                Log.d("paste: the viewer window didn't get the focus back after the dialog");
                return;
            }
        }

        Log.d("paste: " + items.size() + " characters, " + (safe ? "safe" : "fast, " + fix.remoteLayout()));
        type(viewer, items, sendNonAscii);
    }

    private String ask(Component viewer, String message, String[] buttons, int defaultButton, boolean osSelector) {
        JPanel panel = new JPanel();
        panel.setLayout(new BoxLayout(panel, BoxLayout.Y_AXIS));
        JLabel label = new JLabel(message);
        label.setAlignmentX(Component.LEFT_ALIGNMENT);
        panel.add(label);
        if (osSelector) {
            JPanel os = new JPanel();
            os.setLayout(new BoxLayout(os, BoxLayout.X_AXIS));
            os.setAlignmentX(Component.LEFT_ALIGNMENT);
            os.setBorder(BorderFactory.createEmptyBorder(10, 0, 0, 0));
            os.add(new JLabel("Remote OS:"));
            os.add(Box.createHorizontalStrut(10));
            final JRadioButton linux = new JRadioButton("Linux console", !config.remoteWindows);
            final JRadioButton windows = new JRadioButton("Windows", config.remoteWindows);
            ButtonGroup group = new ButtonGroup();
            group.add(linux);
            group.add(windows);
            ActionListener l = new ActionListener() {
                @Override
                public void actionPerformed(ActionEvent e) {
                    config.remoteWindows = windows.isSelected();
                }
            };
            linux.addActionListener(l);
            windows.addActionListener(l);
            os.add(linux);
            os.add(windows);
            panel.add(os);
        }
        int choice = JOptionPane.showOptionDialog(SwingUtilities.getWindowAncestor(viewer), panel, TITLE,
            JOptionPane.DEFAULT_OPTION, JOptionPane.PLAIN_MESSAGE, null, buttons, buttons[defaultButton]);
        return choice < 0 ? null : buttons[choice];
    }

    /** After a dialog: the viewer window active again, or false. */
    private boolean refocus(final Component viewer) throws Exception {
        final Window window = SwingUtilities.getWindowAncestor(viewer);
        EventQueue.invokeAndWait(new Runnable() {
            @Override
            public void run() {
                window.toFront();
                viewer.requestFocusInWindow();
            }
        });
        long until = System.currentTimeMillis() + 1000;
        while (!window.isFocused() && System.currentTimeMillis() < until)
            Thread.sleep(10);
        Thread.sleep(100);
        return window.isFocused();
    }

    private static boolean capsLockOn() {
        try {
            return Toolkit.getDefaultToolkit().getLockingKeyState(KeyEvent.VK_CAPS_LOCK);
        } catch (RuntimeException e) {
            return false;
        }
    }

    private void type(Component viewer, List<Item> items, boolean sendNonAscii) throws Exception {
        Window window = SwingUtilities.getWindowAncestor(viewer);
        for (Item item : items) {
            int cp = item.codePoint;
            if (item.key == null && !sendNonAscii && !(cp >= 32 && cp <= 126))
                continue;
            if (abort || !window.isFocused()) {
                Log.d("paste stopped: " + (abort ? "Esc" : "viewer window not focused"));
                return;
            }
            if (item.key == null)
                altCode(viewer, cp);
            else if (item.key[0] == ENTER)
                tap(viewer, KeyEvent.VK_ENTER, KeyEvent.KEY_LOCATION_STANDARD);
            else
                key(viewer, item.key[0], item.key[1]);
        }
    }

    private void key(Component viewer, int position, int mods) throws Exception {
        boolean shift = (mods & Layouts.SHIFT) != 0;
        boolean altGr = (mods & Layouts.ALTGR) != 0;
        try {
            if (shift)
                send(viewer, KeyEvent.KEY_PRESSED, KeyEvent.VK_SHIFT, KeyEvent.KEY_LOCATION_LEFT);
            if (altGr)
                send(viewer, KeyEvent.KEY_PRESSED, KeyEvent.VK_ALT_GRAPH, KeyEvent.KEY_LOCATION_STANDARD);
            int vk = Layouts.usKey(position);
            send(viewer, KeyEvent.KEY_PRESSED, vk, KeyEvent.KEY_LOCATION_STANDARD);
            send(viewer, KeyEvent.KEY_RELEASED, vk, KeyEvent.KEY_LOCATION_STANDARD);
        } finally {     // no modifier left down on the remote
            if (altGr)
                send(viewer, KeyEvent.KEY_RELEASED, KeyEvent.VK_ALT_GRAPH, KeyEvent.KEY_LOCATION_STANDARD);
            if (shift)
                send(viewer, KeyEvent.KEY_RELEASED, KeyEvent.VK_SHIFT, KeyEvent.KEY_LOCATION_LEFT);
        }
        pause();
    }

    private void tap(Component viewer, int vk, int location) throws Exception {
        send(viewer, KeyEvent.KEY_PRESSED, vk, location);
        send(viewer, KeyEvent.KEY_RELEASED, vk, location);
        pause();
    }

    private void altCode(Component viewer, int cp) throws Exception {
        send(viewer, KeyEvent.KEY_PRESSED, KeyEvent.VK_ALT, KeyEvent.KEY_LOCATION_LEFT);
        try {
            for (char d : Layouts.altCodeDigits(cp, config.remoteWindows).toCharArray())
                tap(viewer, KeyEvent.VK_NUMPAD0 + (d - '0'), KeyEvent.KEY_LOCATION_NUMPAD);
        } finally {
            send(viewer, KeyEvent.KEY_RELEASED, KeyEvent.VK_ALT, KeyEvent.KEY_LOCATION_LEFT);
        }
        pause();
    }

    private void pause() throws InterruptedException {
        if (config.keyDelay > 0)
            Thread.sleep(config.keyDelay);
    }

    private void send(final Component viewer, final int id, final int vk, final int location) throws Exception {
        final long now = System.currentTimeMillis();
        EventQueue.invokeAndWait(new Runnable() {
            @Override
            public void run() {
                fix.send(viewer, id, vk, location, 0, now);
            }
        });
    }
}
