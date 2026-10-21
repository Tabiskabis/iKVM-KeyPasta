package keypasta;

import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.Container;
import java.awt.Frame;
import java.awt.KeyEventDispatcher;
import java.awt.KeyboardFocusManager;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.AWTEventListener;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.KeyEvent;
import java.awt.event.WindowEvent;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;
import java.lang.reflect.Field;
import java.util.Collections;
import java.util.Locale;
import java.util.Map;
import java.util.WeakHashMap;
import javax.swing.Timer;

/**
 * Sits in front of the iKVM viewer's key handling (a KeyEventDispatcher sees every key event
 * before the component does) and fixes what iKVM gets wrong:
 * - iKVM turns Java's key code, which follows the local layout, into a key position with a US
 *   table. Here every key of the main block gets the US key code of its physical position
 *   instead, so the remote's own layout decides what it types, whatever the local layout.
 * - Windows adds a left Ctrl to every AltGr: dropped.
 * - iKVM's "stable" keyboard mode drops a held left Ctrl when the next key goes down, but a key
 *   release sends it: left Ctrl is followed by the release of F24 (never pressed; no effect on
 *   Linux and Windows remotes).
 * - Lock keys (CapsLock, ...) go to iKVM unchanged for now: the own Windows tap stopped CapsLock
 *   from arriving in a test, unexplained by iKVM's Java code. Being rechecked against AGENTS.md
 *   ("CapsLock as one quick tap") before this is settled.
 * - CapsLock follows the window like on a KVM switch: each viewer window keeps the remote's
 *   state, other programs keep theirs (see windowFocus).
 * - Paste (see Paste).
 * The viewer window's title gets " ⌨", so iKVM-KeyPasta.ahk leaves it alone.
 */
final class KeyFix implements KeyEventDispatcher {
    static final String MARKER = " ⌨";
    private static final String TITLE_START = "Java iKVM Viewer";
    private static final int CTRL_HOLD_MS = 20;
    private static final int ALTGR_GAP_MS = 10;

    enum Os { WINDOWS, LINUX, MAC, OTHER }

    final Config config;
    final Os os;
    final Paste paste;
    private Field scancodeField;
    private Field rawCodeField;
    private Field windowsKeyField;      // Windows: KeyEvent.rawCode is the Windows key code
    private Field locationField;        // Linux: KeyEvent.keyLocation, see linuxLocation
    private volatile Map<Integer, Integer> macPositions = Collections.emptyMap();
    private volatile String macLayout;

    /** Events this class dispatches itself pass through untouched. */
    private boolean injecting;

    private KeyEvent pendingCtrl;
    private boolean ctrlSent;
    private boolean ctrlDropped;
    private final Timer ctrlTimer;
    private Component inputMethodsOff;
    /** CapsLock of each viewer window when last left: the remote's (see windowFocus). */
    private final Map<Window, Boolean> viewerCaps = new WeakHashMap<Window, Boolean>();
    /** CapsLock of the other programs, set again when a viewer window is left for them. */
    private Boolean outsideCaps;
    /** When this class last set CapsLock locally: Windows then sends a CapsLock key. */
    private long capsSetAt;
    private static final int CAPS_SYNC_DELAY_MS = 150;
    private static final int CAPS_KEY_WINDOW_MS = 300;
    /** Keys sent as pressed (after the position fix): key code * 10 + key location, see dispatch. */
    private final java.util.Set<Integer> pressed = new java.util.LinkedHashSet<Integer>();
    private Component viewer;
    /** macOS: keys released when Cmd went up, their own release (if it still comes) is dropped. */
    private final java.util.Set<Integer> releasedWithCmd = new java.util.HashSet<Integer>();

    static void install(Config config) {
        final KeyFix fix = new KeyFix(config);
        KeyboardFocusManager.getCurrentKeyboardFocusManager().addKeyEventDispatcher(fix);
        Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
            @Override
            public void eventDispatched(AWTEvent event) {
                try {
                    if (event.getID() == WindowEvent.WINDOW_OPENED || event.getID() == WindowEvent.WINDOW_ACTIVATED) {
                        markTitle(((WindowEvent) event).getWindow());
                        if (containsViewer(((WindowEvent) event).getWindow())) {
                            Icons.viewerWindow(((WindowEvent) event).getWindow());
                            fix.refreshMacLayout();
                        }
                    }
                    if (event.getID() == WindowEvent.WINDOW_OPENED) {
                        Menu.addTo(((WindowEvent) event).getWindow(), fix);
                        fix.keyboardPopup(((WindowEvent) event).getWindow());
                    }
                    if (event.getID() == WindowEvent.WINDOW_CLOSED || event.getID() == WindowEvent.WINDOW_GAINED_FOCUS)
                        fix.refocus(((WindowEvent) event).getWindow(), event.getID());
                    // keys released in another window never come back here
                    if (event.getID() == WindowEvent.WINDOW_DEACTIVATED)
                        fix.reset();
                    if (event.getID() == WindowEvent.WINDOW_ACTIVATED || event.getID() == WindowEvent.WINDOW_DEACTIVATED)
                        fix.windowFocus((WindowEvent) event);
                } catch (RuntimeException e) {      // not into the window's own event handling
                    Log.d("window event failed: " + e);
                }
            }
        }, AWTEvent.WINDOW_EVENT_MASK);
        for (Frame frame : Frame.getFrames()) {
            markTitle(frame);
            if (containsViewer(frame))
                Icons.viewerWindow(frame);
            Menu.addTo(frame, fix);
        }
        ViewerWatch.install(fix.os == Os.MAC);
        WaylandFrames.install();
        Log.d("installed: os=" + fix.os + " scancode=" + (fix.scancodeField != null)
            + " rawCode=" + (fix.rawCodeField != null) + " macPositions=" + fix.macPositions.size()
            + (fix.os == Os.MAC ? " macPhysicalKeys=" + MacKeys.ready() : ""));
    }

    /**
     * macOS: the viewer's virtual keyboard window is sized for a title bar 6 pixels lower than
     * today's: its bottom row was cut. Once, when it first opens.
     */
    private void keyboardPopup(Window w) {
        if (os == Os.MAC && w.getClass().getName().equals("tw.com.aten.ikvm.ui.onScreenKeyboard")) {
            w.setSize(w.getWidth(), w.getHeight() + 8);
            Log.d("virtual keyboard window 8 pixels higher: " + w.getWidth() + "x" + w.getHeight());
        }
        if (os == Os.MAC && loggedWindows.add(w.getClass().getName()))
            Log.d("window opened: " + w.getClass().getName());
        widenPreferences(w);
    }

    /**
     * The viewer's own preferences window (OptionFrame: Hermon/AST2050), too narrow (macOS:
     * for the Mac font), on every OS: its tabs' preferred width + 140 (it packs to that each time it's shown), and resizable. When it
     * opens, and from ViewerWatch for every showing window (in case the opening was missed).
     */
    static void widenPreferences(Window w) {
        if (!w.isShowing() || !w.getClass().getName().startsWith("tw.com.aten.ikvm.ui.")
                || !w.getClass().getName().endsWith("OptionFrame"))
            return;
        try {
            javax.swing.JComponent tabs = (javax.swing.JComponent) w.getClass().getMethod("getTabbedPane").invoke(w);
            if (tabs.getClientProperty("keypasta.widened") != null)
                return;                             // (closed and opened again: disposed, not hidden)
            tabs.putClientProperty("keypasta.widened", Boolean.TRUE);
            java.awt.Dimension d = tabs.getPreferredSize();
            int before = w.getWidth();
            tabs.setPreferredSize(new java.awt.Dimension(d.width + 140, d.height));
            tabs.invalidate();                      // (setPreferredSize doesn't: pack kept the old size)
            ((java.awt.Frame) w).setResizable(true);
            w.pack();
            Log.d("viewer preferences window " + w.getClass().getSimpleName() + " widened: " + before + " -> " + w.getWidth());
        } catch (Exception ex) {
            Log.d("widening the viewer preferences failed: " + ex);
        }
    }

    /**
     * After a dialog of a viewer window closes (Record: file and size dialogs), or when a viewer
     * window gets the focus, the focus may stay on its toolbar or nowhere: the viewer gets it,
     * unless a text field or another window has it. The focus owner is logged (class only).
     */
    private void refocus(Window w, int id) {
        if (!config.enableKeyFix)
            return;
        final Window viewerWindow = viewerOf(id == WindowEvent.WINDOW_CLOSED && w != null ? w.getOwner() : w);
        if (viewerWindow == null)
            return;
        javax.swing.SwingUtilities.invokeLater(new Runnable() {
            @Override
            public void run() {
                try {
                    Component v = viewerIn(viewerWindow);
                    Component owner = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
                    if (v == null || !viewerWindow.isFocused() || owner == v)
                        return;
                    if (owner instanceof javax.swing.text.JTextComponent || owner instanceof javax.swing.JComboBox)
                        return;
                    Log.d("focus in the viewer window was on " + (owner == null ? "nothing" : owner.getClass().getName())
                        + ": to the viewer");
                    v.requestFocusInWindow();
                } catch (RuntimeException e) {
                    Log.d("refocus failed: " + e);
                }
            }
        });
    }

    private KeyFix(Config config) {
        this.config = config;
        ViewerLayout.config = config;
        config.resolvePaste();
        config.loadPrefs();
        String name = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        os = name.startsWith("windows") ? Os.WINDOWS : name.startsWith("linux") ? Os.LINUX
            : name.startsWith("mac") ? Os.MAC : Os.OTHER;
        if (os == Os.WINDOWS) {
            scancodeField = field("scancode");
            windowsKeyField = field("rawCode");
        } else if (os == Os.LINUX) {
            rawCodeField = field("rawCode");
            locationField = field("keyLocation");
        }
        else if (os == Os.MAC)
            macPositions = Layouts.macPositions(macLayout = localLayout());
        ctrlTimer = new Timer(CTRL_HOLD_MS, new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                try {
                    sendPendingCtrl();
                } catch (RuntimeException ex) {
                    Log.d("Ctrl failed: " + ex);
                }
            }
        });
        ctrlTimer.setRepeats(false);
        paste = new Paste(this);
    }

    private static Field field(String name) {
        try {
            Field f = KeyEvent.class.getDeclaredField(name);
            f.setAccessible(true);
            return f;
        } catch (Exception e) {
            Log.d("KeyEvent." + name + " not readable: " + e);
            return null;
        }
    }

    /**
     * macOS: the input source may have changed since (by hand, or by something else): read again
     * when a viewer window gets active, in the background; the positions follow.
     */
    void refreshMacLayout() {
        if (os != Os.MAC || !config.localLayout.equals("auto"))
            return;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                String l = LocalLayouts.readMacCurrent();
                if (l != null && !l.equals(macLayout)) {      // unreadable: the one in use stays
                    Log.d("local layout now " + l + " (was " + macLayout + ")");
                    macPositions = Layouts.macPositions(l);
                    macLayout = l;
                }
            }
        }, "iKVM-KeyPasta layout");
        t.setDaemon(true);
        t.start();
    }

    private String localLayout() {
        if (!config.localLayout.equals("auto"))
            return config.localLayout;
        String l = LocalLayouts.current();
        return l != null ? l : "us";
    }

    /** The remote's layout for fast paste (see Config.useBmc). */
    String remoteLayout() {
        return config.remoteLayout;
    }

    /**
     * Every frame gets the title keeper, whatever its title now: the .jnlp viewer opens with
     * another title and sets "Java iKVM Viewer v1.69.44 [ip]" only once connected.
     */
    static void markTitle(Window window) {
        if (!(window instanceof Frame))
            return;
        Frame frame = (Frame) window;
        boolean kept = false;
        for (PropertyChangeListener l : frame.getPropertyChangeListeners("title"))
            kept |= l instanceof TitleKeeper;
        if (!kept)
            frame.addPropertyChangeListener("title", new TitleKeeper());
        keepMarker(frame);
    }

    private static void keepMarker(Frame frame) {
        String title = frame.getTitle();
        if (title != null && title.startsWith(TITLE_START) && !title.endsWith(MARKER))
            frame.setTitle(title + MARKER);
    }

    /** iKVM sets and rewrites its title (resolution, frame rate): keep the marker at its end. */
    private static final class TitleKeeper implements PropertyChangeListener {
        @Override
        public void propertyChange(PropertyChangeEvent e) {
            try {
                keepMarker((Frame) e.getSource());
            } catch (RuntimeException ex) {
                Log.d("title failed: " + ex);
            }
        }
    }

    /** The BMC of a viewer window: the [host] in its title ("Java iKVM Viewer v1.69.41 [192.0.2.1] ..."). */
    static String bmcOf(Component c) {
        Window w = c instanceof Window ? (Window) c : c == null ? null : javax.swing.SwingUtilities.getWindowAncestor(c);
        for (; w != null; w = w.getOwner())
            if (w instanceof Frame && containsViewer(w)) {
                java.util.regex.Matcher m = java.util.regex.Pattern.compile("\\[([^\\]]+)\\]").matcher(String.valueOf(((Frame) w).getTitle()));
                return m.find() ? m.group(1).trim() : "";
            }
        return "";
    }

    static Component viewerOfWindow(Window w) {
        return viewerIn(w);
    }

    static boolean isViewerWindow(Window w) {
        return containsViewer(w);
    }

    static boolean isViewer(Component c) {
        return c != null && c.getClass().getName().equals(Agent.VIEWER_CLASS);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        try {
            return dispatch(e);
        } catch (RuntimeException ex) {     // a bug here must not cost the user the key
            Log.d("key handling failed: " + ex);
            return false;
        }
    }

    private boolean dispatch(KeyEvent e) {
        if (injecting)
            return false;
        if (e.getID() == KeyEvent.KEY_PRESSED && (e.getModifiersEx() & (KeyEvent.META_DOWN_MASK | KeyEvent.CTRL_DOWN_MASK)) != 0
                && !isModifier(e.getKeyCode()) && loggedShortcuts < 10) {
            loggedShortcuts++;      // shortcuts only (Cmd, Ctrl), not text: why one didn't work
            Log.d("shortcut " + KeyEvent.getModifiersExText(e.getModifiersEx()) + "+" + KeyEvent.getKeyText(e.getKeyCode())
                + (MacKeys.kvk(e) >= 0 ? " (physical key " + KeyEvent.getKeyText(Layouts.usKey(MacKeys.position(MacKeys.kvk(e)))) + ")" : "")
                + " for " + (e.getComponent() == null ? "-" : e.getComponent().getClass().getName()));
        }
        if (!isViewer(e.getComponent()))
            return retarget(e);
        Component c = e.getComponent();
        viewer = c;
        if (e.getID() == KeyEvent.KEY_PRESSED)
            config.useBmc(bmcOf(c));                // the host's own settings (read once per host)
        if (e.getID() == KeyEvent.KEY_TYPED)
            return paste.busy();
        if (paste.handle(e))
            return true;
        if (!config.enableKeyFix) {
            // keyboard fixes off: the viewer sees the key unchanged, input methods as Java set them
            if (inputMethodsOff != null) {
                inputMethodsOff.enableInputMethods(true);
                inputMethodsOff = null;
            }
            return false;
        }
        if (os != Os.MAC && c != inputMethodsOff) {
            // input methods (dead keys on Linux) would swallow key presses: the remote composes.
            // Not on macOS: with them off, every mouse movement got expensive there (the frame
            // rate dropped from the first key on; seen twice). There a dead key's composition is
            // ended right away instead (see endMacComposition).
            c.enableInputMethods(false);
            inputMethodsOff = c;
        }
        if (isCapsSyncKey(e))
            return true;
        if (os == Os.LINUX && Native.isSyncKey(e)) {
            Log.d("LED sync key dropped: " + (e.getID() == KeyEvent.KEY_PRESSED ? "press" : "release"));
            return true;
        }
        if (handleCtrl(e))
            return true;
        if (os == Os.MAC && e.getID() == KeyEvent.KEY_PRESSED)
            learnMacLayout(e);
        if (os == Os.MAC && e.getKeyCode() == KeyEvent.VK_CLEAR) {
            // the Mac keypad's Clear key sits where NumLock is: the remote's NumLock (macOS has none).
            // iKVM sends a macOS lock key as a tap at its press and again at its release (a Mac's
            // CapsLock: press = on, release = off): its release would toggle it back, so it's dropped.
            if (e.getID() == KeyEvent.KEY_RELEASED)
                return true;
            e.setKeyCode(KeyEvent.VK_NUM_LOCK);
        }
        if (os == Os.MAC && e.getID() == KeyEvent.KEY_PRESSED && e.getKeyLocation() == KeyEvent.KEY_LOCATION_NUMPAD
                && loggedNumpad.add(e.getKeyCode()))
            Log.d("numpad key " + KeyEvent.getKeyText(e.getKeyCode()) + " (" + e.getKeyCode() + ")");
        if (os == Os.MAC && isDeadKey(e.getKeyCode()))
            endMacComposition(c);
        boolean cmdKey = os == Os.MAC && e.getKeyCode() == KeyEvent.VK_META;     // as pressed, before the swap
        if (os == Os.LINUX)
            linuxLocation(e);
        int keyCode = positionalKeyCode(e);
        if (os == Os.MAC && isModifier(e.getKeyCode()) && loggedModifiers.add(e.getKeyCode() * 10 + e.getKeyLocation()))
            Log.d("modifier " + KeyEvent.getKeyText(e.getKeyCode()) + " (" + e.getKeyCode() + ", location "
                + e.getKeyLocation() + ") goes to the viewer as " + keyCode);
        // no key code and no position (e.g. a character composed from a dead key): iKVM would
        // guess a position from the character, so the remote got it twice
        if (keyCode == KeyEvent.VK_UNDEFINED)
            return true;
        e.setKeyCode(keyCode);
        if (os == Os.MAC) {
            // macOS may not report releasing a key while Cmd is held: release them with Cmd
            if (e.getID() == KeyEvent.KEY_RELEASED && cmdKey)
                releaseKeysHeldWithCmd(c, e);
            if (e.getID() == KeyEvent.KEY_PRESSED)
                releasedWithCmd.remove(keyCode);
            else if (releasedWithCmd.remove(keyCode))
                return true;
        }
        // a release without its press (swallowed by an input method): send the press first
        int key = keyCode * 10 + e.getKeyLocation();
        if (e.getID() == KeyEvent.KEY_PRESSED && !(os == Os.MAC && isLockKey(keyCode)))
            pressed.add(key);                       // (macOS lock keys: their release is a tap, see below)
        else if (e.getID() == KeyEvent.KEY_RELEASED && !pressed.remove(key) && Layouts.US_KEY.containsValue(keyCode)
                && !(os == Os.MAC && isLockKey(keyCode)))
            send(c, KeyEvent.KEY_PRESSED, keyCode, e.getKeyLocation(), e.getModifiers(), e.getWhen());
        return false;
    }

    private int loggedShortcuts;
    private final java.util.Set<String> loggedWindows = new java.util.HashSet<String>();
    private final java.util.Set<Integer> loggedModifiers = new java.util.HashSet<Integer>();
    private final java.util.Set<Integer> loggedNumpad = new java.util.HashSet<Integer>();
    private final java.util.Set<Character> loggedBackQuote = new java.util.HashSet<Character>();

    /**
     * macOS: iKVM sends a lock key as a tap at its press and again at its release (a Mac's CapsLock
     * reports on as press, off as release). So none is held in `pressed`: a focus loss would send
     * its release, a tap, and toggle the remote's CapsLock (it did, after every dialog).
     */
    private static boolean isLockKey(int k) {
        return k == KeyEvent.VK_CAPS_LOCK || k == KeyEvent.VK_NUM_LOCK || k == KeyEvent.VK_SCROLL_LOCK;
    }

    private static boolean isDeadKey(int k) {
        return k >= KeyEvent.VK_DEAD_GRAVE && k <= KeyEvent.VK_DEAD_SEMIVOICED_SOUND;
    }

    /**
     * macOS: a dead key starts a composition in the input method (marked text); while it lasts,
     * the next key's press doesn't reach Java (only its release, then the press is sent late, see
     * dispatch). The remote composes itself: the composition is ended right after the dead key.
     * Viewer.getInputContext gives a new context every call: one kept one instead (InputSwitch).
     */
    private void endMacComposition(final Component c) {
        java.awt.EventQueue.invokeLater(new Runnable() {
            @Override
            public void run() {
                try {
                    java.awt.im.InputContext ic = c.getInputContext();
                    if (ic != null)
                        ic.endComposition();
                } catch (RuntimeException ex) {
                    Log.d("ending the composition failed: " + ex);
                }
            }
        });
    }

    /**
     * macOS: a typed key whose key code is its position (not a letter) tells the local layout by
     * its character (; key: ö Swiss German or German, é Swiss French, ; US). If the layout in use
     * doesn't fit, the first one that does is taken: the letters' positions follow at once.
     */
    private void learnMacLayout(KeyEvent e) {
        if (!config.localLayout.equals("auto")
                || (e.getModifiersEx() & (KeyEvent.CTRL_DOWN_MASK | KeyEvent.META_DOWN_MASK | KeyEvent.ALT_DOWN_MASK)) != 0)
            return;
        java.util.List<String> fit = Layouts.macLayoutsFor(e.getKeyCode(), Character.toLowerCase(e.getKeyChar()));
        if (fit == null || fit.isEmpty() || fit.contains(macLayout))
            return;
        Log.d("local layout from a typed key: " + fit.get(0) + " (was " + macLayout + ")");
        macLayout = fit.get(0);
        macPositions = Layouts.macPositions(macLayout);
    }
    private final java.util.Set<String> loggedRetargets = new java.util.HashSet<String>();

    /**
     * A key for another component of a viewer window (its toolbar, a button, the window itself,
     * where the focus may stay after a dialog: the record dialogs, for instance) goes to the
     * viewer instead, which also gets the focus back. Not for text fields, combo boxes and open
     * menus, nor other windows and dialogs.
     */
    private boolean retarget(KeyEvent e) {
        Component c = e.getComponent();
        if (c == null || !config.enableKeyFix || e.getID() == KeyEvent.KEY_TYPED)
            return false;
        Window w = c instanceof Window ? (Window) c : javax.swing.SwingUtilities.getWindowAncestor(c);
        Component v = viewerIn(w);
        if (v == null || !v.isShowing() || c instanceof javax.swing.text.JTextComponent
                || javax.swing.SwingUtilities.getAncestorOfClass(javax.swing.JComboBox.class, c) != null
                || c instanceof javax.swing.JComboBox
                || javax.swing.MenuSelectionManager.defaultManager().getSelectedPath().length > 0)
            return false;
        if (loggedRetargets.add(c.getClass().getName()))
            Log.d("keys for " + c.getClass().getName() + " in the viewer window go to the viewer");
        KeyEvent copy = new KeyEvent(v, e.getID(), e.getWhen(), e.getModifiers(), e.getKeyCode(), e.getKeyChar(),
            e.getKeyLocation());
        try {                                           // the key's position, where Java has it
            for (Field f : new Field[] {scancodeField, rawCodeField, windowsKeyField})
                if (f != null)
                    f.setLong(copy, f.getLong(e));
        } catch (IllegalAccessException ignored) {
        }
        MacKeys.copy(e, copy);
        v.requestFocusInWindow();
        v.dispatchEvent(copy);                          // through this dispatcher, as the viewer's
        return true;
    }

    private static Component viewerIn(Component c) {
        if (isViewer(c))
            return c;
        if (c instanceof Container)
            for (Component child : ((Container) c).getComponents()) {
                Component v = viewerIn(child);
                if (v != null)
                    return v;
            }
        return null;
    }

    /**
     * Linux: Java gives the Windows keys and AltGr no left or right (KEY_LOCATION_STANDARD): set
     * from the X key code (133/134 left/right Windows key, 108 the right Alt key), so the right
     * Windows key (Command in the container's browser view) is the remote's right one, and with
     * Alt and Command swapped its AltGr.
     */
    private void linuxLocation(KeyEvent e) {
        int k = e.getKeyCode();
        if (locationField == null || rawCodeField == null || e.getKeyLocation() != KeyEvent.KEY_LOCATION_STANDARD
                || !(k == KeyEvent.VK_WINDOWS || k == KeyEvent.VK_META || k == KeyEvent.VK_ALT_GRAPH))
            return;
        try {
            long x = rawCodeField.getLong(e);
            int location = x == 133 ? KeyEvent.KEY_LOCATION_LEFT : x == 134 || x == 108 ? KeyEvent.KEY_LOCATION_RIGHT : -1;
            if (location > 0)
                locationField.setInt(e, location);
        } catch (IllegalAccessException ignored) {
        }
    }

    /** Alt, Option, AltGr, Command, the Windows key: what swapAltCmd swaps. */
    private static boolean isAltOrCmd(int k) {
        return k == KeyEvent.VK_ALT || k == KeyEvent.VK_ALT_GRAPH || k == KeyEvent.VK_META || k == KeyEvent.VK_WINDOWS;
    }

    /**
     * Alt and Command swapped (Config.swapAltCmd), by the key's location, which stays: Command
     * (Meta on macOS; the Windows key elsewhere, which Command is in the container's browser view)
     * is the remote's Alt, the right one its AltGr; Alt/Option and AltGr are its Windows key. So
     * a Mac keyboard has Alt next to the space bar, as on a PC (what Karabiner did before).
     */
    private static int swapAltCmd(int k) {
        return k == KeyEvent.VK_ALT || k == KeyEvent.VK_ALT_GRAPH ? KeyEvent.VK_WINDOWS : KeyEvent.VK_ALT;
    }

    private static boolean isModifier(int k) {
        return k == KeyEvent.VK_META || k == KeyEvent.VK_SHIFT || k == KeyEvent.VK_CONTROL || k == KeyEvent.VK_ALT
            || k == KeyEvent.VK_ALT_GRAPH || k == KeyEvent.VK_WINDOWS || k == KeyEvent.VK_CAPS_LOCK;
    }

    private void releaseKeysHeldWithCmd(Component c, KeyEvent e) {
        for (Integer k : new java.util.ArrayList<Integer>(pressed)) {
            if (isModifier(k / 10))
                continue;
            pressed.remove(k);
            releasedWithCmd.add(k / 10);
            send(c, KeyEvent.KEY_RELEASED, k / 10, k % 10, e.getModifiers(), e.getWhen());
        }
    }

    /** The US key code of the key's position, or its own key code if it has no position here. */
    int positionalKeyCode(KeyEvent e) {
        int keyCode = e.getKeyCode();
        if (isAltOrCmd(keyCode) && config.swapAltCmd())
            return swapAltCmd(keyCode);
        if (os == Os.MAC && keyCode == KeyEvent.VK_META)
            return KeyEvent.VK_WINDOWS;     // Command: the remote's Windows key (iKVM leaves Meta out)
        int location = e.getKeyLocation();
        if (location != KeyEvent.KEY_LOCATION_STANDARD && location != KeyEvent.KEY_LOCATION_UNKNOWN)
            return keyCode;         // numpad, left/right modifiers: same position on every layout
        int position = position(e);
        Integer us = Layouts.US_KEY.get(position);
        return us == null ? keyCode : us;
    }

    private int position(KeyEvent e) {
        try {
            if (scancodeField != null) {
                // media and browser keys (volume, play, ...): extended scan codes, whose low byte
                // is that of a letter (Volume Up: E0 30 = B)
                if (windowsKeyField != null) {
                    long vk = windowsKeyField.getLong(e);
                    if (vk >= 0xA6 && vk <= 0xB7)
                        return -1;
                }
                return (int) (scancodeField.getLong(e) & 0xFF);
            }
            if (rawCodeField != null) {
                long x = rawCodeField.getLong(e);
                return x > 8 ? (int) (x - 8) : -1;          // X keycode = Linux key number + 8
            }
        } catch (IllegalAccessException ignored) {
        }
        // macOS: the physical key, if MacKeys could keep it
        int kvk = MacKeys.kvk(e);
        if (kvk >= 0) {
            if (kvk == 0x0A || kvk == 0x32)                 // left of 1 / ISO key: by the character
                return Layouts.macBackQuotePosition(e.getKeyChar());
            return MacKeys.position(kvk);
        }
        // else: Java takes the key code of letters and digits from the character (with Shift
        // too: Z stays Z), all other keys get the US key code of their position (Swiss ' and Shift+'
        // both VK_MINUS). So only those need the local layout; the others are right already.
        int k = e.getKeyCode();
        boolean byCharacter = (k >= KeyEvent.VK_A && k <= KeyEvent.VK_Z) || (k >= KeyEvent.VK_0 && k <= KeyEvent.VK_9)
            || k == KeyEvent.VK_DEAD_CIRCUMFLEX || k == KeyEvent.VK_DEAD_GRAVE || k == KeyEvent.VK_DEAD_DIAERESIS
            || k == KeyEvent.VK_DEAD_ACUTE;
        if (k == KeyEvent.VK_BACK_QUOTE) {
            int p = Layouts.macBackQuotePosition(e.getKeyChar());
            if (e.getID() == KeyEvent.KEY_PRESSED && loggedBackQuote.add(e.getKeyChar()))
                Log.d("key left of 1 / ISO key: character U+" + Integer.toHexString(e.getKeyChar()) + " -> "
                    + (p == 0x56 ? "ISO key" : "left of 1"));
            return p;
        }
        Integer p = byCharacter ? macPositions.get(k) : null;
        return p == null ? -1 : p;
    }

    /**
     * CapsLock follows the active window, like on a KVM switch: leaving a viewer window for another
     * program, the viewer's state (the remote's) is kept and the other programs' state set again;
     * coming back, the viewer's. iKVM tries the same in its native code (Viewer.focusGained /
     * focusLost), which didn't work: the local and the remote CapsLock went apart. A target state,
     * set only when it differs, and a bit later than iKVM's own attempt: if that worked, nothing
     * happens. Moving between a viewer window and its own dialogs changes nothing. Where Java can't
     * set the lock state (macOS, Linux), it does nothing.
     */
    void windowFocus(WindowEvent e) {
        if (!config.enableKeyFix || os != Os.WINDOWS || config.simpleCaps)
            return;                                 // only Windows' Java can set the lock state; Simplify Caps Lock: no syncing
        final Window viewerWindow = viewerOf(e.getWindow());
        if (viewerWindow == null)
            return;
        Window other = viewerOf(e.getOppositeWindow());
        if (other == viewerWindow)
            return;                                 // to or from its own dialog
        boolean outside = other == null;            // another program (or its window gone)
        Boolean local = capsLock();
        if (local == null)
            return;
        if (e.getID() == WindowEvent.WINDOW_DEACTIVATED) {
            viewerCaps.put(viewerWindow, local);
            if (outside && outsideCaps != null && !outsideCaps.equals(local))
                setCapsLock(outsideCaps, "left the viewer");
            return;
        }
        if (outside)
            outsideCaps = local;
        if (!viewerCaps.containsKey(viewerWindow)) {
            viewerCaps.put(viewerWindow, local);    // first time: as iKVM left it on connecting
            return;
        }
        Timer later = new Timer(CAPS_SYNC_DELAY_MS, new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent ev) {
                try {
                    Boolean want = viewerCaps.get(viewerWindow);
                    Boolean now = capsLock();
                    if (want != null && now != null && !want.equals(now) && viewerWindow.isActive())
                        setCapsLock(want, "back in the viewer");
                } catch (RuntimeException ex) {
                    Log.d("CapsLock sync failed: " + ex);
                }
            }
        });
        later.setRepeats(false);
        later.start();
    }

    /** The viewer window w is, or whose dialog it is; null for any other window and for null. */
    private static Window viewerOf(Window w) {
        for (; w != null; w = w.getOwner())
            if (containsViewer(w))
                return w;
        return null;
    }

    private static boolean containsViewer(Component c) {
        if (isViewer(c))
            return true;
        if (c instanceof Container)
            for (Component child : ((Container) c).getComponents())
                if (containsViewer(child))
                    return true;
        return false;
    }

    private static Boolean capsLock() {
        try {
            return Toolkit.getDefaultToolkit().getLockingKeyState(KeyEvent.VK_CAPS_LOCK);
        } catch (RuntimeException e) {          // UnsupportedOperationException on some systems
            return null;
        }
    }

    private void setCapsLock(boolean on, String why) {
        try {
            capsSetAt = System.currentTimeMillis();
            Toolkit.getDefaultToolkit().setLockingKeyState(KeyEvent.VK_CAPS_LOCK, on);
            Log.d("CapsLock set " + (on ? "on" : "off") + ": " + why);
        } catch (RuntimeException e) {          // macOS, Linux: can't be set from Java
            Log.d("CapsLock can't be set here: " + e);
        }
    }

    /**
     * The CapsLock key Windows sends when the lock state is set (by setCapsLock, or iKVM's own LED
     * sync): no key press, so not for the remote, where it would toggle CapsLock again. It has no
     * scan code; right after setCapsLock any CapsLock key counts, should a system give it one.
     */
    private boolean isCapsSyncKey(KeyEvent e) {
        if (os != Os.WINDOWS || e.getKeyCode() != KeyEvent.VK_CAPS_LOCK)
            return false;
        long scan = -1;
        try {
            if (scancodeField != null)
                scan = scancodeField.getLong(e);
        } catch (IllegalAccessException ignored) {
        }
        if (scan != 0 && System.currentTimeMillis() - capsSetAt > CAPS_KEY_WINDOW_MS)
            return false;
        Log.d("CapsLock sync key dropped: " + (e.getID() == KeyEvent.KEY_PRESSED ? "press" : "release")
            + " scan=" + scan);
        return true;
    }

    /**
     * Left Ctrl is held back briefly: Windows adds one right before every AltGr (dropped then).
     * Otherwise it's sent on, right away when another key goes down, followed by the F24 release.
     */
    private boolean handleCtrl(KeyEvent e) {
        boolean leftCtrl = e.getKeyCode() == KeyEvent.VK_CONTROL && e.getKeyLocation() == KeyEvent.KEY_LOCATION_LEFT;
        if (e.getID() == KeyEvent.KEY_PRESSED && leftCtrl) {
            if (ctrlSent || pendingCtrl != null)
                return true;                        // key repeat
            if (os != Os.WINDOWS) {                 // no AltGr Ctrl there: send right away
                pendingCtrl = e;
                sendPendingCtrl();
                return true;
            }
            pendingCtrl = e;
            ctrlTimer.restart();
            return true;
        }
        if (e.getID() == KeyEvent.KEY_RELEASED && leftCtrl) {
            if (ctrlDropped) {
                ctrlDropped = false;
                return true;
            }
            sendPendingCtrl();                      // tapped quicker than the hold back
            ctrlSent = false;
            return false;
        }
        if (e.getID() == KeyEvent.KEY_PRESSED && pendingCtrl != null) {
            boolean rightAlt = e.getKeyCode() == KeyEvent.VK_ALT_GRAPH
                || (e.getKeyCode() == KeyEvent.VK_ALT && e.getKeyLocation() == KeyEvent.KEY_LOCATION_RIGHT);
            if (rightAlt && Math.abs(e.getWhen() - pendingCtrl.getWhen()) <= ALTGR_GAP_MS) {
                pendingCtrl = null;
                ctrlTimer.stop();
                ctrlDropped = true;
            } else
                sendPendingCtrl();
        }
        return false;
    }

    private void sendPendingCtrl() {
        ctrlTimer.stop();
        KeyEvent ctrl = pendingCtrl;
        if (ctrl == null)
            return;
        pendingCtrl = null;
        ctrlSent = true;
        ctrlDropped = false;
        Component c = ctrl.getComponent();
        send(c, KeyEvent.KEY_PRESSED, KeyEvent.VK_CONTROL, KeyEvent.KEY_LOCATION_LEFT, ctrl.getModifiers(), ctrl.getWhen());
        send(c, KeyEvent.KEY_RELEASED, KeyEvent.VK_F24, KeyEvent.KEY_LOCATION_STANDARD, ctrl.getModifiers(), ctrl.getWhen());
    }

    /**
     * The viewer lost the focus: its key releases go elsewhere now. Release what the remote has
     * down; Alt or Windows (Command) broken up with a Ctrl tap first, as they would act alone.
     */
    private void reset() {
        ctrlTimer.stop();
        pendingCtrl = null;
        try {
            if (viewer != null && (ctrlSent || !pressed.isEmpty())) {
                long now = System.currentTimeMillis();
                boolean altOrWin = false;
                for (Integer k : pressed)
                    altOrWin |= k / 10 == KeyEvent.VK_ALT || k / 10 == KeyEvent.VK_WINDOWS;
                if (altOrWin) {
                    send(viewer, KeyEvent.KEY_PRESSED, KeyEvent.VK_CONTROL, KeyEvent.KEY_LOCATION_LEFT, 0, now);
                    send(viewer, KeyEvent.KEY_RELEASED, KeyEvent.VK_CONTROL, KeyEvent.KEY_LOCATION_LEFT, 0, now);
                } else if (ctrlSent)
                    send(viewer, KeyEvent.KEY_RELEASED, KeyEvent.VK_CONTROL, KeyEvent.KEY_LOCATION_LEFT, 0, now);
                for (Integer k : pressed)
                    send(viewer, KeyEvent.KEY_RELEASED, k / 10, k % 10, 0, now);
            }
        } finally {
            ctrlSent = false;
            ctrlDropped = false;
            pressed.clear();
            releasedWithCmd.clear();
            paste.reset();
        }
    }

    /** A key event to the viewer, past this dispatcher. Event dispatch thread only. */
    void send(Component c, int id, int keyCode, int location, int modifiers, long when) {
        injecting = true;
        try {
            c.dispatchEvent(new KeyEvent(c, id, when, modifiers, keyCode, KeyEvent.CHAR_UNDEFINED, location));
        } finally {
            injecting = false;
        }
    }
}
