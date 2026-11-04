package keypasta;

import java.awt.Component;
import java.awt.Desktop;
import java.awt.Dimension;
import java.awt.Window;
import java.net.URI;

import javax.swing.BorderFactory;
import javax.swing.JEditorPane;
import javax.swing.JOptionPane;
import javax.swing.JScrollPane;
import javax.swing.JTabbedPane;
import javax.swing.UIManager;
import javax.swing.event.HyperlinkEvent;

/**
 * IPMIView's About dialog (IPMIView20$AboutDialog: a JTabbedPane with About, System Properties,
 * Environment Variables, Run Time) gets a "KeyPasta agent" tab: the project page and what the
 * agent changes in IPMIView on this OS. Added when the dialog opens (IPMIViewLogin's listener).
 * The viewer's own About (the ? button in KeyPasta Preferences) lists the viewer's changes.
 * Keep the lists in step with DOCUMENTATION.md, sections 6 and 7.
 */
final class About {
    static final String URL = "https://github.com/Tabiskabis/iKVM-KeyPasta";
    private static final String TITLE = "KeyPasta agent";

    private About() {
    }

    static void opened(Window w) {
        if (!"IPMIView20.IPMIView20$AboutDialog".equals(w.getClass().getName()))
            return;
        JTabbedPane tabs = null;
        try {
            java.lang.reflect.Field f = w.getClass().getDeclaredField("jtabedPane");
            f.setAccessible(true);
            tabs = (JTabbedPane) f.get(w);
        } catch (Exception e) {
            Log.d("About dialog: no tabs (" + e + ")");
            return;
        }
        if (tabs == null || tabs.indexOfTab(TITLE) >= 0)
            return;
        JScrollPane scroll = new JScrollPane(pane(ipmiviewHtml()));
        scroll.setBorder(BorderFactory.createEmptyBorder());
        tabs.addTab(TITLE, scroll);
        Log.d("About dialog: KeyPasta agent tab added");
        if (Config.MAC)
            fitTabs(w, tabs);
    }

    /**
     * macOS: Aqua's tab pane has one row and scrolls it (an arrow at the right), where the other
     * looks and feels wrap into two: IPMIView's fixed dialog width showed three of its five tabs.
     * The dialog gets wide enough for all of them, kept centred where it was.
     */
    private static void fitTabs(Window w, JTabbedPane tabs) {
        java.awt.FontMetrics fm = tabs.getFontMetrics(tabs.getFont());
        int need = 48;                          // the pane's and the dialog's edges
        for (int i = 0; i < tabs.getTabCount(); i++)
            need += fm.stringWidth(tabs.getTitleAt(i)) + 32;   // Aqua's padding per tab, generously
        int screen = w.getGraphicsConfiguration().getBounds().width;
        need = Math.min(need, screen * 9 / 10);
        int extra = need - w.getWidth();
        if (extra <= 0)
            return;
        w.setBounds(w.getX() - extra / 2, w.getY(), need, w.getHeight());
        w.validate();
        Log.d("About dialog: " + (need - extra) + " -> " + need + " wide for its tabs");
    }

    /** The viewer's About KeyPasta, from the ? button in KeyPasta Preferences. */
    static void showViewer(Component parent, String pasteHotkey) {
        JEditorPane text = pane(viewerHtml(pasteHotkey));
        // a fixed width, so the HTML wraps (its height then follows), but room for the folder's
        // path, which can't wrap
        String folder = Config.file().getAbsoluteFile().getParent();
        int width = Math.max(480, text.getFontMetrics(text.getFont()).stringWidth(folder) + 40);
        text.setSize(new Dimension(width, Short.MAX_VALUE));
        text.setPreferredSize(new Dimension(width, text.getPreferredSize().height));
        JOptionPane.showMessageDialog(parent, text, "About KeyPasta", JOptionPane.PLAIN_MESSAGE);
    }

    private static JEditorPane pane(String html) {
        JEditorPane text = new JEditorPane("text/html", html);
        text.setEditable(false);
        text.putClientProperty(JEditorPane.HONOR_DISPLAY_PROPERTIES, Boolean.TRUE);
        text.setFont(UIManager.getFont("Label.font"));
        text.setBackground(UIManager.getColor("Panel.background"));
        text.setBorder(BorderFactory.createEmptyBorder(8, 10, 8, 10));
        text.addHyperlinkListener(e -> {
            if (e.getEventType() == HyperlinkEvent.EventType.ACTIVATED)
                browse(e.getDescription());
        });
        text.setCaretPosition(0);
        return text;
    }

    /** Version, project link, preferences folder, then the list of changes to {@code program}. */
    private static StringBuilder head(String program) {
        // space between the items: margin-top (Swing's HTML ignores a list item's margin-bottom)
        StringBuilder s = new StringBuilder("<html><head><style>ul { margin-left: 16px; margin-top: 0 } li { margin-top: 6px }</style></head><body>");
        String version = About.class.getPackage() == null ? null : About.class.getPackage().getImplementationVersion();
        s.append("<b>iKVM-KeyPasta agent</b>").append(version == null ? "" : " " + version).append("<br>");
        s.append("<a href=\"").append(URL).append("\">").append(URL).append("</a>");
        s.append("<p>KeyPasta Preferences folder:<br>").append(escape(Config.file().getAbsoluteFile().getParent())).append("</p>");
        s.append("<p>Changes to ").append(program).append(":</p><ul>");
        return s;
    }

    private static String ipmiviewHtml() {
        boolean windows = !Config.MAC && !Config.LINUX;
        StringBuilder s = head("IPMIView");
        item(s, "All settings files in IPMIView's settings folder (when it has one), none in its program folder.");
        item(s, "Login view: an eye button shows the saved password.");
        item(s, "Saved ID and password: kept when a system is renamed, filled into the firmware update's login popup,"
            + " removed with the system (account.properties).");
        item(s, "Faster console launch: no fixed 4 seconds waiting for the tunnel"
            + (windows ? "" : ", no 5 seconds pause in the viewer") + ".");
        item(s, "The console also launches when IPMIView can't create its stunnel.properties (a folder it can't write).");
        item(s, "Sensors tab opens in the text view, with a \"Clear Chassis Intrusion\" button.");
        item(s, "No lookup of the computer's own address for every BMC connection and packet (faster first login).");
        item(s, "The viewer gets its settings (user name, password, ports) through its input instead of a file in the temp folder"
            + " (when the viewer runs with the agent too).");
        item(s, "Quits without asking \"Are you sure to quit?\"; closing a BMC session doesn't show the note about its KVM console.");
        item(s, Config.MAC ? "Main window 1144 pixels wide." : "Main window 20 pixels wider.");
        if (Config.MAC)
            item(s, "Font: SF Pro or Helvetica Neue instead of PMingLiU; labels cut by it widened.");
        if (Config.LINUX) {
            item(s, "Font: Noto Sans, DejaVu Sans or Liberation Sans instead of PMingLiU, antialiased; labels cut by it widened.");
            item(s, "Windows laid out by coordinates (Flash Tool) made big enough for their content.");
        }
        item(s, "The note after saving the configuration (and the Configuration tip) shows its folder with the dots in it.");
        s.append("</ul></body></html>");
        return s.toString();
    }

    private static String viewerHtml(String pasteHotkey) {
        StringBuilder s = head("the iKVM viewer");
        item(s, "Every key arrives at its position, with any local keyboard layout: the remote's layout decides what it types."
            + " The viewer's own Keyboard layout setting no longer matters.");
        item(s, "Paste: the clipboard typed on the remote (" + pasteHotkey + ").");
        item(s, "Settings per BMC: KeyPasta Preferences in the Options menu.");
        item(s, "Smooth picture while the mouse moves: mouse moves sent at most 60 times a second.");
        item(s, "Caps Lock, Num Lock and Scroll Lock: the remote's lock follows the local one, or the keys go as they are pressed (Toggle keys).");
        item(s, "Keys held when the window loses the focus are released on the remote.");
        item(s, "Keys go to the remote also when a toolbar button has the focus.");
        item(s, "The window follows a new remote resolution right away and no longer forces itself on top.");
        if (Config.MAC) {
            item(s, "No quitting without the Input Monitoring permission (the viewer's keyboard light code).");
            item(s, "Cmd+Q goes to the remote; the menus in the menu bar are there and enabled after dialogs.");
            item(s, "One stunnel program instead of a new one on every start (firewalls).");
        }
        if (Config.LINUX)
            item(s, "Windows stay resizable under Wayland and WSL (no empty margins, no offset menus).");
        if (!Config.MAC && !Config.LINUX)
            item(s, "A window left blocked by a dialog that's gone (no clicks, menus or keys) is unblocked.");
        item(s, "Preferences window wider and resizable; KeyPasta's icon on the viewer's windows.");
        s.append("</ul></body></html>");
        return s.toString();
    }

    private static void item(StringBuilder s, String text) {
        s.append("<li>").append(escape(text)).append("</li>");
    }

    private static String escape(String text) {
        return text.replace("&", "&amp;").replace("<", "&lt;");
    }

    private static void browse(String url) {
        try {
            if (Desktop.isDesktopSupported() && Desktop.getDesktop().isSupported(Desktop.Action.BROWSE)) {
                Desktop.getDesktop().browse(new URI(url));
                return;
            }
        } catch (Exception e) {
            Log.d("About dialog: browser not opened by Java (" + e + ")");
        }
        try {
            new ProcessBuilder(Config.MAC ? "open" : "xdg-open", url).start();
        } catch (Exception e) {
            Log.d("About dialog: no browser (" + e + ")");
        }
    }
}
