package keypasta;

import java.awt.AWTEvent;
import java.awt.Color;
import java.awt.Component;
import java.awt.Container;
import java.awt.EventQueue;
import java.awt.GridBagConstraints;
import java.awt.GridBagLayout;
import java.awt.LayoutManager;
import java.awt.Toolkit;
import java.awt.event.AWTEventListener;
import java.awt.event.ContainerEvent;
import java.awt.event.HierarchyEvent;
import java.awt.event.WindowEvent;
import java.io.File;
import java.util.Collections;
import java.util.Set;
import java.util.WeakHashMap;
import javax.swing.AbstractButton;
import javax.swing.BorderFactory;
import javax.swing.JLabel;
import javax.swing.JPanel;

/**
 * macOS, IPMIView without Homebrew's stunnel: IPMIView itself starts (ipmiview-keypasta.sh no
 * longer stops), but the KVM console of a BMC with encrypted KVM can't open without stunnel. So a
 * note goes below IPMIView's "Launch KVM Console" button, found by its text wherever IPMIView puts
 * it (a tab built when a BMC is opened): every container change and every component that becomes
 * visible is searched, each button gets the note once.
 */
final class StunnelNote {
    static final String[] STUNNELS = {"/opt/homebrew/bin/stunnel", "/usr/local/bin/stunnel"};
    private static final String BUTTON = "launch kvm console";
    private static final String TEXT = "<html><div style='width:260px;text-align:center'>stunnel isn't installed: the KVM console "
        + "of a BMC with encrypted KVM won't open. Install it with <b>brew install stunnel</b>, "
        + "then start IPMIView again.</div></html>";
    private static final Set<Component> noted =
        Collections.newSetFromMap(new WeakHashMap<Component, Boolean>());
    private static boolean started;

    private StunnelNote() {
    }

    static boolean stunnelInstalled() {
        for (String s : STUNNELS)
            if (new File(s).canExecute())
                return true;
        return false;
    }

    /** From the class loading of IPMIView's main class: AWT only from a thread of its own. */
    static synchronized void install() {
        if (started || !Icons.isMac())
            return;
        if (stunnelInstalled()) {
            Log.d("Homebrew stunnel found: no note below IPMIView's Launch KVM Console button");
            started = true;
            return;
        }
        started = true;
        Log.d("no Homebrew stunnel: note below IPMIView's Launch KVM Console button");
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                EventQueue.invokeLater(new Runnable() {
                    @Override
                    public void run() {
                        watch();
                    }
                });
            }
        }, "iKVM-KeyPasta stunnel note");
        t.setDaemon(true);
        t.start();
    }

    private static void watch() {
        for (java.awt.Frame f : java.awt.Frame.getFrames())    // already there
            search(f);
        Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
            @Override
            public void eventDispatched(AWTEvent e) {
                try {
                    if (e instanceof ContainerEvent && e.getID() == ContainerEvent.COMPONENT_ADDED)
                        search(((ContainerEvent) e).getChild());
                    else if (e instanceof HierarchyEvent
                            && (((HierarchyEvent) e).getChangeFlags() & HierarchyEvent.SHOWING_CHANGED) != 0
                            && ((HierarchyEvent) e).getComponent().isShowing())
                        search(((HierarchyEvent) e).getComponent());
                    else if (e.getID() == WindowEvent.WINDOW_OPENED)
                        search(((WindowEvent) e).getWindow());
                } catch (RuntimeException ex) {
                    Log.d("stunnel note failed: " + ex);
                }
            }
        }, AWTEvent.CONTAINER_EVENT_MASK | AWTEvent.HIERARCHY_EVENT_MASK | AWTEvent.WINDOW_EVENT_MASK);
    }

    private static final Set<Component> seen = Collections.newSetFromMap(new WeakHashMap<Component, Boolean>());

    private static void search(Component c) {
        // Swing's JButton or AWT's Button
        String text = c instanceof AbstractButton ? ((AbstractButton) c).getText()
            : c instanceof java.awt.Button ? ((java.awt.Button) c).getLabel() : null;
        if (text != null && javax.swing.SwingUtilities.getAncestorOfClass(Note.class, c) == null) {
            String t = text.replaceAll("<[^>]*>", "").trim().toLowerCase(java.util.Locale.ROOT);
            if (t.contains("kvm") && seen.add(c))     // which buttons there are, for the log
                Log.d("button " + c.getClass().getName() + " \"" + text + "\" in "
                    + (c.getParent() == null ? "-" : c.getParent().getClass().getName() + " ("
                    + (c.getParent().getLayout() == null ? "no layout" : c.getParent().getLayout().getClass().getName()) + ")"));
            if (t.equals(BUTTON) && noted.add(c))
                addNote(c);
        }
        if (c instanceof Container)
            for (Component child : ((Container) c).getComponents())
                search(child);
    }

    /** The button and the note in a panel of their own, in the button's place. */
    private static final class Note extends JPanel {
        Note(Component button) {
            super(new java.awt.BorderLayout(0, 4));
            setOpaque(false);
            JPanel keep = new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.CENTER, 0, 0));   // the button's own width
            keep.setOpaque(false);
            keep.add(button);
            add(keep, java.awt.BorderLayout.NORTH);
            add(label(), java.awt.BorderLayout.CENTER);
            // in a BoxLayout (IPMIView's), as big as needed, placed like the button
            setAlignmentX(button.getAlignmentX());
            setAlignmentY(button.getAlignmentY());
        }

        @Override
        public java.awt.Dimension getMaximumSize() {
            return getPreferredSize();
        }
    }

    private static JLabel label() {
        JLabel note = new JLabel(TEXT, javax.swing.SwingConstants.CENTER);
        note.setForeground(new Color(0xB0, 0x30, 0x20));
        note.setBorder(BorderFactory.createEmptyBorder(6, 0, 0, 0));
        return note;
    }

    private static void addNote(Component button) {
        Container parent = button.getParent();
        if (parent == null)
            return;
        LayoutManager layout = parent.getLayout();
        int index = -1;
        for (int i = 0; i < parent.getComponentCount(); i++)
            if (parent.getComponent(i) == button)
                index = i;
        if (layout == null) {
            // absolute positions: the note below the button, the button stays where it is
            JLabel note = label();
            java.awt.Dimension d = note.getPreferredSize();
            note.setBounds(button.getX(), button.getY() + button.getHeight() + 4, d.width, d.height);
            parent.add(note);
            Log.d("stunnel note added (absolute)");
        } else {
            Object constraints = null;
            if (layout instanceof GridBagLayout)
                constraints = (GridBagConstraints) ((GridBagLayout) layout).getConstraints(button).clone();
            else if (layout instanceof java.awt.BorderLayout)
                constraints = ((java.awt.BorderLayout) layout).getConstraints(button);
            parent.remove(index);
            try {
                parent.add(new Note(button), constraints, index);
                Log.d("stunnel note added (" + layout.getClass().getSimpleName() + ")");
            } catch (RuntimeException e) {
                // a layout that doesn't take it: the button back as it was
                if (button.getParent() != null)
                    button.getParent().remove(button);
                parent.add(button, constraints, index);
                Log.d("stunnel note not added (" + layout.getClass().getSimpleName() + "): " + e);
            }
        }
        parent.revalidate();
        parent.repaint();
    }
}
