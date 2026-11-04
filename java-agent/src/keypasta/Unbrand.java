package keypasta;

import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.Container;
import java.awt.Frame;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.AWTEventListener;
import java.awt.event.MouseListener;
import java.awt.event.WindowEvent;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;
import java.lang.reflect.Field;
import javax.swing.Icon;
import javax.swing.JLabel;
import javax.swing.SwingUtilities;

/**
 * IPMIView's main window without Supermicro's brand: its title without " - Super Micro Computer,
 * Inc." (IPMIView sets it once in its constructor; set again, it's taken off again), and without
 * the logo at the top left (superLogo2014.jpg, a link to supermicro.com: a JLabel in a panel at
 * the North of its field jPanel3): that panel is removed, the BMC list moves up. IPMIView's files
 * stay unchanged.
 */
final class Unbrand {
    private static final String BRAND = " - Super Micro Computer, Inc.";
    private static boolean installed;

    private Unbrand() {
    }

    /** From the class loading of IPMIView's main class (Agent). */
    static synchronized void install() {
        if (installed)
            return;
        installed = true;
        SwingUtilities.invokeLater(new Runnable() {
            @Override
            public void run() {
                for (Frame f : Frame.getFrames())
                    window(f);
                Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
                    @Override
                    public void eventDispatched(AWTEvent e) {
                        if (e.getID() == WindowEvent.WINDOW_OPENED)
                            window(((WindowEvent) e).getWindow());
                    }
                }, AWTEvent.WINDOW_EVENT_MASK);
            }
        });
    }

    private static void window(Window w) {
        if (!(w instanceof Frame) || !Icons.IPMIVIEW_MAIN.replace('/', '.').equals(w.getClass().getName()))
            return;
        final Frame f = (Frame) w;
        try {
            title(f);
            f.addPropertyChangeListener("title", new PropertyChangeListener() {
                @Override
                public void propertyChange(PropertyChangeEvent e) {
                    title(f);
                }
            });
        } catch (Throwable t) {
            Log.d("IPMIView title not changed: " + t);
        }
        try {
            logo(f);
        } catch (Throwable t) {
            Log.d("IPMIView logo not replaced: " + t);
        }
    }

    private static void title(Frame f) {
        String t = f.getTitle();
        if (t != null && t.endsWith(BRAND))
            f.setTitle(t.substring(0, t.length() - BRAND.length()));
    }

    private static boolean logoDone;

    private static void logo(Frame f) throws Exception {
        if (logoDone)
            return;
        Field panel3 = f.getClass().getDeclaredField("jPanel3");
        panel3.setAccessible(true);
        JLabel label = logoLabel((Container) panel3.get(f));
        if (label == null) {
            Log.d("IPMIView logo not found");
            return;
        }
        logoDone = true;
        Container top = (Container) panel3.get(f);
        Component panel = label;
        while (panel.getParent() != null && panel.getParent() != top)
            panel = panel.getParent();              // the logo's panel, at jPanel3's North
        if (panel.getParent() != top) {
            Log.d("IPMIView logo's panel not found");
            return;
        }
        int width = panel.getPreferredSize().width;
        top.remove(panel);
        top.revalidate();
        top.repaint();
        Log.d("IPMIView logo removed");
        keepListWidth(f, width);
    }

    /**
     * The BMC list's split pane (jSplitPane1) took its divider place from its left side's preferred
     * width, which the logo set: without it the split pane sometimes laid the list out collapsed
     * (divider at the left edge, seen under WSLg). Its place set to IPMIView's own default
     * (dividerDefaultLoc: the logo's width + the divider), else the logo panel's width.
     */
    private static void keepListWidth(Frame f, int logoWidth) {
        try {
            Field splitField = f.getClass().getDeclaredField("jSplitPane1");
            splitField.setAccessible(true);
            javax.swing.JSplitPane split = (javax.swing.JSplitPane) splitField.get(f);
            int place = 0;
            try {
                Field def = f.getClass().getDeclaredField("dividerDefaultLoc");
                def.setAccessible(true);
                place = def.getInt(f);
            } catch (NoSuchFieldException e) {
                // older IPMIView: the logo's width
            }
            if (place <= split.getDividerSize())
                place = logoWidth + split.getDividerSize();
            split.setDividerLocation(place);
            Log.d("IPMIView BMC list " + place + " pixels wide");
        } catch (Throwable t) {
            Log.d("IPMIView BMC list width not set: " + t);
        }
    }

    /** The label with an image and IPMIView's own mouse listener: the logo. */
    private static JLabel logoLabel(Container c) {
        for (Component child : c.getComponents()) {
            if (child instanceof JLabel) {
                JLabel l = (JLabel) child;
                Icon icon = l.getIcon();
                if (icon != null)
                    for (MouseListener m : l.getMouseListeners())
                        if (m.getClass().getName().startsWith("IPMIView20."))
                            return l;
            } else if (child instanceof Container) {
                JLabel l = logoLabel((Container) child);
                if (l != null)
                    return l;
            }
        }
        return null;
    }
}
