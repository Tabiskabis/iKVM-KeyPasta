package keypasta;

import java.security.AccessController;
import java.security.PrivilegedAction;

/**
 * Runs code with the agent's own permissions (all, loaded by the bootstrap class loader, see
 * Agent), whatever called it: under Java Web Start's security manager the caller may be code
 * with fewer.
 */
final class Privileged {
    private Privileged() {
    }

    static void run(final Runnable r) {
        AccessController.doPrivileged(new PrivilegedAction<Void>() {
            @Override
            public Void run() {
                r.run();
                return null;
            }
        });
    }
}
