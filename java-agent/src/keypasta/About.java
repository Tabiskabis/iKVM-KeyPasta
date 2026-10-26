package keypasta;

import java.awt.Desktop;
import java.awt.Window;
import java.net.URI;

import javax.swing.BorderFactory;
import javax.swing.JEditorPane;
import javax.swing.JScrollPane;
import javax.swing.JTabbedPane;
import javax.swing.UIManager;
import javax.swing.event.HyperlinkEvent;

/**
 * IPMIView's About dialog (IPMIView20$AboutDialog: a JTabbedPane with About, System Properties,
 * Environment Variables, Run Time) gets a "KeyPasta agent" tab: the project page and what the
 * agent changes in IPMIView on this OS. Added when the dialog opens (IPMIViewLogin's listener).
 * Keep the list in step with DOCUMENTATION.md, section 7.
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
        JEditorPane text = new JEditorPane("text/html", html());
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
        JScrollPane scroll = new JScrollPane(text);
        scroll.setBorder(BorderFactory.createEmptyBorder());
        tabs.addTab(TITLE, scroll);
        Log.d("About dialog: KeyPasta agent tab added");
    }

    private static String html() {
        boolean windows = !Config.MAC && !Config.LINUX;
        StringBuilder s = new StringBuilder("<html><head><style>ul { margin-left: 16px; margin-top: 2px } li { margin-bottom: 2px }</style></head><body>");
        String version = About.class.getPackage() == null ? null : About.class.getPackage().getImplementationVersion();
        s.append("<b>iKVM-KeyPasta agent</b>").append(version == null ? "" : " " + version).append("<br>");
        s.append("<a href=\"").append(URL).append("\">").append(URL).append("</a>");
        s.append("<p>Changes to IPMIView:</p><ul>");
        item(s, "Quits without asking \"Are you sure to quit?\"; closing a BMC session doesn't show the note about its KVM console.");
        item(s, Config.MAC ? "Main window 1144 pixels wide." : "Main window 20 pixels wider.");
        item(s, "Login view: an eye button shows the saved password.");
        item(s, "Firmware update: the login popup is filled with the BMC's saved ID and password.");
        item(s, "Removing a system also removes its saved ID and password (account.properties).");
        item(s, "The note after saving the configuration (and the Configuration tip) shows its folder with the dots in it.");
        item(s, "All settings files in IPMIView's settings folder (when it has one), none in its program folder.");
        item(s, "Sensors tab opens in the text view, with a \"Clear Chassis Intrusion\" button.");
        item(s, "No lookup of the computer's own address for every BMC connection and packet (faster first login).");
        item(s, "Faster console launch: no fixed 4 seconds waiting for the tunnel"
            + (windows ? "" : ", no 5 seconds pause in the viewer") + ".");
        item(s, "The viewer gets its settings (user name, password, ports) through its input instead of a file in the temp folder"
            + " (when the viewer runs with the agent too).");
        if (Config.MAC)
            item(s, "Font: SF Pro or Helvetica Neue instead of PMingLiU; labels cut by it widened.");
        if (Config.LINUX) {
            item(s, "Font: Noto Sans, DejaVu Sans or Liberation Sans instead of PMingLiU, antialiased; labels cut by it widened.");
            item(s, "Windows laid out by coordinates (Flash Tool) made big enough for their content.");
        }
        item(s, "iKVM viewer: keyboard fixes (any local layout), paste, preferences window wider and resizable"
            + (Config.LINUX ? ", resizable windows under Wayland and WSL" : "") + ".");
        s.append("</ul></body></html>");
        return s.toString();
    }

    private static void item(StringBuilder s, String text) {
        s.append("<li>").append(text.replace("&", "&amp;").replace("<", "&lt;")).append("</li>");
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
