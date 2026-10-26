package keypasta;

import java.io.File;

/**
 * IPMIView's note after File > Save ("The configuration file has been save to" and the path of
 * IPMIView.properties) and Help > Configuration tip show the folder IPMIView keeps its settings
 * in, made with new File(".").getAbsolutePath().replaceAll("\\.", ""): meant to take off the
 * trailing ".", it takes out every dot of the path (~/.config/ipmiview showed as
 * ~/config/ipmiview, IPMIView_2.25.0_build.260812 as IPMIView_2250_build260812). IPMIView20's
 * String.replaceAll calls land here (Patch.redirectConfigNote): that one takes off only the
 * trailing "."; any other is done as asked. The note's "has been save to" becomes "has been saved
 * to" (Patch.replaceString). All systems.
 */
public final class ConfigNote {
    private ConfigNote() {
    }

    public static String replaceAll(String s, String regex, String replacement) {
        if ("\\.".equals(regex) && "".equals(replacement) && s.endsWith(File.separator + "."))
            return s.substring(0, s.length() - 1);
        return s.replaceAll(regex, replacement);
    }
}
