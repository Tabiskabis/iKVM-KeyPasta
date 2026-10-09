package keypasta;

import java.awt.AWTEvent;
import java.awt.Component;
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
import java.awt.im.InputContext;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;
import java.lang.reflect.Field;
import java.util.Collections;
import java.util.Locale;
import java.util.Map;
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
 * - Lock keys only work as one quick tap in stable mode: CapsLock is sent as a tap (Windows;
 *   iKVM does this itself on other systems).
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
    private Map<Integer, Integer> macPositions = Collections.emptyMap();

    /** Events this class dispatches itself pass through untouched. */
    private boolean injecting;

    private KeyEvent pendingCtrl;
    private boolean ctrlSent;
    private boolean ctrlDropped;
    private final Timer ctrlTimer;
    private boolean capsHeld;
    private Component inputMethodsOff;
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
                    if (event.getID() == WindowEvent.WINDOW_OPENED || event.getID() == WindowEvent.WINDOW_ACTIVATED)
                        markTitle(((WindowEvent) event).getWindow());
                    // keys released in another window never come back here
                    if (event.getID() == WindowEvent.WINDOW_DEACTIVATED)
                        fix.reset();
                } catch (RuntimeException e) {      // not into the window's own event handling
                    Log.d("window event failed: " + e);
                }
            }
        }, AWTEvent.WINDOW_EVENT_MASK);
        for (Frame frame : Frame.getFrames())
            markTitle(frame);
        Log.d("installed: os=" + fix.os + " scancode=" + (fix.scancodeField != null)
            + " rawCode=" + (fix.rawCodeField != null) + " macPositions=" + fix.macPositions.size());
    }

    private KeyFix(Config config) {
        this.config = config;
        config.resolvePaste();
        String name = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        os = name.startsWith("windows") ? Os.WINDOWS : name.startsWith("linux") ? Os.LINUX
            : name.startsWith("mac") ? Os.MAC : Os.OTHER;
        if (os == Os.WINDOWS) {
            scancodeField = field("scancode");
            windowsKeyField = field("rawCode");
        } else if (os == Os.LINUX)
            rawCodeField = field("rawCode");
        else if (os == Os.MAC)
            macPositions = Layouts.macPositions(localLayout());
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
     * The local input locale: Windows reports the keyboard layout's language and country. macOS
     * may report a language only, Linux the system locale: then the country of the system locale.
     */
    private static Locale inputLocale() {
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

    private String localLayout() {
        if (!config.localLayout.equals("auto"))
            return config.localLayout;
        Locale locale = inputLocale();
        Log.d("input locale " + locale);
        if (locale.getCountry().equals("CH"))
            return locale.getLanguage().equals("fr") ? "fr-CH" : "de-CH";
        return "us";
    }

    /** Swiss layout of the remote for fast paste. */
    boolean remoteFrench() {
        if (!config.remoteLayout.equals("auto"))
            return config.remoteLayout.equals("fr-CH");
        Locale locale = inputLocale();
        return locale.getCountry().equals("CH") && locale.getLanguage().equals("fr");
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
        if (injecting || !isViewer(e.getComponent()))
            return false;
        Component c = e.getComponent();
        viewer = c;
        if (c != inputMethodsOff) {
            // input methods (dead keys on Linux) would swallow key presses: the remote composes
            c.enableInputMethods(false);
            inputMethodsOff = c;
        }
        if (e.getID() == KeyEvent.KEY_TYPED)
            return paste.busy();
        if (paste.handle(e))
            return true;
        if (handleCtrl(e))
            return true;
        if (os == Os.WINDOWS && handleCapsLock(e))
            return true;
        int keyCode = positionalKeyCode(e);
        // no key code and no position (e.g. a character composed from a dead key): iKVM would
        // guess a position from the character, so the remote got it twice
        if (keyCode == KeyEvent.VK_UNDEFINED)
            return true;
        e.setKeyCode(keyCode);
        if (os == Os.MAC) {
            // macOS may not report releasing a key while Cmd is held: release them with Cmd
            if (e.getID() == KeyEvent.KEY_RELEASED && keyCode == KeyEvent.VK_WINDOWS)
                releaseKeysHeldWithCmd(c, e);
            if (e.getID() == KeyEvent.KEY_PRESSED)
                releasedWithCmd.remove(keyCode);
            else if (releasedWithCmd.remove(keyCode))
                return true;
        }
        // a release without its press (swallowed by an input method): send the press first
        int key = keyCode * 10 + e.getKeyLocation();
        if (e.getID() == KeyEvent.KEY_PRESSED)
            pressed.add(key);
        else if (e.getID() == KeyEvent.KEY_RELEASED && !pressed.remove(key) && Layouts.US_KEY.containsValue(keyCode))
            send(c, KeyEvent.KEY_PRESSED, keyCode, e.getKeyLocation(), e.getModifiers(), e.getWhen());
        return false;
    }

    private static boolean isModifier(int k) {
        return k == KeyEvent.VK_SHIFT || k == KeyEvent.VK_CONTROL || k == KeyEvent.VK_ALT
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
        // macOS: Java takes the key code of letters and digits from the character (with Shift
        // too: Z stays Z), all other keys get the US key code of their position (Swiss ' and Shift+'
        // both VK_MINUS). So only those need the local layout; the others are right already.
        int k = e.getKeyCode();
        boolean byCharacter = (k >= KeyEvent.VK_A && k <= KeyEvent.VK_Z) || (k >= KeyEvent.VK_0 && k <= KeyEvent.VK_9)
            || k == KeyEvent.VK_DEAD_CIRCUMFLEX || k == KeyEvent.VK_DEAD_GRAVE || k == KeyEvent.VK_DEAD_DIAERESIS;
        Integer p = byCharacter ? macPositions.get(k) : null;
        return p == null ? -1 : p;
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
            capsHeld = false;
            pressed.clear();
            releasedWithCmd.clear();
            paste.reset();
        }
    }

    /** CapsLock as one quick tap, key repeat dropped. */
    private boolean handleCapsLock(KeyEvent e) {
        if (e.getKeyCode() != KeyEvent.VK_CAPS_LOCK)
            return false;
        if (e.getID() == KeyEvent.KEY_PRESSED && !capsHeld) {
            capsHeld = true;
            send(e.getComponent(), KeyEvent.KEY_PRESSED, KeyEvent.VK_CAPS_LOCK, KeyEvent.KEY_LOCATION_STANDARD, 0, e.getWhen());
            send(e.getComponent(), KeyEvent.KEY_RELEASED, KeyEvent.VK_CAPS_LOCK, KeyEvent.KEY_LOCATION_STANDARD, 0, e.getWhen());
        } else if (e.getID() == KeyEvent.KEY_RELEASED)
            capsHeld = false;
        return true;
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
