package keypasta;

/**
 * Rewrites the viewer's bytecode so the window never forces itself on top: ATEN calls
 * {@code parent.setAlwaysOnTop(true)} on every (re)connect (RemoteVideo.connectionRetry), which
 * buries the virtual-media and options dialogs. This flips the constant pushed before each
 * {@code setAlwaysOnTop(Z)} call in the class from 1 (true) to 0 (false), at load time.
 *
 * Pure byte manipulation, no bytecode library: it finds the constant-pool method references named
 * "setAlwaysOnTop", then walks each method's Code instruction by instruction and, where an
 * {@code iconst_1} is immediately followed by an {@code invokevirtual} of one of those references,
 * changes the {@code iconst_1} to {@code iconst_0}. Any parsing surprise returns the class
 * unchanged (the agent's runtime veto then still applies).
 */
final class Patch {
    private static final int ICONST_0 = 0x03, ICONST_1 = 0x04, INVOKEVIRTUAL = 0xB6;

    private Patch() {
    }

    /** @return the patched class bytes, or null if nothing was changed / parsing failed. */
    static byte[] noAlwaysOnTop(byte[] cf) {
        try {
            return run(cf.clone());
        } catch (Throwable t) {
            Log.d("always-on-top patch skipped: " + t);
            return null;
        }
    }

    private static byte[] run(byte[] b) {
        int p = 8;                                  // magic(4) + minor(2) + major(2)
        int cpCount = u2(b, p); p += 2;
        // constant pool: record Utf8 strings, NameAndType name indexes, and method-ref NaT indexes.
        String[] utf8 = new String[cpCount];
        int[] natName = new int[cpCount];           // NameAndType -> name_index
        int[] refNat = new int[cpCount];            // Methodref/InterfaceMethodref -> NameAndType index
        for (int i = 1; i < cpCount; i++) {
            int tag = b[p++] & 0xFF;
            switch (tag) {
                case 1: { int len = u2(b, p); p += 2; utf8[i] = new String(b, p, len, java.nio.charset.StandardCharsets.UTF_8); p += len; break; }
                case 7: case 8: case 16: case 19: case 20: p += 2; break;
                case 15: p += 3; break;
                case 3: case 4: case 9: case 11: case 18: case 17: p += 4; break;
                case 10: refNat[i] = u2(b, p + 2); p += 4; break;      // Methodref
                case 12: natName[i] = u2(b, p); p += 4; break;         // NameAndType
                case 5: case 6: p += 8; i++; break;                   // Long/Double take two slots
                default: return null;                                 // unknown tag: give up
            }
        }
        // which method-ref indexes name "setAlwaysOnTop"?
        boolean[] target = new boolean[cpCount];
        boolean any = false;
        for (int i = 1; i < cpCount; i++) {
            if (refNat[i] != 0) {
                int nat = refNat[i];
                if (nat > 0 && nat < cpCount && natName[nat] > 0 && "setAlwaysOnTop".equals(utf8[natName[nat]])) {
                    target[i] = true; any = true;
                }
            }
        }
        if (!any) return null;

        p += 6;                                      // access_flags(2) + this_class(2) + super_class(2)
        int ifaces = u2(b, p); p += 2 + ifaces * 2;
        p = skipMembers(b, p);                       // fields
        int methods = u2(b, p); p += 2;
        boolean changed = false;
        for (int m = 0; m < methods; m++) {
            p += 6;                                  // access(2) + name(2) + descriptor(2)
            int attrs = u2(b, p); p += 2;
            for (int a = 0; a < attrs; a++) {
                int nameIdx = u2(b, p); int len = u4(b, p + 2); int body = p + 6;
                if ("Code".equals(utf8[nameIdx])) {
                    int codeLen = u4(b, body + 4);   // max_stack(2)+max_locals(2) then code_length(4)
                    int code = body + 8;
                    changed |= patchCode(b, code, codeLen, target);
                }
                p = body + len;
            }
        }
        return changed ? b : null;
    }

    /** Walk instructions; flip iconst_1 to iconst_0 when immediately before a target invokevirtual. */
    private static boolean patchCode(byte[] b, int start, int len, boolean[] target) {
        boolean changed = false;
        int prevIconst1 = -1;
        int i = start, end = start + len;
        while (i < end) {
            int op = b[i] & 0xFF;
            if (op == INVOKEVIRTUAL && prevIconst1 == i - 1) {
                int ref = u2(b, i + 1);
                if (ref > 0 && ref < target.length && target[ref]) {
                    b[prevIconst1] = (byte) ICONST_0;
                    changed = true;
                }
            }
            prevIconst1 = (op == ICONST_1) ? i : -1;
            i += insnLen(b, i, start);
        }
        return changed;
    }

    private static int insnLen(byte[] b, int pc, int codeStart) {
        int op = b[pc] & 0xFF;
        switch (op) {
            case 0x10: case 0x12: case 0x15: case 0x16: case 0x17: case 0x18: case 0x19:
            case 0x36: case 0x37: case 0x38: case 0x39: case 0x3A: case 0xA9: case 0xBC:
                return 2;
            case 0x11: case 0x13: case 0x14: case 0x84: case 0x99: case 0x9A: case 0x9B:
            case 0x9C: case 0x9D: case 0x9E: case 0x9F: case 0xA0: case 0xA1: case 0xA2:
            case 0xA3: case 0xA4: case 0xA5: case 0xA6: case 0xA7: case 0xA8: case 0xB2:
            case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7: case 0xB8: case 0xBB:
            case 0xBD: case 0xC0: case 0xC1: case 0xC6: case 0xC7:
                return 3;
            case 0xC5: return 4;
            case 0xB9: case 0xBA: case 0xC8: case 0xC9: return 5;
            case 0xC4:    // wide
                return (b[pc + 1] & 0xFF) == 0x84 ? 6 : 4;
            case 0xAA: {  // tableswitch (operands aligned to 4 bytes from the code start)
                int base = codeStart + (((pc - codeStart) + 4) & ~3);
                int low = u4(b, base + 4), high = u4(b, base + 8);
                return (base - pc) + 12 + (high - low + 1) * 4;
            }
            case 0xAB: {  // lookupswitch
                int base = codeStart + (((pc - codeStart) + 4) & ~3);
                int npairs = u4(b, base + 4);
                return (base - pc) + 8 + npairs * 8;
            }
            default:
                return 1;
        }
    }

    /** Native methods of the viewer redirected by redirectNatives, all in keypasta.Native. */
    private static final String[][] NATIVES = {
        {null, "keyboardAction", "(IIIIIII)V"}, {null, "changeLEDstate", "(IIIIIII)V"},
        {null, "getLEDstate", "()I"}, {null, "setLEDstate", "()V"},
    };

    /**
     * macOS: every call of the viewer's own native keyboard and LED methods (keyboardAction,
     * getLEDstate, setLEDstate, changeLEDstate) becomes a call of the static method of the same
     * name in keypasta.Native, the viewer object as first argument: invokevirtual/invokespecial
     * #ref -> invokestatic #hook, 3 bytes each, so no offset in the code changes. The new constant
     * pool entries go at its end. Native decides, and calls the original through reflection.
     * Any parsing surprise returns the class unchanged.
     *
     * @return the patched class bytes, or null if nothing was changed / parsing failed.
     */
    static byte[] redirectNatives(byte[] cf) {
        try {
            return redirect(cf.clone(), NATIVES, "keypasta/Native", "native keyboard/LED calls");
        } catch (Throwable t) {
            Log.d("native redirect skipped: " + t);
            return null;
        }
    }

    /** The viewer's native mouseAction calls become keypasta.MouseRate.mouseAction(this, ...) (see MouseRate). */
    static byte[] redirectMouse(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{null, "mouseAction", "(IIII)V"}}, "keypasta/MouseRate", "mouse moves");
        } catch (Throwable t) {
            Log.d("mouse redirect skipped: " + t);
            return null;
        }
    }

    /** macOS, Linux: IPMIView's setDefaultFont() becomes keypasta.Fonts.setDefaultFont(this) (see Fonts). */
    static byte[] redirectFonts(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{null, "setDefaultFont", "()V"}}, "keypasta/Fonts", "IPMIView font");
        } catch (Throwable t) {
            Log.d("font redirect skipped: " + t);
            return null;
        }
    }

    /** IPMIView's JOptionPane.showConfirmDialog and showMessageDialog calls become keypasta.Quit's (see Quit). */
    static byte[] redirectQuit(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"javax/swing/JOptionPane", "showConfirmDialog",
                "(Ljava/awt/Component;Ljava/lang/Object;Ljava/lang/String;I)I", "static"},
                {"javax/swing/JOptionPane", "showMessageDialog", "(Ljava/awt/Component;Ljava/lang/Object;)V", "static"}},
                "keypasta/Quit", "IPMIView quit question");
        } catch (Throwable t) {
            Log.d("quit question redirect skipped: " + t);
            return null;
        }
    }

    /** IPMIView's KVM launch: timed, its 4 s wait for stunnel shortened (see LaunchTiming). */
    static byte[] redirectLaunch(byte[] cf, String name) {
        String[][] targets = "IPMIView20/iKVMLunchar".equals(name)
            ? new String[][] {
                {"com/supermicro/ipmi/stunnel/StunnelUtility", "checkOS", "()Ljava/lang/String;", "static"},
                {"java/lang/Runtime", "exec", "(Ljava/lang/String;)Ljava/lang/Process;"}}
            : new String[][] {
                {"com/supermicro/ipmi/stunnel/StunnelParameters", "setStunnelIP", "(Ljava/lang/String;)V", "object"},
                {null, "getRandomConnectPort", "()I", "static"},
                {null, "isPortUsed", "(I)Z", "static"},
                {"java/lang/Thread", "sleep", "(J)V", "static"},
                {"java/lang/Runtime", "exec", "(Ljava/lang/String;)Ljava/lang/Process;"}};
        try {
            return redirect(cf.clone(), targets, "keypasta/LaunchTiming", "KVM launch timing");
        } catch (Throwable t) {
            Log.d("KVM launch timing skipped: " + t);
            return null;
        }
    }

    /** macOS: StunnelUtility's StunnelFacotry.createStunnel becomes KeyPastaStunnel's (see MacStunnel). */
    static byte[] redirectStunnel(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"com/supermicro/ipmi/stunnel/StunnelFacotry", "createStunnel",
                "(Ljava/lang/String;I)Lcom/supermicro/ipmi/stunnel/BaseStunnel;", "static"}},
                "com/supermicro/ipmi/stunnel/KeyPastaStunnel", "macOS encrypted console");
        } catch (Throwable t) {
            Log.d("macOS encrypted console redirect skipped: " + t);
            return null;
        }
    }

    /** Linux, Wayland/WSL: the viewer's setResizable calls become WaylandFrames.setResizable. */
    static byte[] redirectResizable(byte[] cf) {
        String[] owners = {null, "tw/com/aten/ikvm/ui/Viewer", "javax/swing/JFrame", "javax/swing/JDialog",
            "java/awt/Frame", "java/awt/Dialog"};
        String[][] targets = new String[owners.length][];
        for (int i = 0; i < owners.length; i++)
            targets[i] = new String[] {owners[i], "setResizable", "(Z)V", "object"};
        try {
            return redirect(cf.clone(), targets, "keypasta/WaylandFrames", "fixed window sizes");
        } catch (Throwable t) {
            Log.d("fixed window size redirect skipped: " + t);
            return null;
        }
    }

    /** The viewer's KVMMain: its Thread.sleep calls become ViewerStart.sleep (see ViewerStart). */
    static byte[] redirectViewerStart(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"java/lang/Thread", "sleep", "(J)V", "static"}},
                "keypasta/ViewerStart", "viewer start pause");
        } catch (Throwable t) {
            Log.d("viewer start pause redirect skipped: " + t);
            return null;
        }
    }

    /**
     * Every reference to the class from (its Class constant: new, method owners, stack map types)
     * becomes to (a subclass of it with the same constructor). Null: no such reference.
     */
    static byte[] renameClass(byte[] b, String from, String to) {
        try {
            int cpCount = u2(b, 8);
            int p = 10;
            String[] utf8 = new String[cpCount];
            int[] tag = new int[cpCount], classAt = new int[cpCount];
            for (int i = 1; i < cpCount; i++) {
                int t = b[p++] & 0xFF;
                tag[i] = t;
                switch (t) {
                    case 1: { int len = u2(b, p); utf8[i] = new String(b, p + 2, len, "UTF-8"); p += 2 + len; break; }
                    case 7: classAt[i] = p; p += 2; break;
                    case 8: case 16: case 19: case 20: p += 2; break;
                    case 15: p += 3; break;
                    case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18: p += 4; break;
                    case 5: case 6: p += 8; i++; break;
                    default: return null;
                }
            }
            int cpEnd = p;
            int added = cpCount;                            // the new name's index
            int changed = 0;
            for (int i = 1; i < cpCount; i++)
                if (tag[i] == 7 && from.equals(utf8[u2(b, classAt[i])])) {
                    b[classAt[i]] = (byte) (added >> 8);
                    b[classAt[i] + 1] = (byte) added;
                    changed++;
                }
            if (changed == 0)
                return null;
            java.io.ByteArrayOutputStream extra = new java.io.ByteArrayOutputStream();
            java.io.DataOutputStream out = new java.io.DataOutputStream(extra);
            out.writeByte(1);
            out.writeUTF(to);
            out.flush();
            byte[] add = extra.toByteArray();
            byte[] r = new byte[b.length + add.length];
            System.arraycopy(b, 0, r, 0, cpEnd);
            r[8] = (byte) ((cpCount + 1) >> 8);
            r[9] = (byte) (cpCount + 1);
            System.arraycopy(add, 0, r, cpEnd, add.length);
            System.arraycopy(b, cpEnd, r, cpEnd + add.length, b.length - cpEnd);
            Log.d(from + " is " + to + " in " + utf8[u2(b, classAt[u2(b, cpEnd + 2)])]);
            return r;
        } catch (Exception e) {
            Log.d("class rename skipped: " + e);
            return null;
        }
    }

    /**
     * Every String constant (what ldc pushes) equal to from becomes to, a Utf8 entry added for it.
     * Null: no such constant.
     */
    static byte[] replaceString(byte[] b, String from, String to) {
        try {
            int cpCount = u2(b, 8);
            int p = 10;
            String[] utf8 = new String[cpCount];
            int[] tag = new int[cpCount], at = new int[cpCount];
            for (int i = 1; i < cpCount; i++) {
                int t = b[p++] & 0xFF;
                tag[i] = t;
                switch (t) {
                    case 1: { int len = u2(b, p); utf8[i] = new String(b, p + 2, len, "UTF-8"); p += 2 + len; break; }
                    case 7: case 8: at[i] = p; p += 2; break;
                    case 16: case 19: case 20: p += 2; break;
                    case 15: p += 3; break;
                    case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18: p += 4; break;
                    case 5: case 6: p += 8; i++; break;
                    default: return null;
                }
            }
            int cpEnd = p;
            int added = cpCount;                            // the new text's index
            int changed = 0;
            for (int i = 1; i < cpCount; i++)
                if (tag[i] == 8 && from.equals(utf8[u2(b, at[i])])) {
                    b[at[i]] = (byte) (added >> 8);
                    b[at[i] + 1] = (byte) added;
                    changed++;
                }
            if (changed == 0)
                return null;
            java.io.ByteArrayOutputStream extra = new java.io.ByteArrayOutputStream();
            java.io.DataOutputStream out = new java.io.DataOutputStream(extra);
            out.writeByte(1);
            out.writeUTF(to);
            out.flush();
            byte[] add = extra.toByteArray();
            byte[] r = new byte[b.length + add.length];
            System.arraycopy(b, 0, r, 0, cpEnd);
            r[8] = (byte) ((cpCount + 1) >> 8);
            r[9] = (byte) (cpCount + 1);
            System.arraycopy(add, 0, r, cpEnd, add.length);
            System.arraycopy(b, cpEnd, r, cpEnd + add.length, b.length - cpEnd);
            Log.d("text \"" + from.trim() + "\" corrected in " + utf8[u2(b, at[u2(b, cpEnd + 2)])]);
            return r;
        } catch (Exception e) {
            Log.d("text correction skipped: " + e);
            return null;
        }
    }

    /**
     * IPMIView20's String.replaceAll calls become ConfigNote.replaceAll, and its note's "has been
     * save to" becomes "has been saved to" (see ConfigNote).
     */
    static byte[] redirectConfigNote(byte[] cf) {
        byte[] out = null;
        try {
            out = redirect(cf.clone(), new String[][] {{"java/lang/String", "replaceAll",
                "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"}}, "keypasta/ConfigNote", "settings folder in notes");
        } catch (Throwable t) {
            Log.d("settings folder in notes redirect skipped: " + t);
        }
        byte[] text = replaceString(out != null ? out : cf.clone(), " The configuration file has been save to",
            " The configuration file has been saved to");
        return text != null ? text : out;
    }

    /**
     * IPMIView's settings files opened by name go to its settings folder (see SettingsFolder):
     * ConfigAccessor's File and FileReader, the others' FileReader and FileWriter become
     * SettingsFolder's, their File.exists/isFile/createNewFile calls SettingsFolder's.
     */
    static byte[] redirectSettingsFolder(byte[] cf, String name) {
        byte[] out = cf;
        boolean changed = false;
        String[][] renames = "IPMIView20/ConfigAccessor".equals(name)
            ? new String[][] {{"java/io/File", "keypasta/SettingsFolder$Folder"}, {"java/io/FileReader", "keypasta/SettingsFolder$Reader"}}
            : new String[][] {{"java/io/FileReader", "keypasta/SettingsFolder$Reader"}, {"java/io/FileWriter", "keypasta/SettingsFolder$Writer"}};
        for (String[] r : renames) {
            byte[] renamed = renameClass(out == cf ? cf.clone() : out, r[0], r[1]);
            if (renamed != null) {
                out = renamed;
                changed = true;
            }
        }
        if (!"IPMIView20/ConfigAccessor".equals(name)) {
            try {
                byte[] redirected = redirect(out == cf ? cf.clone() : out, new String[][] {{"java/io/File", "exists", "()Z"},
                    {"java/io/File", "isFile", "()Z"}, {"java/io/File", "createNewFile", "()Z"}},
                    "keypasta/SettingsFolder", "settings file checks");
                if (redirected != null) {
                    out = redirected;
                    changed = true;
                }
            } catch (Throwable t) {
                Log.d("settings file check redirect skipped: " + t);
            }
        }
        return changed ? out : null;
    }

    /** IPMIView's UDP classes: InetAddress.getLocalHost becomes LocalHost.getLocalHost (see LocalHost). */
    static byte[] redirectLocalHost(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"java/net/InetAddress", "getLocalHost", "()Ljava/net/InetAddress;", "static"}},
                "keypasta/LocalHost", "own address lookup");
        } catch (Throwable t) {
            Log.d("own address lookup redirect skipped: " + t);
            return null;
        }
    }

    /** IPMIView20's DeviceFile.deleteDevice calls become IPMIViewLogin.deleteDevice (see IPMIViewLogin). */
    static byte[] redirectDeviceDelete(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"IPMIView20/DeviceFile", "deleteDevice",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V", "object"}}, "keypasta/IPMIViewLogin", "device removal");
        } catch (Throwable t) {
            Log.d("device removal redirect skipped: " + t);
            return null;
        }
    }

    /** The device editor's DeviceFile.modifyDevice call becomes IPMIViewLogin.modifyDevice (its saved account follows a rename). */
    static byte[] redirectDeviceModify(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"IPMIView20/DeviceFile", "modifyDevice",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V", "object"}},
                "keypasta/IPMIViewLogin", "device rename");
        } catch (Throwable t) {
            Log.d("device rename redirect skipped: " + t);
            return null;
        }
    }

    /** IPMISession's ComboTab.resetDefaultTab calls become IPMIViewLogin.resetDefaultTab (see IPMIViewLogin). */
    static byte[] redirectSensorsTab(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"IPMIView20/ComboTab", "resetDefaultTab", "()V", "object"}},
                "keypasta/IPMIViewLogin", "sensors tab default");
        } catch (Throwable t) {
            Log.d("sensors tab redirect skipped: " + t);
            return null;
        }
    }

    /** The viewer's KVMMain: File.exists and File.delete become KvmSettings's (see KvmSettings). */
    static byte[] redirectKvmSettings(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"java/io/File", "exists", "()Z"}, {"java/io/File", "delete", "()Z"}},
                "keypasta/KvmSettings", "settings file checks");
        } catch (Throwable t) {
            Log.d("settings file check redirect skipped: " + t);
            return null;
        }
    }

    /** Ways of starting a program, redirected by redirectSpawn, all in keypasta.Spawn. */
    private static final String[][] SPAWNS = {
        {"java/lang/Runtime", "exec", "(Ljava/lang/String;)Ljava/lang/Process;"},
        {"java/lang/Runtime", "exec", "(Ljava/lang/String;[Ljava/lang/String;)Ljava/lang/Process;"},
        {"java/lang/Runtime", "exec", "(Ljava/lang/String;[Ljava/lang/String;Ljava/io/File;)Ljava/lang/Process;"},
        {"java/lang/Runtime", "exec", "([Ljava/lang/String;)Ljava/lang/Process;"},
        {"java/lang/Runtime", "exec", "([Ljava/lang/String;[Ljava/lang/String;)Ljava/lang/Process;"},
        {"java/lang/Runtime", "exec", "([Ljava/lang/String;[Ljava/lang/String;Ljava/io/File;)Ljava/lang/Process;"},
        {"java/lang/ProcessBuilder", "start", "()Ljava/lang/Process;"},
    };

    /**
     * macOS: the viewer's Runtime.exec and ProcessBuilder.start calls become calls of
     * keypasta.Spawn (same way as redirectNatives, the Runtime/ProcessBuilder as first argument),
     * which runs stunnel from a fixed place (see Spawn).
     *
     * @return the patched class bytes, or null if nothing was changed / parsing failed.
     */
    static byte[] redirectSpawn(byte[] cf) {
        try {
            return redirect(cf.clone(), SPAWNS, "keypasta/Spawn", "program starts");
        } catch (Throwable t) {
            Log.d("program start redirect skipped: " + t);
            return null;
        }
    }

    /**
     * The viewer's keys by its own "Keyboard layout" setting (RemoteVideo.processKeyEvent: German
     * swaps Y/Z, French moves A, Q, W, Z, M, ...) become keypasta.ViewerLayout.getKbLayout, which
     * says US while the keyboard fixes are on: they give every key the US key code of its
     * position already. All systems.
     */
    static byte[] redirectKbLayout(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"tw/com/aten/ikvm/bean/OptionInfo", "getKbLayout",
                "()Ljava/util/Locale;", "object"}}, "keypasta/ViewerLayout", "viewer keyboard layout setting");
        } catch (Throwable t) {
            Log.d("keyboard layout redirect skipped: " + t);
            return null;
        }
    }

    /**
     * The viewer's InputContext.selectInputMethod calls (Viewer.getInputContext, the virtual
     * keyboard's language) become keypasta.InputSwitch.selectInputMethod, which leaves them out
     * while the keyboard fixes are on (see there). All systems.
     */
    static byte[] redirectInputSwitch(byte[] cf) {
        try {
            return redirect(cf.clone(), new String[][] {{"java/awt/im/InputContext", "selectInputMethod",
                "(Ljava/util/Locale;)Z"}, {"java/awt/im/InputContext", "getInstance", "()Ljava/awt/im/InputContext;",
                "static"}}, "keypasta/InputSwitch", "input method switches");
        } catch (Throwable t) {
            Log.d("input method switch redirect skipped: " + t);
            return null;
        }
    }

    /**
     * macOS: the physical key of key events (see MacKeys). In CPlatformResponder the key info
     * conversions, in LWWindowPeer the KeyEvent's extended key code (an interface call, its 2
     * extra bytes become nops). Only after MacKeys.prepare succeeded.
     */
    static byte[] redirectMacKeys(byte[] cf, String name) {
        try {
            String[][] targets = name.equals("sun/lwawt/macosx/CPlatformResponder")
                ? new String[][] {{"sun/lwawt/macosx/NSEvent", "nsToJavaKeyInfo", "([I[I)Z", "static"},
                    {"sun/lwawt/macosx/NSEvent", "nsKeyModifiersToJavaKeyInfo", "([I[I)V", "static"}}
                : new String[][] {{"sun/awt/AWTAccessor$KeyEventAccessor", "setExtendedKeyCode",
                    "(Ljava/awt/event/KeyEvent;J)V", "object"}};
            return redirect(cf.clone(), targets, "keypasta/MacKeys", "macOS physical keys");
        } catch (Throwable t) {
            Log.d("macOS physical keys redirect skipped: " + t);
            return null;
        }
    }

    /**
     * targets: {owner (null: the class itself, receiver passed as Object), name, descriptor[,
     * "object": receiver passed as Object, for an owner the agent can't name; "static": a static
     * method, invokestatic, the hook has the same descriptor]};
     * the hook has the same name, the receiver as first argument.
     */
    private static byte[] redirect(byte[] b, String[][] targets, String hooks, String what) throws Exception {
        int cpCount = u2(b, 8);
        int p = 10;
        String[] utf8 = new String[cpCount];
        int[] tag = new int[cpCount], a = new int[cpCount], c = new int[cpCount];
        for (int i = 1; i < cpCount; i++) {
            int t = b[p++] & 0xFF;
            tag[i] = t;
            switch (t) {
                case 1: { int len = u2(b, p); utf8[i] = new String(b, p + 2, len, "UTF-8"); p += 2 + len; break; }
                case 7: case 8: case 16: case 19: case 20: a[i] = u2(b, p); p += 2; break;
                case 15: p += 3; break;
                case 3: case 4: case 17: case 18: p += 4; break;
                case 9: case 10: case 11: case 12: a[i] = u2(b, p); c[i] = u2(b, p + 2); p += 4; break;
                case 5: case 6: p += 8; i++; break;
                default: return null;
            }
        }
        int cpEnd = p;
        String self = utf8[a[u2(b, cpEnd + 2)]];            // this_class -> Class -> name
        java.io.ByteArrayOutputStream extra = new java.io.ByteArrayOutputStream();
        java.io.DataOutputStream out = new java.io.DataOutputStream(extra);
        int next = cpCount;
        int hookClassName = next++;
        out.writeByte(1); out.writeUTF(hooks);
        int hookClass = next++;
        out.writeByte(7); out.writeShort(hookClassName);
        int[] newRef = new int[cpCount];                     // old Methodref -> new hook Methodref
        boolean[] staticRef = new boolean[cpCount];          // a static method's (invokestatic)
        boolean any = false;
        for (int i = 1; i < cpCount; i++) {
            if ((tag[i] != 10 && tag[i] != 11) || tag[a[i]] != 7)
                continue;
            String owner = utf8[a[a[i]]];
            int nat = c[i];
            String name = utf8[a[nat]], desc = utf8[c[nat]];
            for (String[] n : targets) {
                if (!(n[0] == null ? self : n[0]).equals(owner) || !n[1].equals(name) || !n[2].equals(desc))
                    continue;
                int hookDesc = next++;
                boolean isStatic = n.length > 3 && "static".equals(n[3]);
                boolean asObject = n[0] == null || (n.length > 3 && "object".equals(n[3]));
                out.writeByte(1); out.writeUTF(isStatic ? desc : "(L" + (asObject ? "java/lang/Object" : n[0]) + ";" + desc.substring(1));
                staticRef[i] = isStatic;
                int hookNat = next++;
                out.writeByte(12); out.writeShort(a[nat]); out.writeShort(hookDesc);
                newRef[i] = next++;
                out.writeByte(10); out.writeShort(hookClass); out.writeShort(hookNat);
                any = true;
            }
        }
        if (!any || next > 0xFFFF)
            return null;

        // the calls, in place
        p = cpEnd + 6;
        int ifaces = u2(b, p); p += 2 + ifaces * 2;
        p = skipMembers(b, p);
        int methods = u2(b, p); p += 2;
        int changed = 0;
        for (int m = 0; m < methods; m++) {
            p += 6;
            int attrs = u2(b, p); p += 2;
            for (int k = 0; k < attrs; k++) {
                int nameIdx = u2(b, p), len = u4(b, p + 2), body = p + 6;
                if ("Code".equals(utf8[nameIdx])) {
                    int code = body + 8, end = code + u4(b, body + 4);
                    for (int i = code; i < end; i += insnLen(b, i, code)) {
                        int op = b[i] & 0xFF;
                        if (op != 0xB6 && op != 0xB7 && op != 0xB8 && op != 0xB9)
                            continue;
                        int ref = u2(b, i + 1);
                        if (ref < cpCount && newRef[ref] != 0 && (op == 0xB8) == staticRef[ref]
                                && (op == 0xB9) == (tag[ref] == 11)) {
                            b[i] = (byte) 0xB8;
                            b[i + 1] = (byte) (newRef[ref] >> 8);
                            b[i + 2] = (byte) newRef[ref];
                            if (op == 0xB9) {               // invokeinterface is 5 bytes: 2 nops after
                                b[i + 3] = 0;
                                b[i + 4] = 0;
                            }
                            changed++;
                        }
                    }
                }
                p = body + len;
            }
        }
        if (changed == 0)
            return null;
        out.flush();
        byte[] add = extra.toByteArray();
        byte[] r = new byte[b.length + add.length];
        System.arraycopy(b, 0, r, 0, cpEnd);
        r[8] = (byte) (next >> 8);
        r[9] = (byte) next;
        System.arraycopy(add, 0, r, cpEnd, add.length);
        System.arraycopy(b, cpEnd, r, cpEnd + add.length, b.length - cpEnd);
        Log.d(what + " redirected in " + self + ": " + changed);
        return r;
    }

    private static int skipMembers(byte[] b, int p) {
        int count = u2(b, p); p += 2;
        for (int i = 0; i < count; i++) {
            p += 6;                                  // access(2)+name(2)+descriptor(2)
            int attrs = u2(b, p); p += 2;
            for (int a = 0; a < attrs; a++) p = u4(b, p + 2) + p + 6;
        }
        return p;
    }

    private static int u2(byte[] b, int i) { return ((b[i] & 0xFF) << 8) | (b[i + 1] & 0xFF); }
    private static int u4(byte[] b, int i) { return (u2(b, i) << 16) | u2(b, i + 2); }
}
