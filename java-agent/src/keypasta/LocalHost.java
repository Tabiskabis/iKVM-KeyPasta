package keypasta;

import java.net.InetAddress;

/**
 * IPMIView asks for the computer's own address (InetAddress.getLocalHost) every time it opens a
 * connection to a BMC and, in its session, for every packet it sends. That resolves the computer's
 * own name each time (Java keeps the answer 5 seconds and holds a lock while it asks), which returns
 * all addresses of all its network adapters: on Windows with many adapters or VPN addresses it was
 * slow, and IPMIView's status check of its whole BMC list (one thread per BMC, every 20 seconds,
 * DeviceStatus) queued up behind it, the login with it (the first login after the start took long,
 * longer the more addresses the computer has).
 *
 * In the classes redirected here (Patch.redirectLocalHost, Agent.LOCAL_HOST_USERS) the address is
 * only ever used as (a) the address of an empty DatagramPacket that a receive() fills, which
 * overwrites the address with the sender's, and (b) in com.supermicro.ipmi.UDPSocket.stopListen,
 * the target of a 1-byte packet to its own port that wakes its waiting receive() (the socket is
 * bound to all addresses, never connected; its constructor already falls back to 127.0.0.1). The
 * loopback address does both, with no lookup, and never goes stale when an adapter goes away.
 * Not redirected, as they really need the network address: SOL20 and TCR (send its bytes to the
 * BMC, where to send console data), IPMITASCommand (the adapter's MAC as a key), FTPConnection.
 */
public final class LocalHost {
    private static volatile boolean logged;

    private LocalHost() {
    }

    public static InetAddress getLocalHost() {
        if (!logged) {
            logged = true;
            Log.d("own address: loopback for IPMIView's BMC connections (no host name lookup)");
        }
        return InetAddress.getLoopbackAddress();
    }
}
