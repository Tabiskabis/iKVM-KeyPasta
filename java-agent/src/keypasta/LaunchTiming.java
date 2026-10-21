package keypasta;

import java.io.IOException;
import java.net.BindException;
import java.net.InetAddress;
import java.net.ServerSocket;

/**
 * IPMIView's "Launch KVM Console" (IPMIView20.iKVMLunchar, com.supermicro.ipmi.stunnel.StunnelUtility):
 * timed in the log, step by step, and its fixed 4 s wait after starting stunnel shortened.
 *
 * The steps: IPMI questions to the BMC (tunnel support, version, ports), stunnel set up and
 * started, for tunnel version 5 a test login by a separate Java program (iKVM_precheck.jar), then
 * the viewer (iKVM.jar / iKVM_ssl.jar), a new Java process. StunnelUtility.startStunnel sleeps
 * 4 s after starting stunnel, however fast stunnel listens: here it waits until stunnel's local
 * port is taken (a bind to the same address and port fails), checked every 50 ms, at most the
 * 4 s. The loop after it (configAndStartStunnel: restart stunnel until the port is used) then
 * finds it ready. Patch.redirectLaunch sends the calls here:
 * - iKVMLunchar: StunnelUtility.checkOS (its first call: the start), Runtime.exec (the viewer);
 * - StunnelUtility: StunnelParameters.setStunnelIP and getRandomConnectPort (the local address
 *   and port stunnel will listen on), Thread.sleep, Runtime.exec (stunnel, iKVM_precheck.jar).
 * - StunnelUtility.isPortUsed: whether stunnel's port is taken, checked on stunnel's own address.
 *   IPMIView binds the port on all addresses, which macOS allows next to stunnel's on 127.0.0.1:
 *   "not used", so its loop started stunnel again every 500 ms until its 4 s were up (logs: 10
 *   more stunnels, the viewer 4.7 s later).
 * Logged: times and which program starts (its first file name only: the viewer's command line
 * has the user name and password).
 */
public final class LaunchTiming {
    private static volatile long start;
    private static volatile String listenIp;
    private static volatile int listenPort;

    private LaunchTiming() {
    }

    private static String since() {
        return start == 0 ? "" : " (+" + (System.currentTimeMillis() - start) + " ms)";
    }

    /** iKVMLunchar's StunnelUtility.checkOS(): the launch starts. */
    public static String checkOS() {
        start = System.currentTimeMillis();
        listenPort = 0;
        Log.d("KVM launch: start, asking the BMC about its tunnel (IPMI)");
        return System.getProperty("os.name") + ":" + System.getProperty("os.arch");
    }

    /** StunnelUtility's StunnelParameters.setStunnelIP: the local address stunnel listens on. */
    public static void setStunnelIP(Object parameters, String ip) throws Exception {
        listenIp = ip;
        parameters.getClass().getMethod("setStunnelIP", String.class).invoke(parameters, ip);
    }

    /** StunnelUtility.getRandomConnectPort(), its own code: a free port 50000-65535, else 49999. */
    public static int getRandomConnectPort() {
        long t0 = System.currentTimeMillis();
        int port = (int) (Math.random() * 15536.0 + 50000.0);
        while (used(port)) {
            port = (int) (Math.random() * 15536.0 + 50000.0);
            if ((System.currentTimeMillis() - t0) / 1000L > 5L) {
                port = 49999;
                break;
            }
        }
        listenPort = port;
        Log.d("KVM launch: BMC answered, setting up the tunnel" + since());
        return port;
    }

    /** Like StunnelUtility.isPortUsed (a TCP and a UDP bind on all addresses). */
    private static boolean used(int port) {
        try {
            new ServerSocket(port).close();
            new java.net.DatagramSocket(port).close();
            return false;
        } catch (IOException e) {
            return true;
        }
    }

    /** StunnelUtility's Thread.sleep: the 4 s after starting stunnel until its port is taken. */
    public static void sleep(long ms) throws InterruptedException {
        int port = listenPort;
        if (ms != 4000L || port <= 0 || port == 49999) {
            Thread.sleep(ms);
            return;
        }
        long t0 = System.currentTimeMillis();
        while (System.currentTimeMillis() - t0 < ms) {
            Boolean listening = listening(port);
            if (listening == null) {                    // can't tell: the rest of the 4 s
                Thread.sleep(Math.max(0L, ms - (System.currentTimeMillis() - t0)));
                Log.d("KVM launch: stunnel started, waited the full 4 s (its port can't be checked)" + since());
                return;
            }
            if (listening) {
                Log.d("KVM launch: stunnel ready after " + (System.currentTimeMillis() - t0) + " ms instead of a fixed 4 s" + since());
                return;
            }
            Thread.sleep(50L);
        }
        Log.d("KVM launch: stunnel not listening after 4 s" + since());
    }

    /** StunnelUtility.isPortUsed: on stunnel's address (see above); can't tell: IPMIView's check. */
    public static boolean isPortUsed(int port) {
        Boolean taken = listening(port);
        if (taken != null)
            return taken;
        try {
            new ServerSocket(port).close();
            return false;
        } catch (IOException e) {
            return true;
        }
    }

    /** Whether stunnel listens on its address and port: true, false, null (can't tell). */
    private static Boolean listening(int port) {
        try {
            InetAddress address = listenIp == null ? InetAddress.getLoopbackAddress() : InetAddress.getByName(listenIp);
            new ServerSocket(port, 1, address).close();
            return Boolean.FALSE;
        } catch (BindException e) {
            return Boolean.TRUE;                        // taken: stunnel's
        } catch (Exception e) {
            return null;
        }
    }

    /** Runtime.exec(String) in iKVMLunchar and StunnelUtility: which program, when. */
    public static Process exec(Runtime runtime, String command) throws IOException {
        Log.d("KVM launch: starting " + program(command) + since());
        String settings = command.contains("--FR") ? KvmSettings.takePending() : null;
        if (settings != null)
            return KvmSettings.execWithSettings(runtime, command, settings);
        return runtime.exec(command);
    }

    /** The jar (after -jar) or the program's file name; never the arguments. */
    static String program(String command) {
        String[] parts = command.trim().split("\\s+");
        for (int i = 0; i + 1 < parts.length; i++)
            if (parts[i].equals("-jar"))
                return parts[i + 1];
        String first = parts.length == 0 ? "" : parts[0];
        return first.substring(Math.max(first.lastIndexOf('/'), first.lastIndexOf('\\')) + 1);
    }
}
