package keypasta;

import java.awt.EventQueue;
import java.awt.Frame;
import java.awt.Window;
import java.util.ArrayList;
import java.util.List;
import java.awt.Image;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.util.Locale;
import javax.imageio.ImageIO;

/**
 * macOS: IPMIView's Dock icon. IPMIView (the Linux package, run on macOS) only sets a window icon,
 * which macOS doesn't show, so the Dock shows Java's. The Dock gets that window icon instead (the
 * one Windows and Linux show, also an OEM's), enlarged without smoothing (crisp in the Dock),
 * through java.awt.Taskbar (Java 9+, by reflection: the agent is built for Java 8).
 *
 * The iKVM viewer has no icon of its own (Java's everywhere): KeyPasta's (icon-*.png in this jar,
 * from mac/icons/iKVM-KeyPasta.svg) on its windows, and on macOS in the Dock, following dark/light
 * mode (icon-light-512.png from iKVM-KeyPasta-light-mode.svg). Java has no event for that: the
 * setting (defaults read -g AppleInterfaceStyle) is read again whenever macOS's global preferences
 * file changes, checked every 2 s.
 *
 * macOS: IPMIView's menus in the Mac menu bar, missing after IPMIView started (the app menu only):
 * the viewer's remedies, ViewerWatch.installIpmiview (the menu bar watch, the focus watch).
 */
final class Icons {
    static final String IPMIVIEW_MAIN = "IPMIView20/IPMIView20";
    private static boolean done;

    private Icons() {
    }

    static boolean isMac() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("mac");
    }

    /** From the class loading of IPMIView's main class: AWT only from a thread of its own. */
    static synchronized void ipmiviewDock() {
        if (done || !isMac())
            return;
        done = true;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    EventQueue.invokeLater(new Runnable() {
                        @Override
                        public void run() {
                            watchIpmiviewWindows();
                        }
                    });
                } catch (Throwable e) {
                    Log.d("IPMIView Dock icon failed: " + e);
                }
            }
        }, "iKVM-KeyPasta icon");
        t.setDaemon(true);
        t.start();
    }

    private static boolean ipmiviewDockSet;

    /** The first frame with an icon (IPMIView sets it before showing its main window). */
    private static void watchIpmiviewWindows() {
        try {
            ViewerWatch.installIpmiview();
        } catch (Throwable t) {
            Log.d("IPMIView watch not installed: " + t);
        }
        for (Frame f : Frame.getFrames())
            ipmiviewWindow(f);
        java.awt.Toolkit.getDefaultToolkit().addAWTEventListener(new java.awt.event.AWTEventListener() {
            @Override
            public void eventDispatched(java.awt.AWTEvent e) {
                try {
                    if (e.getID() == java.awt.event.WindowEvent.WINDOW_OPENED)
                        ipmiviewWindow(((java.awt.event.WindowEvent) e).getWindow());
                } catch (RuntimeException ex) {
                    Log.d("IPMIView Dock icon failed: " + ex);
                }
            }
        }, java.awt.AWTEvent.WINDOW_EVENT_MASK);
    }

    private static void ipmiviewWindow(Window w) {
        if (ipmiviewDockSet || !(w instanceof Frame) || w.getIconImages().isEmpty())
            return;
        Image best = null;
        for (Image i : w.getIconImages())
            if (best == null || i.getWidth(null) > best.getWidth(null))
                best = i;
        int size = best.getWidth(null), height = best.getHeight(null);
        if (size <= 0 || height <= 0)
            return;                                  // not loaded yet: the next window
        ipmiviewDockSet = true;
        BufferedImage src = new BufferedImage(size, height, BufferedImage.TYPE_INT_ARGB);
        src.getGraphics().drawImage(best, 0, 0, null);
        setDockIcon(enlarge(src, Math.max(1, 256 / size)));
    }

    private static List<Image> keypasta;
    private static boolean viewerDockSet;

    /** A viewer window: KeyPasta's icon (its dialogs show their owner's). Event dispatch thread. */
    static void viewerWindow(Window w) {
        if (!(w instanceof Frame))
            return;
        List<Image> icons = keypastaIcons();
        if (icons.isEmpty())
            return;
        if (!icons.equals(w.getIconImages()))
            w.setIconImages(icons);
        if (isMac() && !viewerDockSet) {
            viewerDockSet = true;
            watchAppearance(icons.get(icons.size() - 1));
        }
    }

    private static void watchAppearance(final Image darkIcon) {
        final Image lightIcon = image("icon-light-512.png");
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                Thread t = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        File prefs = new File(System.getProperty("user.home"), "Library/Preferences/.GlobalPreferences.plist");
                        long seen = Long.MIN_VALUE;
                        Boolean shown = null;
                        while (true) {
                            long modified = prefs.lastModified();
                            if (modified != seen) {
                                seen = modified;
                                final boolean dark = darkMode();
                                if (shown == null || shown != dark) {
                                    shown = dark;
                                    EventQueue.invokeLater(new Runnable() {
                                        @Override
                                        public void run() {
                                            setDockIcon(dark || lightIcon == null ? darkIcon : lightIcon);
                                        }
                                    });
                                }
                            }
                            try {
                                Thread.sleep(2000);
                            } catch (InterruptedException e) {
                                return;
                            }
                        }
                    }
                }, "iKVM-KeyPasta appearance");
                t.setDaemon(true);
                t.start();
            }
        });
    }

    private static boolean darkMode() {
        try {
            Process p = new ProcessBuilder("/usr/bin/defaults", "read", "-g", "AppleInterfaceStyle")
                .redirectErrorStream(true).start();
            InputStream in = p.getInputStream();
            byte[] buf = new byte[64];
            int n = in.read(buf);
            p.waitFor();
            return n > 0 && new String(buf, 0, n, "UTF-8").trim().equalsIgnoreCase("Dark");
        } catch (Exception e) {
            return true;    // the default icon
        }
    }

    static Image image(final String name) {
        final Image[] out = new Image[1];
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                try {
                    InputStream in = Icons.class.getResourceAsStream(name);
                    if (in != null) {
                        try {
                            out[0] = ImageIO.read(in);
                        } finally {
                            in.close();
                        }
                    }
                } catch (Exception e) {
                    Log.d("icon " + name + " failed: " + e);
                }
            }
        });
        return out[0];
    }

    private static List<Image> keypastaIcons() {
        if (keypasta != null)
            return keypasta;
        final List<Image> list = new ArrayList<Image>();
        Privileged.run(new Runnable() {
            @Override
            public void run() {
                for (int size : new int[] {16, 24, 32, 48, 64, 128, 256, 512}) {
                    try {
                        InputStream in = Icons.class.getResourceAsStream("icon-" + size + ".png");
                        if (in == null)
                            continue;
                        try {
                            list.add(ImageIO.read(in));
                        } finally {
                            in.close();
                        }
                    } catch (Exception e) {
                        Log.d("icon " + size + " failed: " + e);
                    }
                }
            }
        });
        keypasta = list;
        return list;
    }

    private static void setDockIcon(Image icon) {
        try {
            Class<?> taskbar = Class.forName("java.awt.Taskbar");
            if (!(Boolean) taskbar.getMethod("isTaskbarSupported").invoke(null))
                return;
            Object bar = taskbar.getMethod("getTaskbar").invoke(null);
            Method set = taskbar.getMethod("setIconImage", Image.class);
            set.invoke(bar, icon);
            Log.d("Dock icon set");
        } catch (ClassNotFoundException e) {
            Log.d("no Dock icon on Java 8");
        } catch (Throwable e) {
            Log.d("IPMIView Dock icon failed: " + e);
        }
    }

    private static BufferedImage enlarge(BufferedImage src, int scale) {
        BufferedImage big = new BufferedImage(src.getWidth() * scale, src.getHeight() * scale, BufferedImage.TYPE_INT_ARGB);
        for (int y = 0; y < big.getHeight(); y++)
            for (int x = 0; x < big.getWidth(); x++)
                big.setRGB(x, y, src.getRGB(x / scale, y / scale));
        return big;
    }
}
