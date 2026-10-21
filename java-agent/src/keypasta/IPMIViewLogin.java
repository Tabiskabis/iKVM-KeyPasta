package keypasta;

import java.awt.AWTEvent;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Component;
import java.awt.Container;
import java.awt.Cursor;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.AWTEventListener;
import java.awt.event.HierarchyEvent;
import java.awt.event.WindowEvent;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import javax.swing.BorderFactory;
import javax.swing.Icon;
import javax.swing.JDialog;
import javax.swing.JPasswordField;
import javax.swing.JTextField;
import javax.swing.JToggleButton;

/**
 * IPMIView's passwords, two conveniences:
 * - The login view of a BMC (IPMIView20.IPMISession, its field Password; IPMIView fills it from
 *   account.properties when "save ID and Password" is on) gets a small eye button at the right end
 *   of the password field that shows the password (and hides it again). Only there (user).
 * - The firmware update's popup "Please input ID and Password" (FlashFirmware, FlashFirmwareATEN,
 *   FlashFirmwareAMI(X9), the Redfish BMC/BIOS update views) is filled with the BMC's saved ID and
 *   password, if the fields are empty: the BMC's IP from the update window (field ip or loginIP),
 *   its device name from IPMIView's device list (DeviceFile.getHostnameByIP), the account saved
 *   for that name (else for the IP) by IPMIView20.DeviceNameAccount, which also decrypts it
 *   (account.properties is left as IPMIView writes it). Nothing is logged but that it happened.
 * - A device removed from IPMIView's list (IPMIView20.jMiListDeleteActionPerformed:
 *   DeviceFile.deleteDevice, Patch.redirectIPMIViewMain) also loses its saved ID and password in
 *   account.properties (DeviceNameAccount.remove: by its name, and by its IP if no other device in
 *   the list has that IP).
 * - The Sensors tab of a BMC opens in its text view (IPMISession: ComboTab.resetDefaultTab of the
 *   tab holding SensorsReadingView, Patch.redirectSensorsTab), switched to quietly: nothing is read
 *   before the tab is opened (the viewer's switch would read the sensors right at login), and the
 *   graphic view's refresh is stopped as its own switch would.
 * - Diagnosis of the slow first login (the user: longer the more IP addresses the computer
 *   has): when a session view opens or its Login button is pressed, for 20 s, 5 times a second,
 *   what IPMIView's threads are doing (top frames of each thread in IPMIView's or Supermicro's
 *   code, logged when it changes; no values, only class.method:line).
 * All by reflection on IPMIView's classes (their class loader: the windows' own).
 */
public final class IPMIViewLogin {
    private static final String DONE = "iKVM-KeyPasta.reveal";
    private static boolean installed;

    private IPMIViewLogin() {
    }

    /** On the event dispatch thread, from IPMIView's start (Widen). */
    static synchronized void install() {
        if (installed)
            return;
        installed = true;
        Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
            @Override
            public void eventDispatched(AWTEvent e) {
                try {
                    if (e instanceof HierarchyEvent) {
                        HierarchyEvent h = (HierarchyEvent) e;
                        // (sent to every component of the part that became visible: the session's own)
                        if ((h.getChangeFlags() & HierarchyEvent.SHOWING_CHANGED) != 0 && h.getComponent().isShowing()
                                && "IPMIView20.IPMISession".equals(h.getComponent().getClass().getName())) {
                            loginView(h.getComponent());
                            sample("session view opened");
                        }
                    } else if (e.getID() == java.awt.event.MouseEvent.MOUSE_PRESSED && e.getSource() instanceof javax.swing.JButton) {
                        for (Component p = (Component) e.getSource(); p != null; p = p.getParent())
                            if ("IPMIView20.IPMISession".equals(p.getClass().getName())) {
                                sample("button in the session view pressed");
                                break;
                            }
                    } else if (e.getID() == WindowEvent.WINDOW_OPENED && ((WindowEvent) e).getWindow() instanceof JDialog) {
                        About.opened(((WindowEvent) e).getWindow());
                        flashLogin((JDialog) ((WindowEvent) e).getWindow());
                    }
                } catch (Throwable t) {
                    Log.d("IPMIView login convenience failed: " + t);
                }
            }
        }, AWTEvent.HIERARCHY_EVENT_MASK | AWTEvent.WINDOW_EVENT_MASK | AWTEvent.MOUSE_EVENT_MASK);
    }

    private static void loginView(Component session) throws Exception {
        Object field = session.getClass().getField("Password").get(session);
        if (field instanceof JPasswordField)
            reveal((JPasswordField) field);
    }

    private static volatile long sampling;
    /** The agent's loginTrace=true: the 20 s of IPMIView's threads in the log (off: too much). */
    static volatile boolean trace;

    /** 20 s of what IPMIView's threads do (see the class comment); one at a time. */
    static void sample(final String why) {
        if (!trace)
            return;
        final long start = System.currentTimeMillis();
        synchronized (IPMIViewLogin.class) {
            if (start - sampling < 20000L)
                return;
            sampling = start;
        }
        Log.d("login diagnosis: " + why + ", watching IPMIView's threads for 20 s");
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                java.util.Map<Thread, String> last = new java.util.HashMap<Thread, String>();
                while (System.currentTimeMillis() - start < 20000L) {
                    java.util.Set<Thread> seen = new java.util.HashSet<Thread>();
                    for (java.util.Map.Entry<Thread, StackTraceElement[]> e : Thread.getAllStackTraces().entrySet()) {
                        String where = where(e.getValue());
                        if (where == null)
                            continue;
                        seen.add(e.getKey());
                        if (!where.equals(last.put(e.getKey(), where)))
                            Log.d("login diagnosis +" + (System.currentTimeMillis() - start) + " ms, " + e.getKey().getName() + ": " + where);
                    }
                    for (java.util.Iterator<Thread> i = last.keySet().iterator(); i.hasNext(); ) {
                        Thread th = i.next();
                        if (!seen.contains(th)) {
                            i.remove();
                            Log.d("login diagnosis +" + (System.currentTimeMillis() - start) + " ms, " + th.getName() + ": idle/done");
                        }
                    }
                    try {
                        Thread.sleep(200L);
                    } catch (InterruptedException e) {
                        return;
                    }
                }
                Log.d("login diagnosis: done");
            }
        }, "iKVM-KeyPasta login diagnosis");
        t.setDaemon(true);
        t.start();
    }

    /** The top frames of a thread busy in IPMIView's code (null: not, or waiting idly). */
    private static String where(StackTraceElement[] stack) {
        int own = -1;
        for (int i = 0; i < stack.length; i++)
            if (stack[i].getClassName().startsWith("IPMIView20.") || stack[i].getClassName().startsWith("com.supermicro.")) {
                own = i;
                break;
            }
        if (own < 0)
            return null;
        String top = stack[0].getClassName() + "." + stack[0].getMethodName();
        if (top.equals("java.lang.Object.wait") || top.equals("java.lang.Thread.sleep") && own > 1)
            return null;                                   // a timer or queue waiting for work
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < stack.length && i <= own + 2; i++) {
            if (i > 0)
                b.append(" < ");
            b.append(stack[i].getClassName().replaceFirst("^.*\\.", "")).append('.').append(stack[i].getMethodName())
                .append(':').append(stack[i].getLineNumber());
        }
        return b.toString();
    }

    /** The eye button, inside the field at its right end (whatever layout its panel has). */
    static void reveal(final JPasswordField field) {
        if (field.getClientProperty(DONE) != null)
            return;
        field.putClientProperty(DONE, Boolean.TRUE);
        final char echo = field.getEchoChar();
        final JToggleButton eye = new JToggleButton(new Eye(false));
        eye.setSelectedIcon(new Eye(true));
        eye.setBorder(BorderFactory.createEmptyBorder(0, 2, 0, 3));
        eye.setContentAreaFilled(false);
        eye.setFocusable(false);
        eye.setOpaque(false);
        eye.setCursor(Cursor.getPredefinedCursor(Cursor.HAND_CURSOR));
        eye.setToolTipText("Show password");
        eye.addActionListener(new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                field.setEchoChar(eye.isSelected() ? (char) 0 : echo);
                eye.setToolTipText(eye.isSelected() ? "Hide password" : "Show password");
            }
        });
        // at the field's right end, inside its own border; the text stops before the button
        final javax.swing.border.Border own = field.getBorder();
        field.setLayout(new java.awt.LayoutManager() {
            @Override
            public void addLayoutComponent(String name, Component c) {
            }

            @Override
            public void removeLayoutComponent(Component c) {
            }

            @Override
            public java.awt.Dimension preferredLayoutSize(Container parent) {
                return parent.getSize();
            }

            @Override
            public java.awt.Dimension minimumLayoutSize(Container parent) {
                return new java.awt.Dimension(0, 0);
            }

            @Override
            public void layoutContainer(Container parent) {
                java.awt.Insets in = own == null ? new java.awt.Insets(0, 0, 0, 0) : own.getBorderInsets(field);
                int w = eye.getPreferredSize().width;
                eye.setBounds(field.getWidth() - in.right - w, in.top, w, Math.max(0, field.getHeight() - in.top - in.bottom));
            }
        });
        field.add(eye);
        field.setBorder(BorderFactory.createCompoundBorder(own,
            BorderFactory.createEmptyBorder(0, 0, 0, eye.getPreferredSize().width)));
        field.revalidate();
        field.repaint();
    }

    private static void flashLogin(JDialog dialog) throws Exception {
        Window flash = flashWindow(dialog);
        if (flash == null)
            return;
        ClassLoader loader = flash.getClass().getClassLoader();
        Class<?> l = Class.forName("IPMIView20.L", true, loader);
        Object title = l.getMethod("t", String.class).invoke(null, "flash.Please_input_ID_and_Password");
        if (!String.valueOf(title).equals(dialog.getTitle()))
            return;
        JTextField id = null;
        JPasswordField password = null;
        for (Component c : all(dialog.getContentPane())) {
            if (c instanceof JPasswordField && password == null)
                password = (JPasswordField) c;
            else if (c instanceof JTextField && !(c instanceof JPasswordField) && id == null)
                id = (JTextField) c;
        }
        if (password == null)
            return;
        String ip = ip(flash);
        if (ip == null || id == null || !id.getText().isEmpty() || password.getPassword().length > 0)
            return;
        Class<?> account = Class.forName("IPMIView20.DeviceNameAccount", true, loader);
        Method getID = account.getMethod("getID", String.class);
        Method getPassword = account.getMethod("getDecryptedPassword", String.class);
        String name = null;
        try {
            name = (String) Class.forName("IPMIView20.DeviceFile", true, loader).getMethod("getHostnameByIP", String.class).invoke(null, ip);
        } catch (Exception e) {
            // no device name: by IP
        }
        for (String key : new String[] {name, ip}) {
            if (key == null || key.isEmpty() || getID.invoke(null, key) == null)
                continue;
            id.setText((String) getID.invoke(null, key));
            password.setText((String) getPassword.invoke(null, key));
            Log.d("firmware update login filled with the saved ID and password");
            return;
        }
    }

    /** The firmware update window the popup belongs to: its owner, else a showing one. */
    private static Window flashWindow(JDialog dialog) {
        for (Window w = dialog.getOwner(); w != null; w = w.getOwner())
            if (w.getClass().getName().startsWith("IPMIView20.Flash"))
                return w;
        for (Window w : Window.getWindows())
            if (w.isShowing() && w.getClass().getName().startsWith("IPMIView20.Flash"))
                return w;
        return null;
    }

    /** IPMIView20's DeviceFile.deleteDevice: the device removed, then its saved account. */
    public static void deleteDevice(Object deviceFile, String name, String ip, String description) throws Exception {
        Method delete = deviceFile.getClass().getMethod("deleteDevice", String.class, String.class, String.class);
        try {
            delete.invoke(deviceFile, name, ip, description);
        } catch (java.lang.reflect.InvocationTargetException e) {
            throw e.getCause() instanceof Exception ? (Exception) e.getCause() : e;
        }
        try {
            ClassLoader loader = deviceFile.getClass().getClassLoader();
            Class<?> account = Class.forName("IPMIView20.DeviceNameAccount", true, loader);
            Method getID = account.getMethod("getID", String.class);
            Method remove = account.getMethod("remove", String.class);
            boolean removed = false;
            if (name != null && getID.invoke(null, name) != null) {
                remove.invoke(null, name);
                removed = true;
            }
            if (ip != null && getID.invoke(null, ip) != null && !ipInList(deviceFile, ip)) {
                remove.invoke(null, ip);
                removed = true;
            }
            if (removed)
                Log.d("removed device: its saved ID and password removed from account.properties");
        } catch (Exception e) {
            Log.d("removed device: account not removed: " + e);
        }
    }

    /** Another device of the (already changed) list has this IP. */
    private static boolean ipInList(Object deviceFile, String ip) throws Exception {
        java.util.Vector<?> names = (java.util.Vector<?>) deviceFile.getClass().getMethod("getDeviceVector", String.class).invoke(deviceFile, (String) null);
        Method toIP = deviceFile.getClass().getMethod("hostnameToIP", String.class);
        for (Object n : names)
            if (ip.equals(toIP.invoke(deviceFile, String.valueOf(n))))
                return true;
        return false;
    }

    /** IPMISession's ComboTab.resetDefaultTab: the sensors' combo tab to its text view, quietly. */
    @SuppressWarnings("unchecked")
    public static void resetDefaultTab(Object comboTab) throws Exception {
        comboTab.getClass().getMethod("resetDefaultTab").invoke(comboTab);
        try {
            java.util.List<Object> tabs = (java.util.List<Object>) field(comboTab, "subTabList");
            int text = -1;
            for (int i = 0; i < tabs.size(); i++)
                if (tabs.get(i).getClass().getName().equals("IPMIView20.SensorsReadingView"))
                    text = i;
            if (text < 0)
                return;
            javax.swing.JComboBox<?> combo = (javax.swing.JComboBox<?>) field(comboTab, "tabsCombobox");
            java.util.List<Object> toolbars = (java.util.List<Object>) field(comboTab, "toolbarList");
            Container toolbarPanel = (Container) field(comboTab, "toolbarPanel");
            javax.swing.JScrollPane scroll = (javax.swing.JScrollPane) field(comboTab, "scrollPane");
            Field current = comboTab.getClass().getDeclaredField("currentSubTabIndex");
            current.setAccessible(true);
            int old = current.getInt(comboTab);
            java.awt.event.ActionListener[] listeners = combo.getActionListeners();
            for (java.awt.event.ActionListener l : listeners)
                combo.removeActionListener(l);
            try {
                combo.setSelectedIndex(text);
            } finally {
                for (java.awt.event.ActionListener l : listeners)
                    combo.addActionListener(l);
            }
            if (toolbars.get(old) != null)
                toolbarPanel.remove((Component) toolbars.get(old));
            if (toolbars.get(text) != null)
                toolbarPanel.add((Component) toolbars.get(text), "West");
            toolbarPanel.revalidate();
            toolbarPanel.repaint();
            scroll.setViewportView((Component) tabs.get(text));
            Object graphic = tabs.get(old);
            if (old != text) {
                for (Class<?> i : graphic.getClass().getInterfaces())
                    if (i.getName().equals("IPMIView20.ComboTabListener"))
                        i.getMethod("toolbarAction", int.class).invoke(graphic, 6);    // TAB_LEAVE
            }
            current.setInt(comboTab, text);
            clearIntrusionButton((Container) toolbars.get(text), tabs.get(text));
            Log.d("sensors tab: text view");
        } catch (Exception e) {
            Log.d("sensors tab: text view not set: " + e);
        }
    }

    /**
     * The text view's toolbar: "Clear Chassis Intrusion" after its Refresh (the graphic view has it
     * as a "Clear" label under the sensor, the text view nothing). Asks first (IPMIView's own
     * question), sends Supermicro's OEM command (IPMIOEMCommand.clearChassisIntrusion: netfn 0x30,
     * cmd 0x03) over a session of its own, the way the text view reads the sensors
     * (SensorsReadingControl's IPMIInterfaceConfig, SessionControllerFactory), then reads them again.
     */
    private static void clearIntrusionButton(Container toolbar, final Object textView) {
        if (toolbar == null)
            return;
        final ClassLoader loader = textView.getClass().getClassLoader();
        String label = "Clear Chassis Intrusion";
        try {
            label = (String) Class.forName("IPMIView20.L", true, loader).getMethod("t", String.class).invoke(null, "group.table.toolbar.ClrInt");
        } catch (Exception e) {
            // English then
        }
        final javax.swing.JButton button = new javax.swing.JButton(label);
        button.setMargin(new java.awt.Insets(0, 0, 0, 10));
        button.setFocusable(false);
        button.addActionListener(new java.awt.event.ActionListener() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                if (javax.swing.JOptionPane.showConfirmDialog(button, text(loader, "group.sen.Are_you_sure_you_want_to_clear_Chassis_Intrusion",
                        "Are you sure you want to clear Chassis Intrusion ?"), button.getText(), javax.swing.JOptionPane.YES_NO_OPTION)
                        != javax.swing.JOptionPane.YES_OPTION)
                    return;
                button.setEnabled(false);
                new Thread(new Runnable() {
                    @Override
                    public void run() {
                        boolean ok = false;
                        try {
                            ok = clearIntrusion(textView, loader);
                        } catch (Exception ex) {
                            Log.d("clear chassis intrusion failed: " + ex);
                        }
                        final boolean done = ok;
                        javax.swing.SwingUtilities.invokeLater(new Runnable() {
                            @Override
                            public void run() {
                                button.setEnabled(true);
                                javax.swing.JOptionPane.showMessageDialog(button, done
                                    ? text(loader, "group.sen.Chassis_Intrusion_had_been_cleared_successfully", "Chassis Intrusion had been cleared successfully")
                                    : "Clearing the chassis intrusion failed.");
                                try {
                                    textView.getClass().getMethod("refresh").invoke(textView);
                                } catch (Exception ex) {
                                    Log.d("sensors text view not refreshed: " + ex);
                                }
                            }
                        });
                    }
                }, "iKVM-KeyPasta clear chassis intrusion").start();
            }
        });
        toolbar.add(button);
        toolbar.revalidate();
    }

    private static boolean clearIntrusion(Object textView, ClassLoader loader) throws Exception {
        Object config = field(field(textView, "contorller"), "interfaceConfig");
        Class<?> oemClass = Class.forName("com.supermicro.ipmi.IPMIOEMCommand", true, loader);
        Object oem = oemClass.getConstructor(Class.forName("com.supermicro.ipmi.IPMIInterface", true, loader)).newInstance((Object) null);
        Object controller = Class.forName("com.supermicro.ipmi.SessionControllerFactory", true, loader)
            .getMethod("createSessionControllerWithRetry", Class.forName("com.supermicro.ipmi.IPMIInterfaceConfig", true, loader),
                Class.forName("com.supermicro.ipmi.IPMICommand", true, loader))
            .invoke(null, config, oem);
        try {
            boolean ok = (Boolean) oemClass.getMethod("clearChassisIntrusion").invoke(oem);
            Log.d("clear chassis intrusion: " + (ok ? "done" : "refused by the BMC"));
            return ok;
        } finally {
            if (controller != null)
                Class.forName("com.supermicro.ipmi.ISessionController", true, loader).getMethod("closeSession").invoke(controller);
        }
    }

    private static String text(ClassLoader loader, String key, String english) {
        try {
            return (String) Class.forName("IPMIView20.L", true, loader).getMethod("t", String.class).invoke(null, key);
        } catch (Exception e) {
            return english;
        }
    }

    private static Object field(Object o, String name) throws Exception {
        Field f = o.getClass().getDeclaredField(name);
        f.setAccessible(true);
        return f.get(o);
    }

    /** Its BMC's IP: field ip or loginIP (in the class or a superclass). */
    private static String ip(Window flash) {
        for (Class<?> c = flash.getClass(); c != null && c != JDialog.class; c = c.getSuperclass())
            for (String name : new String[] {"ip", "loginIP"}) {
                try {
                    Field f = c.getDeclaredField(name);
                    f.setAccessible(true);
                    Object v = f.get(flash);
                    if (v instanceof String && !((String) v).isEmpty())
                        return (String) v;
                } catch (NoSuchFieldException e) {
                    // the next
                } catch (Exception e) {
                    return null;
                }
            }
        return null;
    }

    private static java.util.List<Component> all(Container c) {
        java.util.List<Component> list = new java.util.ArrayList<Component>();
        for (Component child : c.getComponents()) {
            list.add(child);
            if (child instanceof Container)
                list.addAll(all((Container) child));
        }
        return list;
    }

    /** An eye (open: show; struck through: hide), drawn in the field's text color. */
    private static final class Eye implements Icon {
        private final boolean struck;

        Eye(boolean struck) {
            this.struck = struck;
        }

        @Override
        public void paintIcon(Component c, Graphics g, int x, int y) {
            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            Color color = c.getParent() != null ? c.getParent().getForeground() : Color.DARK_GRAY;
            g2.setColor(new Color(color.getRed(), color.getGreen(), color.getBlue(), 170));
            g2.setStroke(new BasicStroke(1.3f));
            java.awt.geom.Path2D lid = new java.awt.geom.Path2D.Double();
            lid.moveTo(x + 1, y + 6);
            lid.quadTo(x + 8, y - 1.5, x + 15, y + 6);
            lid.quadTo(x + 8, y + 13.5, x + 1, y + 6);
            g2.draw(lid);
            g2.fillOval(x + 5, y + 3, 6, 6);
            if (struck) {
                g2.setStroke(new BasicStroke(1.6f));
                g2.drawLine(x + 2, y + 11, x + 14, y + 1);
            }
            g2.dispose();
        }

        @Override
        public int getIconWidth() {
            return 16;
        }

        @Override
        public int getIconHeight() {
            return 12;
        }
    }
}
