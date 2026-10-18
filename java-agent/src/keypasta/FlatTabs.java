package keypasta;

import java.awt.Component;
import java.awt.Container;
import java.awt.Graphics;
import javax.swing.JTabbedPane;

/**
 * macOS, IPMIView: its tab panes without the Mac's rounded box around their content. IPMIView nests
 * tab panes in boxed panels of its own, and Aqua draws its group box around each tab pane's
 * content too: boxes in boxes, a box edge running past the device tab, a row of tabs below its box's
 * corner (the box is cut where the tabs sit only when they sit on its edge). Same Aqua tab pane,
 * same tabs, only paintContentBorder doing nothing. The Mac's classes (com.apple.laf, exported to
 * the agent by Agent.exportDesktop) are only there on macOS: compiled against stand-ins in
 * java-agent/stub/, not in the jar.
 */
final class FlatTabs {
    private static final String AQUA = "com.apple.laf.AquaTabbedPaneUI";
    private static final String CONTRAST = "com.apple.laf.AquaTabbedPaneContrastUI";
    private static Boolean ready;

    private FlatTabs() {
    }

    private static boolean ready() {
        if (ready == null)
            ready = Agent.exportDesktop("com.apple.laf");
        return ready;
    }

    /** Every Aqua tab pane in c. */
    static void flatten(Component c) {
        if (c instanceof JTabbedPane) {
            JTabbedPane t = (JTabbedPane) c;
            String ui = t.getUI() == null ? "" : t.getUI().getClass().getName();
            if ((ui.equals(AQUA) || ui.equals(CONTRAST)) && ready()) {
                try {
                    // by name: a direct "new" makes the verifier load the Mac's classes with FlatTabs
                    String sub = FlatTabs.class.getName() + (ui.equals(AQUA) ? "$Plain" : "$Contrast");
                    t.setUI((javax.swing.plaf.TabbedPaneUI) Class.forName(sub).newInstance());
                    Log.d("tab pane without its box");
                } catch (Throwable e) {
                    ready = false;
                    Log.d("tab pane unchanged: " + e);
                }
            }
        }
        if (c instanceof Container)
            for (Component child : ((Container) c).getComponents())
                flatten(child);
    }

    static final class Plain extends com.apple.laf.AquaTabbedPaneUI {
        @Override
        protected void paintContentBorder(Graphics g, int tabPlacement, int selectedIndex) {
        }
    }

    static final class Contrast extends com.apple.laf.AquaTabbedPaneContrastUI {
        @Override
        protected void paintContentBorder(Graphics g, int tabPlacement, int selectedIndex) {
        }
    }
}
