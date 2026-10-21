package com.supermicro.ipmi.stunnel;

import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;

/**
 * iKVM-KeyPasta, macOS (see keypasta.MacStunnel): IPMIView's StunnelUtility calls this instead of
 * StunnelFacotry.createStunnel. Not one of the agent's own classes: the agent defines it in
 * IPMIView's class loader, from keypasta/KeyPastaStunnel.bin in the jar (built from hook/ against
 * the stand-ins in stub/), as it returns IPMIView's BaseStunnel.
 *
 * IPMIView's own createStunnel first. Only its refusal on macOS ("The function can't support on
 * mac") becomes IPMIView's own, unused MACStunnel (stunnel and stunnel.conf from BMCSecurity/mac/,
 * which ipmiview-keypasta.sh provides), made by reflection: an IPMIView with Mac support of its
 * own keeps it, one whose MACStunnel is gone or different keeps its own answer (and the log says
 * why).
 */
public final class KeyPastaStunnel {
    private KeyPastaStunnel() {
    }

    public static BaseStunnel createStunnel(String os, int caMode) throws Exception {
        try {
            return StunnelFacotry.createStunnel(os, caMode);
        } catch (Exception refused) {
            if (os == null || os.toLowerCase().indexOf("mac") < 0)
                throw refused;
            BaseStunnel s;
            try {
                Constructor<?> c = Class.forName("com.supermicro.ipmi.stunnel.MACStunnel")
                    .getDeclaredConstructor(String.class, int.class);
                s = (BaseStunnel) c.newInstance("mac", caMode);
            } catch (InvocationTargetException e) {
                Throwable t = e.getCause();
                if (t instanceof Exception)
                    throw (Exception) t;
                if (t instanceof Error)
                    throw (Error) t;
                throw e;
            } catch (ReflectiveOperationException | ClassCastException | LinkageError e) {
                keypasta.MacStunnel.note("encrypted console: IPMIView's MACStunnel not usable (" + e
                    + "), IPMIView's own answer: " + refused.getMessage());
                throw refused;
            }
            keypasta.MacStunnel.note("encrypted console: IPMIView's MACStunnel instead of \""
                + refused.getMessage() + "\"");
            return s;
        }
    }
}
