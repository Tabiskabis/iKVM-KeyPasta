package com.apple.laf;

import java.awt.Graphics;
import java.awt.Rectangle;
import javax.swing.JTabbedPane;
import javax.swing.plaf.TabbedPaneUI;

/** Compile-time stand-in for macOS's class (build.sh/build.cmd: not in the jar). */
public class AquaTabbedPaneUI extends TabbedPaneUI {
    public AquaTabbedPaneUI() {
    }

    protected void paintContentBorder(Graphics g, int tabPlacement, int selectedIndex) {
    }

    @Override
    public int tabForCoordinate(JTabbedPane pane, int x, int y) {
        return -1;
    }

    @Override
    public Rectangle getTabBounds(JTabbedPane pane, int index) {
        return null;
    }

    @Override
    public int getTabRunCount(JTabbedPane pane) {
        return 0;
    }
}
