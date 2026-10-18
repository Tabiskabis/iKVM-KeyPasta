package keypasta;

import java.awt.Window;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.KeyEvent;
import java.beans.PropertyChangeEvent;
import java.beans.PropertyChangeListener;
import java.lang.reflect.Field;
import javax.swing.ButtonGroup;
import javax.swing.Box;
import javax.swing.BoxLayout;
import javax.swing.JCheckBox;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JLabel;
import javax.swing.JMenu;
import javax.swing.JMenuItem;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JRadioButton;
import javax.swing.JPopupMenu;
import javax.swing.SwingUtilities;
import javax.swing.event.PopupMenuEvent;
import javax.swing.event.PopupMenuListener;

/**
 * Adds a "KeyPasta Agent" entry, below a separator, to the iKVM viewer's "Options" menu. The dialog behind it lets the
 * user turn the keyboard fixes and the paste hotkey on or off on their own, and say which layout the
 * remote uses: one of Layouts.CODES (fast paste: each character by its keys) or another one
 * (safe paste: Alt codes). Choices are stored in Config and persisted (java.util.prefs) across runs.
 *
 * The viewer (tw.com.aten.ikvm.ui.Viewer, a JFrame) holds its Options menu in a public field
 * named "menuOption"; it is reached by reflection so the agent needs none of the viewer's
 * classes at compile time. The viewer fills that menu after the window opens, so the item is
 * (re)appended at the end each time the menu is about to show, which also keeps it last.
 */
final class Menu {
    private static final String ITEM = "KeyPasta Agent";
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

    private static void showDialog(Window parent, KeyFix fix) {
        final Config config = fix.config;
        config.useBmc(KeyFix.bmcOf(parent));
        final JCheckBox keyFix = new JCheckBox("Keyboard fixes (key positions, Ctrl, dead keys, CapsLock per window)", config.enableKeyFix);

        // Alt and Command swapped: a default for all BMCs, and this one's own, if it differs.
        final JLabel swapLabel = new JLabel(Config.MAC
            ? "Swap Option and Command (Command: the remote's Alt, Option: its Windows key):"
            : "Swap Alt and the Windows key (Command on a Mac in the browser): Windows/Command is the remote's Alt:");
        final JLabel swapDefaultLabel = new JLabel("Default:");
        final JComboBox<String> swapDefault = new JComboBox<String>(new String[] {"Don't swap", "Swap"});
        swapDefault.setSelectedIndex(config.swapDefault ? 1 : 0);
        final JLabel swapBmcLabel = new JLabel(config.bmc() + ":");
        final JComboBox<String> swapBmc = new JComboBox<String>(new String[] {"Same as the default", "Don't swap", "Swap"});
        swapBmc.setSelectedIndex(config.bmcSwap == null ? 0 : config.bmcSwap ? 2 : 1);
        JPanel swapGrid = new JPanel(new java.awt.GridBagLayout());
        java.awt.GridBagConstraints sg = new java.awt.GridBagConstraints();
        sg.anchor = java.awt.GridBagConstraints.WEST;
        sg.insets = new java.awt.Insets(1, 0, 1, 6);
        sg.gridy = 0;
        swapGrid.add(swapDefaultLabel, sg);
        swapGrid.add(swapDefault, sg);
        if (!config.bmc().isEmpty()) {
            sg.gridy = 1;
            swapGrid.add(swapBmcLabel, sg);
            swapGrid.add(swapBmc, sg);
        }
        swapGrid.setMaximumSize(swapGrid.getPreferredSize());
        final JComponent[] swapParts = {swapLabel, swapDefaultLabel, swapDefault, swapBmcLabel, swapBmc};
        ActionListener enableSwap = new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                for (JComponent c : swapParts)
                    c.setEnabled(keyFix.isSelected());
            }
        };
        keyFix.addActionListener(enableSwap);
        enableSwap.actionPerformed(null);
        final JCheckBox paste = new JCheckBox("Paste the clipboard with " + hotkey(config), config.enablePaste);

        // How the paste types: depends on the remote's keyboard layout. A default for all BMCs,
        // and this one's own, if it differs.
        final String otherName = "Other: everything as Alt codes (slow)";
        final JLabel layoutLabel = new JLabel("Keyboard layout of the remote computer:");
        final JLabel defaultLabel = new JLabel("Default:");
        String[] names = new String[Layouts.NAMES.length + 1];
        System.arraycopy(Layouts.NAMES, 0, names, 0, Layouts.NAMES.length);
        names[names.length - 1] = otherName;
        final JComboBox<String> defaults = new JComboBox<String>(names);
        defaults.setSelectedIndex(layoutIndex(config.defaultLayout));
        final String bmc = config.bmc();
        final JLabel bmcLabel = new JLabel(bmc + ":");
        String[] bmcNames = new String[names.length + 1];
        bmcNames[0] = "Same as the default";
        System.arraycopy(names, 0, bmcNames, 1, names.length);
        final JComboBox<String> bmcLayouts = new JComboBox<String>(bmcNames);
        bmcLayouts.setSelectedIndex(config.bmcLayout == null ? 0 : 1 + layoutIndex(config.bmcLayout));
        JPanel layoutGrid = new JPanel(new java.awt.GridBagLayout());
        java.awt.GridBagConstraints g = new java.awt.GridBagConstraints();
        g.anchor = java.awt.GridBagConstraints.WEST;
        g.insets = new java.awt.Insets(1, 0, 1, 6);
        g.gridy = 0;
        layoutGrid.add(defaultLabel, g);
        layoutGrid.add(defaults, g);
        if (!bmc.isEmpty()) {
            g.gridy = 1;
            layoutGrid.add(bmcLabel, g);
            layoutGrid.add(bmcLayouts, g);
        }
        layoutGrid.setMaximumSize(layoutGrid.getPreferredSize());
        final JLabel nonAsciiLabel = new JLabel("Characters that aren't on the keyboard (é, €, …):");
        final JRadioButton ask = new JRadioButton("Ask when pasting", config.pasteNonAscii.equals("ask"));
        final JRadioButton always = new JRadioButton("Type as Alt codes (slow)", config.pasteNonAscii.equals("always"));
        final JRadioButton never = new JRadioButton("Leave out", config.pasteNonAscii.equals("never"));
        ButtonGroup nonAscii = new ButtonGroup();
        nonAscii.add(ask);
        nonAscii.add(always);
        nonAscii.add(never);
        final JLabel osLabel = new JLabel("Alt codes for the remote system:");
        final JRadioButton linux = new JRadioButton("Linux console", !config.remoteWindows);
        final JRadioButton windows = new JRadioButton("Windows", config.remoteWindows);
        ButtonGroup os = new ButtonGroup();
        os.add(linux);
        os.add(windows);
        final JLabel capsNote = new JLabel("With CapsLock on, a paste types everything as Alt codes (safe paste).");
        capsNote.setFont(capsNote.getFont().deriveFont(capsNote.getFont().getSize2D() - 2f));

        final JComponent[] pasteParts = {layoutLabel, defaultLabel, defaults, bmcLabel, bmcLayouts, nonAsciiLabel, ask, always, never, capsNote,
            osLabel, linux, windows};
        ActionListener enable = new ActionListener() {
            @Override
            public void actionPerformed(ActionEvent e) {
                for (JComponent c : pasteParts)
                    c.setEnabled(paste.isSelected());
            }
        };
        paste.addActionListener(enable);
        enable.actionPerformed(null);

        JPanel panel = new JPanel();
        panel.setLayout(new BoxLayout(panel, BoxLayout.Y_AXIS));
        panel.add(left(keyFix));
        JPanel keySub = new JPanel();                      // the swap, under the keyboard fixes, indented
        keySub.setLayout(new BoxLayout(keySub, BoxLayout.Y_AXIS));
        keySub.setBorder(javax.swing.BorderFactory.createEmptyBorder(2, 24, 0, 0));
        keySub.add(left(swapLabel));
        keySub.add(choices(swapGrid));
        panel.add(left(keySub));
        panel.add(Box.createVerticalStrut(6));
        panel.add(left(paste));
        JPanel sub = new JPanel();                         // the paste's details, under it, indented
        sub.setLayout(new BoxLayout(sub, BoxLayout.Y_AXIS));
        sub.setBorder(javax.swing.BorderFactory.createEmptyBorder(2, 24, 0, 0));
        sub.add(left(layoutLabel));
        sub.add(choices(layoutGrid));
        sub.add(Box.createVerticalStrut(6));
        sub.add(left(nonAsciiLabel));
        sub.add(choices(ask, always, never));
        sub.add(Box.createVerticalStrut(6));
        sub.add(left(osLabel));
        sub.add(choices(linux, windows));
        sub.add(Box.createVerticalStrut(8));
        sub.add(left(capsNote));                    // for all of the above
        panel.add(left(sub));

        int result = JOptionPane.showConfirmDialog(parent, panel, "KeyPasta",
            JOptionPane.OK_CANCEL_OPTION, JOptionPane.PLAIN_MESSAGE);
        if (result != JOptionPane.OK_OPTION) {
            return;
        }
        config.enableKeyFix = keyFix.isSelected();
        config.swapDefault = swapDefault.getSelectedIndex() == 1;
        config.swapSaid = true;
        if (!bmc.isEmpty())
            config.bmcSwap = swapBmc.getSelectedIndex() == 0 ? null : Boolean.valueOf(swapBmc.getSelectedIndex() == 2);
        config.enablePaste = paste.isSelected();
        config.defaultLayout = layoutCode(defaults.getSelectedIndex());
        config.defaultSaid = true;                  // said: fast paste no longer asks about it
        if (!bmc.isEmpty())
            config.bmcLayout = bmcLayouts.getSelectedIndex() == 0 ? null : layoutCode(bmcLayouts.getSelectedIndex() - 1);
        config.applyLayout();
        config.pasteNonAscii = ask.isSelected() ? "ask" : always.isSelected() ? "always" : "never";
        config.remoteWindows = windows.isSelected();
        config.savePrefs();
        Log.d("settings: keyFix=" + config.enableKeyFix + " paste=" + config.enablePaste
            + " default layout=" + config.defaultLayout + " " + bmc + "=" + (config.bmcLayout == null ? "default" : config.bmcLayout)
            + " nonAscii=" + config.pasteNonAscii + " remoteWindows=" + config.remoteWindows
            + " swapAltCmd default=" + config.swapDefault + " " + bmc + "=" + (config.bmcSwap == null ? "default" : config.bmcSwap));
    }

    /** Index of a layout code (or other: the last) in the dropdown. */
    private static int layoutIndex(String code) {
        int i = java.util.Arrays.asList(Layouts.CODES).indexOf(code);
        return i >= 0 ? i : Layouts.CODES.length;
    }

    private static String layoutCode(int index) {
        return index < Layouts.CODES.length ? Layouts.CODES[index] : "other";
    }

    /** Choices under their label, a little indented. */
    private static JComponent choices(JComponent... parts) {
        JPanel p = new JPanel();
        p.setLayout(new BoxLayout(p, BoxLayout.Y_AXIS));
        p.setBorder(javax.swing.BorderFactory.createEmptyBorder(0, 12, 0, 0));
        for (JComponent c : parts)
            p.add(left(c));
        return left(p);
    }

    private static JComponent left(JComponent c) {
        c.setAlignmentX(JComponent.LEFT_ALIGNMENT);
        return c;
    }

    /** A readable name for the paste shortcut, e.g. "⌥⇧V" on macOS, "Alt+Shift+V" elsewhere. */
    private static String hotkey(Config config) {
        String mods = KeyEvent.getModifiersExText(config.pasteMods);
        String key = KeyEvent.getKeyText(config.pasteKey);
        return mods.isEmpty() ? key : mods + "+" + key;
    }
}
