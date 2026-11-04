package keypasta;

import java.awt.Window;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.KeyEvent;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;
import java.lang.reflect.Field;
import javax.swing.ButtonGroup;
import javax.swing.BoxLayout;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JLabel;
import javax.swing.JMenu;
import javax.swing.JMenuItem;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JPopupMenu;
import javax.swing.SwingUtilities;
import javax.swing.event.PopupMenuEvent;
import javax.swing.event.PopupMenuListener;

/**
 * Adds "KeyPasta Preferences", below a separator, to the iKVM viewer's "Options" menu. The
 * dialog behind it lets the
 * user turn the keyboard fixes and the paste hotkey on or off on their own, and say which layout the
 * remote uses: one of Layouts.CODES (fast paste: each character by its keys) or another one
 * (safe paste: Alt codes). Choices are stored in Config and persisted in its settings file (Config.file()).
 *
 * The viewer (tw.com.aten.ikvm.ui.Viewer, a JFrame) holds its Options menu in a public field
 * named "menuOption"; it is reached by reflection so the agent needs none of the viewer's
 * classes at compile time. The viewer fills that menu after the window opens, so the item is
 * (re)appended at the end each time the menu is about to show, which also keeps it last.
 */
final class Menu {
    private static final String ITEM = "KeyPasta Preferences";
    /** Marks a menu we have already hooked, so a re-activated window is not hooked twice. */
    private static final String HOOKED = "keypasta.menuHooked";

    private Menu() {
    }

    static void addTo(Window window, KeyFix fix) {
        if (window == null) {
            return;
        }
        final JMenu options = optionsMenu(window);
        if (options == null || Boolean.TRUE.equals(options.getClientProperty(HOOKED))) {
            return;
        }
        options.putClientProperty(HOOKED, Boolean.TRUE);
        vetoAlwaysOnTop(window);   // ATEN forces the viewer always-on-top on every reconnect; undo it
        final Config config = fix.config;
        final JMenuItem item = new JMenuItem(ITEM);
        final JPopupMenu.Separator line = new JPopupMenu.Separator();
        item.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                // Decoupled from the menu's own event dispatch, and guarded, so nothing here can
                // disturb the viewer.
                SwingUtilities.invokeLater(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            showDialog(window, fix);
                        } catch (Throwable t) {
                            Log.d("KeyPasta dialog failed: " + t);
                        }
                    }
                });
            }
        });
        // Ours stays last, below a separator, however the viewer orders its items: placed now,
        // whenever the viewer adds an item, and right before the menu shows. (With the Mac menu
        // bar the menu never shows as a Swing popup: it mirrors the items it has.)
        final Runnable place = new Runnable() {
            @Override
            public void run() {
                try {
                    int n = options.getMenuComponentCount();
                    if (n > 1 && options.getMenuComponent(n - 1) == item
                            && options.getMenuComponent(n - 2) == line) {
                        return;     // already last, below its separator
                    }
                    options.getPopupMenu().remove(line);    // no-op if not present
                    options.remove(item);
                    options.getPopupMenu().add(line);
                    options.add(item);
                } catch (Throwable t) {
                    Log.d("placing KeyPasta item failed: " + t);
                }
            }
        };
        place.run();
        options.getPopupMenu().addContainerListener(new java.awt.event.ContainerAdapter() {
            @Override
            public void componentAdded(java.awt.event.ContainerEvent e) {
                if (e.getChild() != item && e.getChild() != line)
                    SwingUtilities.invokeLater(place);
            }
        });
        options.getPopupMenu().addPopupMenuListener(new PopupMenuListener() {
            @Override
            public void popupMenuWillBecomeVisible(PopupMenuEvent e) {
                place.run();
            }

            @Override
            public void popupMenuWillBecomeInvisible(PopupMenuEvent e) {
            }

            @Override
            public void popupMenuCanceled(PopupMenuEvent e) {
            }
        });
        if (Config.MAC)
            removeExitMenu(window);
        Log.d("hooked KeyPasta into the Options menu");
    }

    /** ATEN calls setAlwaysOnTop(true) on the viewer on every connection retry. Put it back to
     *  false and keep it there, so dialogs (virtual media, options) are not buried under the viewer. */
    private static void vetoAlwaysOnTop(final Window w) {
        try {
            w.setAlwaysOnTop(false);
            w.addPropertyChangeListener("alwaysOnTop", new PropertyChangeListener() {
                @Override
                public void propertyChange(PropertyChangeEvent e) {
                    if (Boolean.TRUE.equals(e.getNewValue())) {
                        try { w.setAlwaysOnTop(false); } catch (Throwable t) { Log.d("undo always-on-top failed: " + t); }
                    }
                }
            });
        } catch (Throwable t) {
            Log.d("disabling always-on-top failed: " + t);
        }
    }

    /**
     * macOS: the viewer's "Exit" menu (a menu without items that closes the viewer) is left out:
     * in the Mac menu bar the app menu's Quit and the window's close button do the same.
     */
    private static void removeExitMenu(Window window) {
        try {
            Object exit = window.getClass().getField("menuExit").get(window);
            if (exit instanceof JMenu && ((JMenu) exit).getParent() != null) {
                java.awt.Container bar = ((JMenu) exit).getParent();
                bar.remove((JMenu) exit);
                bar.revalidate();
                Log.d("Exit menu removed (macOS)");
            }
        } catch (NoSuchFieldException e) {
            // another viewer version
        } catch (Throwable t) {
            Log.d("removing the Exit menu failed: " + t);
        }
    }

    /** The viewer's public "menuOption" JMenu, or null if this window is not the viewer. */
    private static JMenu optionsMenu(Window window) {
        try {
            Field f = window.getClass().getField("menuOption");
            Object value = f.get(window);
            if (value instanceof JMenu) {
                return (JMenu) value;
            }
        } catch (NoSuchFieldException e) {
            // not the viewer window
        } catch (Throwable t) {
            Log.d("looking up the Options menu failed: " + t);
        }
        return null;
    }

    /**
     * A row of the dialog: a setting, its label and hint, and a dropdown of its values (how
     * they're shown: names), or for the hotkey a field that records it from a key press; each with
     * a reset button: for the current host back to the default's value, for the defaults back to
     * the setting's own default.
     */
    private static final class Row {
        final String key, label, hint;
        final String[] values, names;
        final JComboBox<String> box;        // null: the hotkey
        final HotkeyField hot;              // the hotkey's, else null
        final javax.swing.JButton reset = new javax.swing.JButton("↺");
        final JComponent comp;              // box or hot
        final JComponent cell;              // what the dialog places: comp with reset
        /** What each value does, as hover text on its entry and on the dropdown; null: none. */
        String[] tips;

        Row(String key, String label, String hint, String[] values, String[] names) {
            this.key = key;
            this.label = label;
            this.hint = hint;
            this.values = values;
            this.names = names;
            this.box = new JComboBox<String>(names);
            this.hot = null;
            this.comp = box;
            this.cell = withReset(box);
            final javax.swing.ListCellRenderer<? super String> plain = box.getRenderer();
            box.setRenderer(new javax.swing.ListCellRenderer<String>() {
                @Override
                public java.awt.Component getListCellRendererComponent(javax.swing.JList<? extends String> list,
                        String value, int index, boolean selected, boolean focused) {
                    java.awt.Component c = plain.getListCellRendererComponent(list, value, index, selected, focused);
                    if (c instanceof JComponent && index >= 0) {
                        javax.swing.ToolTipManager.sharedInstance().registerComponent(list);
                        ((JComponent) c).setToolTipText(tip(index));
                    }
                    return c;
                }
            });
            box.addItemListener(e -> box.setToolTipText(tip(box.getSelectedIndex())));
        }

        /** The hotkey's row. */
        Row(String key, String label, String hint) {
            this.key = key;
            this.label = label;
            this.hint = hint;
            this.values = this.names = new String[0];
            this.box = null;
            this.hot = new HotkeyField();
            this.comp = hot;
            this.cell = withReset(hot);
        }

        private JComponent withReset(JComponent c) {
            reset.setMargin(new java.awt.Insets(0, 4, 0, 4));
            reset.setFocusable(false);
            JPanel p = new JPanel(new java.awt.BorderLayout(4, 0));
            p.add(c, java.awt.BorderLayout.CENTER);
            p.add(reset, java.awt.BorderLayout.EAST);
            return p;
        }

        /** The hover text of the dropdown's entry i. */
        String tip(int i) {
            return tips == null || i < 0 ? null : tips[i];
        }

        int index(String v) {
            int i = java.util.Arrays.asList(values).indexOf(v);
            return i >= 0 ? i : 0;
        }

        void show(String v) {
            if (hot != null) {
                hot.show(v);
                return;
            }
            box.setSelectedIndex(index(v));
            box.setToolTipText(tip(box.getSelectedIndex()));
        }

        String value() {
            return hot != null ? hot.spec : values[box.getSelectedIndex()];
        }
    }

    /**
     * The paste hotkey's field: shows the hotkey; a click (or Enter or Space on it) starts
     * recording, the next key pressed with its modifiers is the hotkey; Esc cancels, as does
     * leaving the field. Without Ctrl, Alt or Meta only a key that neither types nor edits nor
     * moves (F1-F24, Pause, Scroll Lock, Print Screen): any other couldn't be used on the remote any
     * more. The key as the hotkey check sees it (Paste.hotkeyKey: macOS by its place).
     */
    private static final class HotkeyField extends javax.swing.JTextField {
        private static final int MODS = java.awt.event.InputEvent.CTRL_DOWN_MASK
            | java.awt.event.InputEvent.ALT_DOWN_MASK | java.awt.event.InputEvent.SHIFT_DOWN_MASK
            | java.awt.event.InputEvent.META_DOWN_MASK;
        String spec = "";
        Runnable onChange;
        private boolean recording;
        /** Linux (the container): the Mac's Command comes as the Windows key, which X gives no modifier. */
        private boolean windowsKey;

        HotkeyField() {
            setEditable(false);
            setFocusable(true);
            setToolTipText("Click, then press the key combination (Esc: cancel)");
            addMouseListener(new java.awt.event.MouseAdapter() {
                @Override
                public void mousePressed(java.awt.event.MouseEvent e) {
                    start();
                }
            });
            addFocusListener(new java.awt.event.FocusAdapter() {
                @Override
                public void focusLost(java.awt.event.FocusEvent e) {
                    stop();
                }
            });
            addKeyListener(new java.awt.event.KeyAdapter() {
                @Override
                public void keyPressed(KeyEvent e) {
                    pressed(e);
                }

                @Override
                public void keyReleased(KeyEvent e) {
                    if (e.getKeyCode() == KeyEvent.VK_WINDOWS)
                        windowsKey = false;
                    if (recording)
                        e.consume();
                }

                @Override
                public void keyTyped(KeyEvent e) {
                    if (recording)
                        e.consume();
                }
            });
        }

        void show(String v) {
            spec = v == null ? "" : v;
            if (!recording)
                setText(text());
        }

        private String text() {
            return label(spec);
        }

        private void start() {
            if (recording)
                return;
            recording = true;
            setFocusTraversalKeysEnabled(false);    // Tab is a key like any other now
            requestFocusInWindow();
            setText("Press the keys… (Esc: cancel)");
        }

        private void stop() {
            if (!recording)
                return;
            recording = false;
            setFocusTraversalKeysEnabled(true);
            setText(text());
        }

        private void pressed(KeyEvent e) {
            int code = e.getKeyCode();
            if (code == KeyEvent.VK_WINDOWS)
                windowsKey = true;
            if (!recording) {
                if (code == KeyEvent.VK_ENTER || code == KeyEvent.VK_SPACE) {
                    e.consume();
                    start();
                }
                return;
            }
            e.consume();
            if (code == KeyEvent.VK_SHIFT || code == KeyEvent.VK_CONTROL || code == KeyEvent.VK_ALT
                    || code == KeyEvent.VK_ALT_GRAPH || code == KeyEvent.VK_META || code == KeyEvent.VK_WINDOWS)
                return;                             // a modifier: the key comes next
            int mods = e.getModifiersEx() & MODS;
            if (!Config.MAC && windowsKey)
                mods |= java.awt.event.InputEvent.META_DOWN_MASK;
            if (code == KeyEvent.VK_ESCAPE && mods == 0) {
                stop();
                return;
            }
            int key = Paste.hotkeyKey(e);
            String name = Config.keyName(key);
            boolean alone = (key >= KeyEvent.VK_F1 && key <= KeyEvent.VK_F12)
                || (key >= KeyEvent.VK_F13 && key <= KeyEvent.VK_F24) || key == KeyEvent.VK_PAUSE
                || key == KeyEvent.VK_SCROLL_LOCK || key == KeyEvent.VK_PRINTSCREEN;
            if (name == null || (!alone && (mods & ~java.awt.event.InputEvent.SHIFT_DOWN_MASK) == 0)) {
                java.awt.Toolkit.getDefaultToolkit().beep();
                return;                             // still recording
            }
            spec = Config.hotkeySpec(mods, name);
            stop();
            if (onChange != null)
                onChange.run();
        }

        /** "Ctrl+Alt+V", on macOS "⌃⌥V"; the spec itself if it isn't a hotkey. */
        static String label(String spec) {
            int[] k = Config.hotkeyKeys(spec);
            if (k == null)
                return spec;
            String mods = KeyEvent.getModifiersExText(k[0]);
            String key = KeyEvent.getKeyText(k[1]);
            return mods.isEmpty() ? key : Config.MAC ? mods + key : mods + "+" + key;
        }
    }

    private static final java.awt.Color OWN = new java.awt.Color(0x0a64d8);
    private static final java.awt.Color FROM_DEFAULT = java.awt.Color.GRAY;

    /**
     * KeyPasta Preferences: every setting with a default and, for the current host (the BMC in
     * the viewer's title), a value of its own or the default's. A switch shows one level at a
     * time: the current host's (values taken from the default in grey italics, its own in blue;
     * each row's reset button takes its own value away) or the defaults (reset: the setting's own
     * default). Hover texts stay while the pointer is there. "Hosts with own settings..."
     * lists all hosts that have any, each to reset. Saved on OK (see Config).
     */
    private static void showDialog(Window parent, final KeyFix fix) {
        final Config config = fix.config;
        config.useBmc(KeyFix.bmcOf(parent));
        final String host = config.bmc();
        final java.util.Map<String, String> def = new java.util.HashMap<String, String>(config.defaults);
        final java.util.Map<String, String> own = new java.util.HashMap<String, String>(config.own);

        String[] layoutValues = new String[Layouts.CODES.length + 1];
        System.arraycopy(Layouts.CODES, 0, layoutValues, 0, Layouts.CODES.length);
        layoutValues[layoutValues.length - 1] = "other";
        String[] layoutNames = new String[Layouts.NAMES.length + 1];
        System.arraycopy(Layouts.NAMES, 0, layoutNames, 0, Layouts.NAMES.length);
        layoutNames[layoutNames.length - 1] = "Other: everything as Alt codes (slow)";
        String[] onOff = {"true", "false"}, onOffNames = {"On", "Off"};
        java.util.List<Row> rows = new java.util.ArrayList<Row>();
        rows.add(new Row(Config.KEY_FIX, "Keyboard fixes", "Key positions, Ctrl, dead keys", onOff, onOffNames));
        rows.add(new Row(Config.SWAP, "Swap Alt and GUI keys", "GUI is Cmd on Mac and Win on PC keyboards",
            new String[] {"false", "true"}, new String[] {"Not swapped", "Swapped"}));
        rows.add(new Row(Config.TOGGLE, "Toggle keys", "Caps Lock, Num Lock, Scroll Lock",
            new String[] {"unaltered", "both", "passthrough"},
            new String[] {"Unaltered behavior", "Toggle both sides", "Passthrough"}));
        rows.get(rows.size() - 1).tips = new String[] {
            "<html>The viewer's own handling. Your lights and the remote's easily get out of step."
                + (Config.MAC ? "<br>On a Mac KeyPasta only keeps the viewer from quitting without Input Monitoring." : "")
                + "</html>",
            "<html>A press toggles your lock and the remote’s. If they differ, it brings the remote in step<br>"
                + "with yours."
                + (Config.MAC ? "<br>The Clear key is always sent: a Mac has no Num Lock." : "") + "</html>",
            "<html>The key exactly as you press it, down, holding, and up, like any other key. Each side keeps<br>"
                + "its own state: they can get stuck and the lights easily get out of step."
                + (Config.MAC ? "<br>Needs macOS input monitoring permissions." : "") + "</html>"};
        rows.add(new Row(Config.PASTE, "Paste", "Types the clipboard on the remote", onOff, onOffNames));
        rows.add(new Row(Config.HOTKEY, "Paste hotkey", "Click it, then press the keys"));
        rows.add(new Row(Config.LAYOUT, "Remote keyboard layout", "Required for faster paste operation", layoutValues, layoutNames));
        rows.add(new Row(Config.NON_ASCII, "Characters not on the keyboard", "é, €, … when pasting",
            new String[] {"ask", "always", "never"}, new String[] {"Ask when pasting", "Type as Alt codes (slow)", "Leave out"}));
        rows.add(new Row(Config.REMOTE_WINDOWS, "Alt codes for", "The remote system", new String[] {"false", "true"},
            new String[] {"Linux console", "Windows"}));

        final boolean[] hostScope = {!host.isEmpty()};
        final boolean[] filling = {false};
        // the scope's button: Reset (current host) or Hosts with own settings (default), in one
        // place of the size of the bigger one, so nothing moves when switching
        final JPanel buttons = new JPanel(new java.awt.CardLayout());
        final java.util.List<Row> all = rows;
        final Runnable fill = new Runnable() {
            @Override
            public void run() {
                filling[0] = true;
                for (Row r : all) {
                    boolean isOwn = hostScope[0] && own.containsKey(r.key);
                    r.show(isOwn ? own.get(r.key) : def.get(r.key));
                    java.awt.Font f = r.comp.getFont();
                    boolean inherited = hostScope[0] && !isOwn;
                    r.comp.setFont(f.deriveFont(inherited ? java.awt.Font.ITALIC : java.awt.Font.PLAIN));
                    r.comp.setForeground(inherited ? FROM_DEFAULT : isOwn ? OWN
                        : javax.swing.UIManager.getColor(r.hot != null ? "TextField.foreground" : "ComboBox.foreground"));
                    // the host's own value, or a default other than the setting's own
                    r.reset.setEnabled(hostScope[0] ? isOwn : !Config.builtIn(r.key).equals(def.get(r.key)));
                    r.reset.setToolTipText(hostScope[0] ? "Back to the default" : "Back to the built-in default");
                }
                filling[0] = false;
                ((java.awt.CardLayout) buttons.getLayout()).show(buttons, hostScope[0] ? "host" : "default");
            }
        };
        for (final Row r : rows) {
            final Runnable changed = new Runnable() {
                @Override
                public void run() {
                    if (filling[0])
                        return;
                    String v = r.value();
                    String was = hostScope[0] && own.containsKey(r.key) ? own.get(r.key) : def.get(r.key);
                    if (r.hot != null && v.equals(was))
                        return;                     // the same hotkey again: stays the default's
                    if (hostScope[0])
                        own.put(r.key, v);          // the current host's own
                    else
                        def.put(r.key, v);
                    fill.run();
                }
            };
            r.reset.addActionListener(new ActionListener() {
                @Override
                public void actionPerformed(ActionEvent e) {
                    if (hostScope[0])
                        own.remove(r.key);          // follows the default again
                    else
                        def.put(r.key, Config.builtIn(r.key));
                    fill.run();
                }
            });
            if (r.hot != null)
                r.hot.onChange = changed;
            else
                r.box.addActionListener(new ActionListener() {
                    @Override
                    public void actionPerformed(ActionEvent e) {
                        changed.run();
                    }
                });
        }

        JPanel panel = new JPanel(new java.awt.GridBagLayout());
        java.awt.GridBagConstraints g = new java.awt.GridBagConstraints();
        g.gridx = 0;
        g.gridy = 0;
        g.gridwidth = 2;
        g.anchor = java.awt.GridBagConstraints.WEST;
        g.insets = new java.awt.Insets(0, 0, 6, 0);
        // plain labels, not HTML (that wrapped the host onto a line of its own)
        JPanel hostRow = new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.LEFT, 0, 0));
        if (host.isEmpty()) {
            hostRow.add(new JLabel("No current host (the viewer's title names none): the defaults"));
        } else {
            hostRow.add(new JLabel("Current host: "));
            JLabel hostName = new JLabel(host);
            hostName.setFont(hostName.getFont().deriveFont(java.awt.Font.BOLD));
            hostRow.add(hostName);
        }
        // About KeyPasta: a small ? at the top right (macOS: Aqua's round help button)
        javax.swing.JButton about = new javax.swing.JButton(Config.MAC ? "" : "?");
        if (Config.MAC)
            about.putClientProperty("JButton.buttonType", "help");
        else
            about.setMargin(new java.awt.Insets(0, 6, 0, 6));
        about.setToolTipText("About KeyPasta");
        about.setFocusable(false);
        about.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                About.showViewer(javax.swing.SwingUtilities.getWindowAncestor((java.awt.Component) e.getSource()),
                    HotkeyField.label(config.value(Config.HOTKEY)));
            }
        });
        JPanel topRow = new JPanel(new java.awt.BorderLayout(10, 0));
        topRow.add(hostRow, java.awt.BorderLayout.CENTER);
        topRow.add(about, java.awt.BorderLayout.EAST);
        g.fill = java.awt.GridBagConstraints.HORIZONTAL;
        panel.add(topRow, g);
        g.fill = java.awt.GridBagConstraints.NONE;
        final javax.swing.JToggleButton ownScope = new javax.swing.JToggleButton("Current host", hostScope[0]);
        final javax.swing.JToggleButton defScope = new javax.swing.JToggleButton("Default", !hostScope[0]);
        if (!host.isEmpty()) {
            ButtonGroup scope = new ButtonGroup();
            scope.add(ownScope);
            scope.add(defScope);
            ActionListener switchScope = new ActionListener() {
                @Override
                public void actionPerformed(ActionEvent e) {
                    hostScope[0] = ownScope.isSelected();
                    fill.run();
                }
            };
            ownScope.addActionListener(switchScope);
            defScope.addActionListener(switchScope);
            JPanel scopeRow = new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.LEFT, 0, 0));
            scopeRow.add(new JLabel("Settings for  "));
            scopeRow.add(ownScope);
            scopeRow.add(defScope);
            g.gridy++;
            g.insets = new java.awt.Insets(0, 0, 10, 0);
            panel.add(scopeRow, g);
        }
        g.gridwidth = 1;
        for (Row r : rows) {
            g.gridy++;
            g.gridx = 0;
            g.insets = new java.awt.Insets(4, 0, 0, 16);
            g.anchor = java.awt.GridBagConstraints.WEST;
            g.fill = java.awt.GridBagConstraints.NONE;
            JPanel text = new JPanel();
            text.setLayout(new BoxLayout(text, BoxLayout.Y_AXIS));
            JLabel nameRow = new JLabel(r.label);
            nameRow.setAlignmentX(0f);
            JLabel hint = new JLabel(r.hint);
            hint.setFont(hint.getFont().deriveFont(hint.getFont().getSize2D() - 2f));
            hint.setForeground(FROM_DEFAULT);
            hint.setAlignmentX(0f);
            text.add(nameRow);
            text.add(hint);
            panel.add(text, g);
            g.gridx = 1;
            g.anchor = java.awt.GridBagConstraints.EAST;
            g.fill = java.awt.GridBagConstraints.HORIZONTAL;
            g.insets = new java.awt.Insets(4, 0, 0, 0);
            panel.add(r.cell, g);
        }
        g.gridy++;
        g.gridx = 0;
        g.gridwidth = 2;
        g.fill = java.awt.GridBagConstraints.NONE;
        g.anchor = java.awt.GridBagConstraints.WEST;
        g.insets = new java.awt.Insets(10, 0, 0, 0);
        JLabel capsNote = new JLabel("With CapsLock on, a paste types everything as Alt codes (safe paste).");
        capsNote.setFont(capsNote.getFont().deriveFont(capsNote.getFont().getSize2D() - 2f));
        panel.add(capsNote, g);
        g.gridy++;
        final javax.swing.JButton hosts = new javax.swing.JButton("Hosts with own settings…");
        final javax.swing.JButton reset = new javax.swing.JButton("Reset current host to default");
        JPanel hostCard = new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.LEFT, 0, 0));
        hostCard.add(reset);
        JPanel defaultCard = new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.LEFT, 0, 0));
        defaultCard.add(hosts);
        buttons.add(hostCard, "host");
        buttons.add(defaultCard, "default");
        panel.add(buttons, g);
        reset.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                own.clear();
                fill.run();
            }
        });
        final JPanel dialogPanel = panel;
        hosts.addActionListener(new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                showHosts(dialogPanel, config, host, own, fill);
            }
        });
        // every dropdown one fixed width (the widest, plain font, a bit of room for italics): the
        // italics of values taken from the default made them wider, and the dialog's content,
        // centered, moved when switching
        int width = 0;
        for (Row r : rows)
            if (r.box != null)
                width = Math.max(width, r.box.getPreferredSize().width);
        for (Row r : rows) {
            java.awt.Dimension d = new java.awt.Dimension(width + 12 + 4 + r.reset.getPreferredSize().width,
                r.comp.getPreferredSize().height);
            r.cell.setPreferredSize(d);
            r.cell.setMinimumSize(d);
        }
        fill.run();

        // hover texts stay while the pointer is there (Swing hides them after 4 s), for this dialog
        javax.swing.ToolTipManager tips = javax.swing.ToolTipManager.sharedInstance();
        int dismiss = tips.getDismissDelay();
        tips.setDismissDelay(Integer.MAX_VALUE);
        int result;
        try {
            result = JOptionPane.showConfirmDialog(parent, panel, "KeyPasta Preferences",
                JOptionPane.OK_CANCEL_OPTION, JOptionPane.PLAIN_MESSAGE);
        } finally {
            tips.setDismissDelay(dismiss);
        }
        if (result != JOptionPane.OK_OPTION)
            return;
        config.defaults.clear();
        config.defaults.putAll(def);
        config.own.clear();
        config.own.putAll(own);
        config.savePrefs();
        Log.d("settings: default " + config.defaults + (host.isEmpty() ? "" : ", " + host + " own " + config.own));
    }

    /** A host's own values in a few words: "layout us · toggle keys passthrough". */
    private static String summary(java.util.Map<String, String> own) {
        StringBuilder b = new StringBuilder();
        for (String k : Config.SETTINGS) {
            String v = own.get(k);
            if (v == null)
                continue;
            boolean on = v.equals("true");
            String t = k.equals(Config.KEY_FIX) ? "keyboard fixes " + (on ? "on" : "off")
                : k.equals(Config.SWAP) ? (on ? "Alt/Command swapped" : "Alt/Command not swapped")
                : k.equals(Config.TOGGLE) ? "toggle keys " + v
                : k.equals(Config.PASTE) ? "paste " + (on ? "on" : "off")
                : k.equals(Config.HOTKEY) ? "hotkey " + v
                : k.equals(Config.LAYOUT) ? "layout " + v
                : k.equals(Config.NON_ASCII) ? "non-ASCII " + v
                : "Alt codes " + (on ? "Windows" : "Linux");
            if (b.length() > 0)
                b.append(" · ");
            b.append(t);
        }
        return b.toString();
    }

    /** The hosts with own settings (saved ones), each with Reset: it follows the default again. */
    private static void showHosts(java.awt.Component parent, final Config config, final String current,
                                  final java.util.Map<String, String> currentOwn, final Runnable refill) {
        final JPanel list = new JPanel(new java.awt.GridBagLayout());
        final Runnable[] build = new Runnable[1];
        build[0] = new Runnable() {
            @Override
            public void run() {
                list.removeAll();
                java.awt.GridBagConstraints g = new java.awt.GridBagConstraints();
                g.anchor = java.awt.GridBagConstraints.WEST;
                g.insets = new java.awt.Insets(2, 0, 2, 12);
                g.gridy = 0;
                java.util.List<String> hosts = Config.hostsWithOwn();
                if (hosts.isEmpty())
                    list.add(new JLabel("No host has settings of its own."), g);
                for (final String h : hosts) {
                    g.gridx = 0;
                    list.add(new JLabel(h), g);
                    g.gridx = 1;
                    JLabel what = new JLabel(summary(Config.ownOf(h)));
                    what.setForeground(FROM_DEFAULT);
                    list.add(what, g);
                    g.gridx = 2;
                    javax.swing.JButton r = new javax.swing.JButton("Reset");
                    r.addActionListener(new ActionListener() {
                        @Override
                        public void actionPerformed(ActionEvent e) {
                            config.resetHost(h);
                            if (h.equals(current)) {
                                currentOwn.clear();
                                refill.run();
                            }
                            build[0].run();
                        }
                    });
                    list.add(r, g);
                    g.gridy++;
                }
                list.revalidate();
                list.repaint();
                Window w = SwingUtilities.getWindowAncestor(list);
                if (w != null)
                    w.pack();
            }
        };
        build[0].run();
        JOptionPane.showMessageDialog(parent, list, "Hosts with own settings", JOptionPane.PLAIN_MESSAGE);
    }
}
