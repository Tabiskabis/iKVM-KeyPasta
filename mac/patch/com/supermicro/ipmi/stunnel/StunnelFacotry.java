package com.supermicro.ipmi.stunnel;

import java.io.File;

/**
 * iKVM-KeyPasta (mac/): stand-in for IPMIView's own StunnelFacotry (sic), put before
 * IPMIView20.jar on the class path by ipmiview-keypasta.sh. The same as IPMIView 2.25's, except
 * that macOS gets IPMIView's own, unused MACStunnel (stunnel and stunnel.conf from
 * BMCSecurity/mac/) instead of the exception "The function can't support on mac".
 */
public class StunnelFacotry {
    public static final String WINDOWS_DIRECTORY = "win";
    public static final String LINUX_DIRECTORY = "linux";
    public static final String MAC_DIRECTORY = "mac";
    public static final String STUNNEL4_56_DIRECTORY = "stunnel4.56";
    public static final String STUNNEL4_56_LINUX_DIRECTORY = STUNNEL4_56_DIRECTORY + File.separator + LINUX_DIRECTORY;

    /** os: StunnelUtility.checkOS(), os.name:os.arch, e.g. "Mac OS X:x86_64". */
    public static BaseStunnel createStunnel(String os, int caMode) throws Exception {
        if (os.indexOf("Windows") > -1)
            return new WindowsStunnel(WINDOWS_DIRECTORY, caMode);
        if (os.toLowerCase().indexOf("mac") > -1)
            return new MACStunnel(MAC_DIRECTORY, caMode);
        if (os.indexOf("64") > -1)
            return new Linux64Stunnel(LINUX_DIRECTORY, caMode);
        return new Linux32Stunnel(LINUX_DIRECTORY, caMode);
    }
}
