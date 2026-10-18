package keypasta;

import java.awt.Font;
import java.awt.GraphicsEnvironment;
import java.lang.reflect.Method;
import java.util.Arrays;
import javax.swing.plaf.FontUIResource;

/**
 * macOS and Linux: IPMIView's font. Everywhere but on Windows, IPMIView (setDefaultFont) loads
 * PMingLiU-02.ttf from its working folder and makes it the font of all of its Swing parts, 12 pt:
 * a Taiwanese font whose Latin letters are thin and hard to read at that size (on Linux without
 * antialiasing: its jagged built-in bitmaps). IPMIView's call of setDefaultFont lands here
 * (Patch.redirectFonts) and sets another font instead, the way IPMIView sets its font (its
 * setUIFont, and IPMI_DEFAULT_FONT for the fonts it makes itself, sizes kept); if none of the list
 * is there, IPMIView's own setDefaultFont.
 * - macOS, 13 pt: SF Pro (San Francisco) if installed (Apple's download), else Helvetica Neue.
 *   Only fonts macOS lists: those Java draws with macOS's own text rendering (Core Text). The
 *   system copy of San Francisco is hidden from that list; loaded from its file (Font.createFont)
 *   Java draws it with its own rasterizer, heavier than macOS's.
 * - Linux, 12 pt: Noto Sans, DejaVu Sans, Liberation Sans, else Java's SansSerif (fontconfig's
 *   sans font). Antialiasing: Agent (awt.useSystemAAFontSettings).
 * Labels cut by the wider font: Widen (macOS).
 */
public final class Fonts {
    static final int SIZE = Config.MAC ? 13 : 12;

    private Fonts() {
    }

    public static void setDefaultFont(Object ipmiview) {
        Class<?> c = ipmiview.getClass();
        try {
            Font font = font();
            c.getMethod("setUIFont", FontUIResource.class).invoke(null, new FontUIResource(font.deriveFont(Font.PLAIN, SIZE)));
            c.getField("IPMI_DEFAULT_FONT").set(null, font.getFamily());
            Log.d("IPMIView font: " + font.getFamily() + " " + SIZE);
            return;
        } catch (Throwable t) {
            Log.d("IPMIView font unchanged: " + t);
        }
        try {
            Method own = c.getDeclaredMethod("setDefaultFont");
            own.setAccessible(true);
            own.invoke(ipmiview);
        } catch (Throwable t) {
            Log.d("IPMIView's setDefaultFont failed: " + t);
        }
    }

    private static Font font() {
        java.util.List<String> families = Arrays.asList(GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames());
        String[] wanted = Config.MAC ? new String[] {"SF Pro Text", "SF Pro", "Helvetica Neue"}
            : new String[] {"Noto Sans", "DejaVu Sans", "Liberation Sans", Font.SANS_SERIF};
        for (String f : wanted)
            if (families.contains(f) || f.equals(Font.SANS_SERIF))
                return new Font(f, Font.PLAIN, SIZE);
        throw new IllegalStateException("no SF Pro, no Helvetica Neue");
    }
}
