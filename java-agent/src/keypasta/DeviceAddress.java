package keypasta;

import java.net.InetAddress;
import java.net.UnknownHostException;

/**
 * IPMIView's device editor (Add and Edit, IPMIView20$NN.actionPerformed) takes an IP address or a
 * hostname, but a hostname is looked up with its bundled dnsjava (Address.getByName) and only the
 * IP is stored (getHostAddress). That old dnsjava doesn't read the hosts file either, so names known
 * only from there were refused. Patch.redirectDeviceAddress makes both calls these:
 * - getByName: the system's resolver (hosts file, DNS, search domains). A name it can't resolve is
 *   refused by IPMIView with "Invalid IP or hostname format" (JOptionPane.showMessageDialog, also
 *   redirected): that message becomes one saying the name couldn't be resolved, and OK again with
 *   the same name saves it anyway.
 * - getHostAddress: the name as typed, so IPMIView.properties keeps the hostname. Login, KVM launch
 *   and stunnel all work with a hostname there. (A plain redirect: the hook takes InetAddress.)
 */
public final class DeviceAddress {
    private static final String DONE = "iKVM-KeyPasta.cancel";
    private static final String INVALID = "Invalid IP or hostname format";
    private static final java.util.regex.Pattern HOSTNAME = java.util.regex.Pattern.compile("[A-Za-z0-9._-]+");
    // event dispatch thread only
    private static String unresolved;      // the name getByName just failed on
    private static String confirmed;       // the name OK again saves unresolved (till the editor closes)

    private DeviceAddress() {}

    public static void showMessageDialog(java.awt.Component parent, Object message) {
        javax.swing.JOptionPane.showMessageDialog(parent, message(parent, message));
    }

    private static Object message(java.awt.Component parent, Object message) {
        String name = unresolved;
        unresolved = null;
        if (name == null || !isInvalidMessage(parent, message))
            return message;
        return name.equals(confirmed)
            ? "\"" + name + "\" could not be resolved to an IP address.\nClick OK again to save this address anyway."
            : "\"" + name + "\" is not a valid hostname or IP address.";
    }

    /** IPMIView's "Invalid IP or hostname format", in its language (IPMIView20.L.t). */
    private static boolean isInvalidMessage(java.awt.Component parent, Object message) {
        if (INVALID.equals(message))
            return true;
        try {
            ClassLoader loader = parent != null ? parent.getClass().getClassLoader() : Thread.currentThread().getContextClassLoader();
            Class<?> l = Class.forName("IPMIView20.L", true, loader);
            return message != null && message.equals(l.getMethod("t", String.class).invoke(null, INVALID));
        } catch (Throwable e) {
            return false;
        }
    }

    /**
     * The device editor (IPMIView20.DeviceEditor, a JDialog with NetBeans' AbsoluteLayout) has only
     * OK, centered: OK moves left, a Cancel button (Swing's own text, IPMIView's language when Java
     * has it) goes right of it and closes the editor as IPMIView's OK does (setVisible(false)); Esc too.
     * The (i) icon right of the address field goes (user): its tooltip says the hostname becomes an IP.
     * The field's label says "Host address:".
     */
    static void editorOpened(java.awt.Window w) throws Exception {
        if (!(w instanceof javax.swing.JDialog) || !"IPMIView20.DeviceEditor".equals(w.getClass().getName()))
            return;
        final javax.swing.JDialog dialog = (javax.swing.JDialog) w;
        if (dialog.getRootPane().getClientProperty(DONE) != null)
            return;
        dialog.getRootPane().putClientProperty(DONE, Boolean.TRUE);
        dialog.addComponentListener(new java.awt.event.ComponentAdapter() {
            @Override
            public void componentHidden(java.awt.event.ComponentEvent e) {
                confirmed = null;       // a new editor asks again
            }
        });
        try {       // "IP address:" -> "Host address:" (user): a hostname stays one now; English only
            java.lang.reflect.Field lf = w.getClass().getDeclaredField("jLabel4");
            lf.setAccessible(true);
            Object label = lf.get(w);
            if (label instanceof javax.swing.JLabel && "IP address:".equals(((javax.swing.JLabel) label).getText()))
                ((javax.swing.JLabel) label).setText("Host address:");
        } catch (Exception e) {
            Log.d("device editor: address label not changed: " + e);
        }
        java.lang.reflect.Field okField = w.getClass().getDeclaredField("jButtonOK");
        okField.setAccessible(true);
        javax.swing.JButton ok = (javax.swing.JButton) okField.get(w);
        java.awt.Container panel = ok.getParent();
        for (java.awt.Component c : panel.getComponents())      // the (i) right of the address field: its tooltip is wrong now
            if (c instanceof javax.swing.JLabel && ((javax.swing.JLabel) c).getIcon() != null
                    && String.valueOf(((javax.swing.JLabel) c).getToolTipText()).startsWith("Could provide IP or hostname"))
                panel.remove(c);
        java.awt.LayoutManager layout = panel.getLayout();
        java.lang.reflect.Field cf = layout.getClass().getDeclaredField("constraints");
        cf.setAccessible(true);
        Object k = ((java.util.Map<?, ?>) cf.get(layout)).get(ok);
        int x = k.getClass().getField("x").getInt(k), y = k.getClass().getField("y").getInt(k);
        int width = k.getClass().getField("width").getInt(k), height = k.getClass().getField("height").getInt(k);
        if (width <= 0)
            width = ok.getPreferredSize().width;
        int gap = 10, left = x + width / 2 - width - gap / 2;    // the pair centered where OK was
        if (left < 0)
            return;
        k.getClass().getField("x").setInt(k, left);
        javax.swing.JButton cancel = new javax.swing.JButton(javax.swing.UIManager.getString("OptionPane.cancelButtonText", dialog.getLocale()));
        cancel.addActionListener(new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                dialog.setVisible(false);
            }
        });
        Object place = k.getClass().getConstructor(int.class, int.class, int.class, int.class)
            .newInstance(left + width + gap, y, width, height);
        panel.add(cancel, place);
        dialog.getRootPane().registerKeyboardAction(new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                dialog.setVisible(false);
            }
        }, javax.swing.KeyStroke.getKeyStroke(java.awt.event.KeyEvent.VK_ESCAPE, 0), javax.swing.JComponent.WHEN_IN_FOCUSED_WINDOW);
        panel.revalidate();
        panel.repaint();
        Log.d("device editor: Cancel button added");
    }

    /**
     * The system's lookup. A name it can't resolve is refused once (IPMIView's message, replaced in
     * showMessageDialog); OK again with the same name saves it as typed (user): the address returned
     * carries the name (0.0.0.0 inside, never used: getHostAddress gives the name). Only names of
     * hostname characters: anything else could break IPMIView.properties' lines. Empty: refused (the
     * system's lookup would give localhost).
     */
    public static InetAddress getByName(String name) throws UnknownHostException {
        String n = name.trim();
        unresolved = null;
        if (n.isEmpty())
            throw new UnknownHostException(n);
        try {
            InetAddress a = InetAddress.getByName(n);
            confirmed = null;
            return a;
        } catch (UnknownHostException e) {
            boolean savable = HOSTNAME.matcher(n).matches();
            if (savable && n.equals(confirmed)) {
                confirmed = null;
                Log.d("device address: unresolvable hostname saved on the second OK");
                return InetAddress.getByAddress(n, new byte[4]);
            }
            confirmed = savable ? n : null;
            unresolved = n;
            throw e;
        }
    }

    public static String getHostAddress(InetAddress address) {
        String text = address.toString();      // "name/ip": the name given, no reverse lookup
        int slash = text.lastIndexOf('/');
        String name = slash > 0 ? text.substring(0, slash) : "";
        if (name.isEmpty())
            return address.getHostAddress();
        Log.d("device address: hostname kept instead of its IP");
        return name;
    }
}
