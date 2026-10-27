package keypasta;

import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.Container;
import java.awt.Dimension;
import java.awt.EventQueue;
import java.awt.Font;
import java.awt.Insets;
import java.awt.LayoutManager;
import java.awt.Rectangle;
import java.awt.Toolkit;
import java.awt.event.AWTEventListener;
import java.awt.event.ContainerEvent;
import java.awt.event.HierarchyEvent;
import java.awt.event.WindowEvent;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import javax.swing.AbstractButton;
import javax.swing.JComponent;
import javax.swing.JLabel;
import javax.swing.JMenuItem;
import javax.swing.plaf.ComponentUI;

/**
 * macOS, IPMIView: labels and buttons whose text doesn't fit ("Health e...", "Sta..."). IPMIView's
 * panels give many of them fixed widths, sized for its narrow PMingLiU font; with the Mac's font
 * (Fonts) the text is cut. Whenever a part of a window becomes visible, each JLabel and button in it
 * whose width is less than its text needs gets what it needs:
 * <ul>
 * <li>a width of its own (IPMIView's setPreferredSize, in a layout that follows it): wider;</li>
 * <li>a fixed place (no layout, or NetBeans' AbsoluteLayout): wider, when that doesn't cover another
 * part or go past its panel's edge;</li>
 * <li>still too narrow after that (no room): its font smaller, down to 11 pt, if the text then fits;
 * else as it was, with the whole text as its tooltip.</li>
 * </ul>
 * macOS only; on Windows and Linux only the main window is made wider (mainWider).
 * Each text is fitted once (again when it changes and the part is shown again). Also a dialog smaller
 * than its content grows (fitDialog).
 */
final class Widen {
    private static final float MIN_SIZE = 11f;
    private static final String DONE = "iKVM-KeyPasta.fitted";
    private static boolean started;
    private static final Set<Component> pending = new LinkedHashSet<Component>();

    private Widen() {
    }

    /** From the class loading of IPMIView's main class: AWT only from a thread of its own. */
    static synchronized void install() {
        if (started)
            return;
        started = true;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                EventQueue.invokeLater(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            IPMIViewLogin.install();    // show password, firmware update login filled
                        } catch (Throwable t) {
                            Log.d("IPMIView login convenience not installed: " + t);
                        }
                        if (Icons.isMac() || Config.LINUX)    // their fonts: Fonts
                            watch();
                        else
                            watchMain();
                    }
                });
            }
        }, "iKVM-KeyPasta widen");
        t.setDaemon(true);
        t.start();
    }

    /** Windows, Linux: only the main window a bit wider (mainWider). */
    static void watchMain() {
        WaylandFrames.install();
        Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
            @Override
            public void eventDispatched(AWTEvent e) {
                try {
                    if (e.getID() == WindowEvent.WINDOW_OPENED)
                        mainWider(((WindowEvent) e).getWindow());
                } catch (RuntimeException ex) {
                    Log.d("widen failed: " + ex);
                }
            }
        }, AWTEvent.WINDOW_EVENT_MASK);
    }

    static void watch() {
        Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
            @Override
            public void eventDispatched(AWTEvent e) {
                try {
                    if (e instanceof HierarchyEvent) {
                        HierarchyEvent h = (HierarchyEvent) e;
                        // once per change, at the part that changed (its children get the event too)
                        if ((h.getChangeFlags() & HierarchyEvent.SHOWING_CHANGED) != 0
                                && h.getChanged() == h.getComponent() && h.getComponent().isShowing())
                            later(h.getComponent());
                    } else if (e instanceof ContainerEvent && e.getID() == ContainerEvent.COMPONENT_ADDED) {
                        Component c = ((ContainerEvent) e).getChild();
                        if (c.isShowing())
                            later(c);
                    } else if (e.getID() == WindowEvent.WINDOW_OPENED) {
                        fitFixedLayout(((WindowEvent) e).getWindow());
                        later(((WindowEvent) e).getWindow());
                        mainWider(((WindowEvent) e).getWindow());
                    }
                } catch (RuntimeException ex) {
                    Log.d("widen failed: " + ex);
                }
            }
        }, AWTEvent.CONTAINER_EVENT_MASK | AWTEvent.HIERARCHY_EVENT_MASK | AWTEvent.WINDOW_EVENT_MASK);
    }

    private static boolean mainWidened;

    /**
     * IPMIView's main window, once when it opens, within the screen, after IPMIView's own resize
     * right after showing it (main: its packed size + 1 wide, + 30 high). macOS: 1144 pixels wide
     * (IPMIView makes it about 900, for its narrow font; the user doesn't want it resized by the
     * panels it shows), and its edges (mainEdges). Windows: 20 pixels wider than IPMIView makes it; Linux
     * (its wider font, Fonts): 60.
     */
    private static void mainWider(final java.awt.Window w) {
        if (mainWidened || !Icons.IPMIVIEW_MAIN.replace('/', '.').equals(w.getClass().getName()))
            return;
        mainWidened = true;
        mainWindow = w;
        EventQueue.invokeLater(new Runnable() {
            @Override
            public void run() {
                Rectangle screen = w.getGraphicsConfiguration().getBounds();
                // maximised by the window manager (the Mac app's container makes it fill the
                // desktop): a new size would undo that
                if (w instanceof java.awt.Frame && (((java.awt.Frame) w).getExtendedState() & java.awt.Frame.MAXIMIZED_BOTH) != 0
                        || w.getWidth() >= screen.width - 2) {
                    Log.d("IPMIView window maximised: left as it is");
                    return;
                }
                int width = Math.min(Icons.isMac() ? 1144 : w.getPreferredSize().width + 1 + (Config.LINUX ? 60 : 20), screen.width);
                int x = Math.max(screen.x, Math.min(w.getX() - (width - w.getWidth()) / 2, screen.x + screen.width - width));
                Log.d("IPMIView window " + w.getWidth() + " -> " + width + " wide");
                w.setBounds(x, w.getY(), width, w.getHeight());
                if (Icons.isMac() && w instanceof javax.swing.RootPaneContainer)
                    mainEdges(((javax.swing.RootPaneContainer) w).getContentPane());
                w.validate();
            }
        });
    }

    private static java.awt.Window mainWindow;

    /**
     * IPMIView's main window: the split pane that fills it without its border (a line along the
     * window's left, right and bottom edges), and the status line at the bottom without its etched
     * border and with room at both ends (macOS rounds the window's corners over its text).
     */
    private static void mainEdges(Container content) {
        for (Component c : content.getComponents()) {
            if (c instanceof javax.swing.JSplitPane) {
                ((JComponent) c).setBorder(javax.swing.BorderFactory.createEmptyBorder());
                Log.d("main split pane without its border");
            } else if (c instanceof javax.swing.JPanel && c.getY() + c.getHeight() >= content.getHeight() - 1
                    && ((JComponent) c).getBorder() != null && c.getHeight() < 40) {
                ((JComponent) c).setBorder(javax.swing.BorderFactory.createEmptyBorder(2, 12, 2, 12));
                Log.d("status line without its border, with margins");
            } else if (c instanceof Container && c.getClass() == javax.swing.JPanel.class) {
                mainEdges((Container) c);                  // IPMIView's panel inside the content pane
            }
        }
    }

    /** After the layout that's on its way. */
    private static void later(Component c) {
        if (!pending.isEmpty()) {
            pending.add(c);
            return;
        }
        pending.add(c);
        EventQueue.invokeLater(new Runnable() {
            @Override
            public void run() {
                List<Component> roots = new ArrayList<Component>(pending);
                pending.clear();
                Set<Component> windows = new LinkedHashSet<Component>();
                for (Component r : roots) {
                    Component w = javax.swing.SwingUtilities.getRoot(r);
                    if (w != null)
                        windows.add(w);
                }
                for (Component r : roots)
                    FlatTabs.flatten(r);
                for (Component w : windows)
                    w.validate();                          // the sizes to compare with
                Set<JComponent> narrow = new LinkedHashSet<JComponent>();
                for (Component r : roots)
                    collect(r, narrow);
                if (narrow.isEmpty())
                    return;
                for (JComponent n : narrow)
                    widen(n);
                for (Component w : windows)
                    fitDialog(w);
                for (Component w : windows)
                    w.validate();
                for (JComponent n : narrow)                // what's still too narrow
                    shrink(n);
            }
        });
    }

    private static String text(Component c) {
        if (c instanceof JMenuItem)
            return null;                                   // menus size themselves
        String t = c instanceof JLabel ? ((JLabel) c).getText()
            : c instanceof AbstractButton ? ((AbstractButton) c).getText() : null;
        if (t == null || t.trim().isEmpty() || t.regionMatches(true, 0, "<html", 0, 5))
            return null;
        return t;
    }

    /** What the text needs, by the look and feel, whatever width was set. */
    private static int need(JComponent c) {
        ComponentUI ui = c instanceof JLabel ? ((JLabel) c).getUI()
            : c instanceof AbstractButton ? ((AbstractButton) c).getUI() : null;
        Dimension d = ui == null ? null : ui.getPreferredSize(c);
        return d == null ? -1 : d.width;
    }

    /**
     * A dialog smaller than its content wants (IPMIView sets fixed sizes, made for its narrow font,
     * e.g. its Flash Tool): as big as that, within the screen.
     */
    private static void fitDialog(Component c) {
        if (!(c instanceof java.awt.Dialog))
            return;
        java.awt.Dialog d = (java.awt.Dialog) c;
        Dimension want = d.getPreferredSize();
        Rectangle screen = d.getGraphicsConfiguration().getBounds();
        // at most half again its size and 80 % of the screen (some content wants far more than it needs)
        int w = Math.min(Math.max(d.getWidth(), want.width), Math.min(d.getWidth() * 3 / 2, screen.width * 4 / 5));
        int h = Math.min(Math.max(d.getHeight(), want.height), Math.min(d.getHeight() * 3 / 2, screen.height * 4 / 5));
        w = Math.max(w, d.getWidth());
        h = Math.max(h, d.getHeight());
        if (w == d.getWidth() && h == d.getHeight())
            return;
        Log.d("dialog " + d.getWidth() + "x" + d.getHeight() + " -> " + w + "x" + h + ": " + d.getTitle());
        int x = Math.max(screen.x, Math.min(d.getX(), screen.x + screen.width - w));
        int y = Math.max(screen.y, Math.min(d.getY(), screen.y + screen.height - h));
        d.setBounds(x, y, w, h);
    }

    /**
     * A window whose content is placed by coordinates (no layout: IPMIView's Flash Tool) and sized
     * by a fixed setSize for its frame: bigger, so its content's right and bottom edges show. Its
     * frame took more than IPMIView counted with (WSLg: 38 px a side, 59 on top: the Flash Tool's
     * Browse and FW Version buttons were off its right edge). Once, when it opens.
     */
    static void fitFixedLayout(java.awt.Window w) {
        if (!(w instanceof javax.swing.RootPaneContainer))
            return;
        Container content = ((javax.swing.RootPaneContainer) w).getContentPane();
        w.validate();
        Dimension need = new Dimension(0, 0);
        extent(content, content, need);
        int dw = need.width + 2 - content.getWidth(), dh = need.height + 2 - content.getHeight();
        if (need.width == 0 || (dw <= 0 && dh <= 0))
            return;
        Dimension size = new Dimension(w.getWidth() + Math.max(0, dw), w.getHeight() + Math.max(0, dh));
        Rectangle screen = w.getGraphicsConfiguration().getBounds();
        size.width = Math.min(size.width, screen.width);
        size.height = Math.min(size.height, screen.height);
        w.setMaximumSize(null);
        w.setMinimumSize(size);
        w.setSize(size);
        w.validate();
        Log.d("window " + w.getClass().getSimpleName() + " bigger for its content: " + w.getWidth() + "x" + w.getHeight());
    }

    /** The right and bottom edges of what containers without a layout hold, in content coordinates. */
    private static void extent(Container c, Container content, Dimension need) {
        for (Component child : c.getComponents()) {
            if (!child.isVisible())
                continue;
            if (c.getLayout() == null) {
                java.awt.Point p = javax.swing.SwingUtilities.convertPoint(c, child.getX(), child.getY(), content);
                need.width = Math.max(need.width, p.x + child.getWidth() + c.getInsets().right);
                need.height = Math.max(need.height, p.y + child.getHeight() + c.getInsets().bottom);
            }
            if (child instanceof Container)
                extent((Container) child, content, need);
        }
    }

    /** The width it shows: its own, or less where its panel ends before it does. */
    private static int room(JComponent c) {
        Container p = c.getParent();
        int w = c.getWidth();
        if (p != null && p.getWidth() > 0)
            w = Math.min(w, p.getWidth() - p.getInsets().right - c.getX());
        return w;
    }

    private static void collect(Component c, Set<JComponent> out) {
        if (!c.isShowing())
            return;
        String t = text(c);
        if (t != null && !t.equals(((JComponent) c).getClientProperty(DONE))) {
            JComponent j = (JComponent) c;
            int need = need(j);
            if (j.getWidth() > 0 && need > room(j))
                out.add(j);
            else if (j.getWidth() > 0)
                j.putClientProperty(DONE, t);
        }
        if (c instanceof Container)
            for (Component child : ((Container) c).getComponents())
                collect(child, out);
    }

    private static void widen(JComponent c) {
        int need = need(c);
        Container p = c.getParent();
        if (p == null || need <= room(c))
            return;
        int clipped = need - room(c);
        if (c.getWidth() >= need && p instanceof JComponent && ((JComponent) p).isPreferredSizeSet()) {
            // wide enough itself, but its panel (a width of its own) ends before: the panel wider
            Dimension d = p.getPreferredSize();
            ((JComponent) p).setPreferredSize(new Dimension(d.width + clipped, d.height));
            Log.d("panel widened: " + text(c));
            p.revalidate();
            return;
        }
        LayoutManager l = p.getLayout();
        boolean absolute = l != null && l.getClass().getName().endsWith("AbsoluteLayout");
        if (l == null || absolute) {
            // wider to the right, else to the left; push buttons the other way round (they're usually
            // lined up by their right edges)
            Rectangle old = c.getBounds(), r = null;
            Insets in = p.getInsets();
            boolean button = c instanceof javax.swing.JButton;
            int right = old.x, left = old.x + old.width - need;
            for (int x : button ? new int[] {left, Integer.MIN_VALUE, right} : new int[] {right, left}) {
                if (x == Integer.MIN_VALUE) {                // a button: the field to its left shorter
                    r = l == null ? besideField(p, c, old, need, in) : null;
                    if (r != null)
                        break;
                    continue;
                }
                Rectangle t = new Rectangle(x, old.y, need, old.height);
                if (t.x < in.left || t.x + t.width > p.getWidth() - in.right)
                    continue;
                boolean free = true;
                for (Component s : p.getComponents())
                    if (s != c && s.isVisible() && !blank(s) && s.getBounds().intersects(t) && !s.getBounds().intersects(old))
                        free = false;                      // would cover another part
                if (free) {
                    r = t;
                    break;
                }
            }
            if (r == null)
                return;                                    // shrink() then
            if (absolute && !absoluteBounds(l, c, r))
                return;
            c.setBounds(r);
            Log.d("widened (" + (absolute ? "AbsoluteLayout" : "no layout") + (r.x != old.x ? ", to the left" : "") + "): " + text(c));
        } else if (c.isPreferredSizeSet()) {
            Dimension d = c.getPreferredSize();
            c.setPreferredSize(new Dimension(need, d.height));
            if (c.isMaximumSizeSet() && c.getMaximumSize().width < need)
                c.setMaximumSize(new Dimension(need, c.getMaximumSize().height));
            if (c.isMinimumSizeSet() && c.getMinimumSize().width < need)
                c.setMinimumSize(new Dimension(need, c.getMinimumSize().height));
            Log.d("widened (" + l.getClass().getSimpleName() + "): " + text(c));
        } else {
            return;
        }
        p.revalidate();
        p.repaint();
    }

    /** An empty label (no text, no icon, no border): nothing to cover. */
    private static boolean blank(Component s) {
        if (!(s instanceof JLabel))
            return false;
        JLabel l = (JLabel) s;
        return (l.getText() == null || l.getText().trim().isEmpty()) && l.getIcon() == null && l.getBorder() == null;
    }

    /**
     * A button at the right of a text field (IPMIView's "Browse..."): wider to the left, the field
     * that much shorter, if it keeps at least 80 pixels and half its width. Null: no such field.
     */
    private static Rectangle besideField(Container p, Component c, Rectangle old, int need, Insets in) {
        Rectangle t = new Rectangle(old.x + old.width - need, old.y, need, old.height);
        if (t.x < in.left)
            return null;
        Component field = null;
        for (Component s : p.getComponents()) {
            if (s == c || !s.isVisible() || blank(s) || !s.getBounds().intersects(t) || s.getBounds().intersects(old))
                continue;
            if (field != null || !(s instanceof javax.swing.text.JTextComponent || s instanceof javax.swing.JComboBox))
                return null;                               // something else, or two of them
            field = s;
        }
        if (field == null)
            return t;
        Rectangle f = field.getBounds();
        int width = t.x - 6 - f.x;                         // 6 px apart
        if (width < 80 || width < f.width / 2)
            return null;
        field.setBounds(f.x, f.y, width, f.height);
        for (Component s : p.getComponents())              // fields lined up with it (IP above File) too
            if (s != field && (s instanceof javax.swing.text.JTextComponent || s instanceof javax.swing.JComboBox)
                    && s.getX() == f.x && s.getWidth() == f.width)
                s.setSize(width, s.getHeight());
        Log.d("field shorter for a button: " + text(c));
        return t;
    }

    /** NetBeans' AbsoluteLayout keeps x, y, width, height per part (public fields). */
    @SuppressWarnings("rawtypes")
    private static boolean absoluteBounds(LayoutManager l, Component c, Rectangle r) {
        try {
            Field f = l.getClass().getDeclaredField("constraints");
            f.setAccessible(true);
            Object k = ((Map) f.get(l)).get(c);
            if (k == null)
                return false;
            k.getClass().getField("x").setInt(k, r.x);
            Field w = k.getClass().getField("width");
            if (w.getInt(k) > 0)
                w.setInt(k, r.width);
            return true;
        } catch (Exception e) {
            Log.d("AbsoluteLayout: " + e);
            return false;
        }
    }

    private static void shrink(JComponent c) {
        String t = text(c);
        if (t == null || c.getWidth() <= 0)
            return;
        c.putClientProperty(DONE, t);
        Font f = c.getFont();
        if (f == null || need(c) <= room(c))
            return;
        float size = f.getSize2D();
        while (size > MIN_SIZE && need(c) > room(c)) {
            size = Math.max(MIN_SIZE, size - 0.5f);
            c.setFont(f.deriveFont(size));
        }
        if (need(c) <= room(c)) {
            Log.d("smaller font (" + size + "): " + t);
        } else {
            c.setFont(f);                                  // no help: its own font, the whole text on hover
            if (c.getToolTipText() == null)
                c.setToolTipText(t);
            Log.d("no room, tooltip: " + t);
        }
    }
}
