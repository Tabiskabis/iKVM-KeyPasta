# iKVM-KeyPasta documentation

Everything the project does, how, and why. For what the project is, how to install and use it, see [README.md](README.md) (and [mac/README.md](mac/README.md) for the Mac app). Notes for AI agents working on the code are in [AGENTS.md](AGENTS.md).

- [1. The problem](#1-the-problem)
- [2. The parts and how they work together](#2-the-parts-and-how-they-work-together)
- [3. Keys](#3-keys)
- [4. Paste](#4-paste)
- [5. The Java agent: loading, safety, options, log](#5-the-java-agent-loading-safety-options-log)
- [6. The Java agent: fixes in the iKVM viewer](#6-the-java-agent-fixes-in-the-ikvm-viewer)
- [7. The Java agent: fixes in IPMIView](#7-the-java-agent-fixes-in-ipmiview)
- [8. The HTML5 userscript](#8-the-html5-userscript)
- [9. The login-fix userscript](#9-the-login-fix-userscript)
- [10. The AutoHotkey script](#10-the-autohotkey-script)
- [11. Windows: installer and launchers](#11-windows-installer-and-launchers)
- [12. Linux: the desktop launcher](#12-linux-the-desktop-launcher)
- [13. macOS: the app, the scripts, the container](#13-macos-the-app-the-scripts-the-container)
- [14. Logs and diagnosis](#14-logs-and-diagnosis)
- [15. Tried and dropped](#15-tried-and-dropped)

---

## 1. The problem

Supermicro BMCs (made by ATEN) offer a remote console in two forms: a Java app (from IPMIView, or as a `.jnlp` file from the BMC's web interface) and an HTML5 viewer in the browser. Both handle the keyboard by *character*, not by *key*, and assume a US keyboard on both ends.

**Java app.** It doesn't forward key positions. Java turns each local key into a Java key code via the character the key produces on the *local* layout, and the viewer looks that code up in a fixed US table. With a Swiss keyboard, some positions (`^`, `¨`, `$`, `-`) can't be reached at all, AltGr arrives with an extra Ctrl, and Y and Z are swapped.

**HTML5 viewer.** It's an old noVNC. It turns the typed character into the US key position of that character (`ast2100.js`), sends only left-hand modifiers, never AltGr, and has nothing for the ISO key (`< >` left of Y on European keyboards).

**What the project wants instead:** the remote console behaves like a keyboard plugged into the server. Every key arrives at its physical position, and the *remote's* layout decides what it types. Then any local layout works with any remote layout, dead keys and AltGr included. On top of that: paste the local clipboard into the remote by typing it, and a few things only possible from outside the viewer (Ctrl+Alt+Del, Alt+Tab).

Two rules follow from the target users (most of them with Swiss keyboards, on BMCs that have been set up long ago):

- **Never require changing the iKVM "Keyboard layout" setting.** It stays English on countless BMCs, and it's stored on the BMC.
- **Never require changing the local input layout.** Typing must work with whatever layout the user has.

## 2. The parts and how they work together

| Part | Fixes | Where |
|---|---|---|
| Java agent (`iKVM-KeyPasta-agent.jar`) | the Java viewer from inside, and IPMIView | Windows, Linux, macOS |
| Userscript (`iKVM-KeyPasta.user.js`) | the HTML5 viewer from inside | any browser with Tampermonkey or Violentmonkey |
| AutoHotkey script (`windows/iKVM-KeyPasta.ahk`) | both viewers from outside, plus what only works from outside | Windows |
| Login fix (`login-fix.user.js`) | the BMC's login page for password managers | any browser |
| Mac app and scripts (`mac/`) | run IPMIView and `.jnlp` viewers on macOS, with the agent | macOS |
| Desktop launcher (`linux/`) | IPMIView with the agent in the app menu | Linux |

The rule is to fix things at their source: inside the viewer (agent, userscript) where possible. The AutoHotkey script keeps what can only be done from outside (Ctrl+Alt+Del, Alt+Tab to the Java app, paste in other programs) and fixes both viewers itself when the agent or the userscript is missing.

**The title marker.** The agent and the userscript append ` ⌨` to the viewer's window or tab title once they're active. The AutoHotkey script reads titles: where it sees the marker, it leaves that window's keys alone (and its paste to the agent or userscript), so any combination of installed parts works without fighting over the keys. The userscript sets the marker only once the viewer's internals it needs are there (`UI.rfb._rfb_insydevnc`): a viewer it can't handle stays with the AutoHotkey fallback. The agent watches the title of every frame, not only those already titled "Java iKVM Viewer", because the `.jnlp` viewer opens with another title and sets the real one only after connecting.

## 3. Keys

### Java viewer with the agent

A `KeyEventDispatcher` sees every key event before the viewer and gives each key of the main block the US key code of its *physical position*, so iKVM's US table turns it into exactly that position. The rest is left to the remote's layout.

Where the position comes from:

- **Windows:** the scan code in Java's key event (private field, low byte).
- **Linux:** the X keycode (minus 8).
- **macOS:** macOS has the key's position (its "kVK" code), but Java drops it. The agent patches Java's macOS key handling in memory while it loads (`MacKeys`): it keeps the code in the key event (in an otherwise unused field) and takes the position from there, whatever the local layout, dead keys and Option combinations included. If that patch doesn't apply (another Java version), a fallback: macOS gives every key except letters, digits and dead keys the US key code of its position anyway; for letters, digits and dead keys the agent derives the position from the known local layout (Swiss German, Swiss French, German or US), read from the current input source (`localLayout=` overrides it), and corrected from the characters of keys like ö, ' or ß when the input source said otherwise. macOS gives the key left of 1 and the ISO key the same key code: the agent tells them apart by their character (§ ° and US \` ~ are left of 1, anything else is the ISO key), so AltGr+< works.

Other key handling, all OS unless noted:

- **AltGr's extra Ctrl** (Windows sends AltGr as Ctrl+right Alt) is held back 20 ms and dropped if right Alt follows.
- **Left Ctrl is followed by an F24 release.** In iKVM's "stable keyboard" mode a held left Ctrl is dropped when the next key goes down, but a key release sends it. F24 is never pressed, so its release has no effect on Linux or Windows remotes.
- **CapsLock per window** (Windows): each viewer window keeps the remote's CapsLock state, other programs keep theirs.
- **Lock keys on macOS:** iKVM sends a Mac lock key as a tap at press and again at release (Mac CapsLock semantics), which toggled it back. The release is dropped, and lock keys aren't kept in the list of held keys (a focus loss toggled the remote's CapsLock).
- **The keypad's Clear key is NumLock on macOS** (it sits there; Macs have none, and the remote's NumLock decides whether the keypad types digits).
- **Command is the remote's Windows key** on macOS.
- **The viewer's LED sync types lock keys on Linux** (and in the container): when the BMC reports LEDs other than the local ones (or the viewer gets the focus), iKVM's Linux library sets the local lock state by typing the lock key (XTest). That key went to the viewer, which sent it to the remote: its CapsLock toggled back, so (depending on when the remote reports its LEDs, the Linux console late) only every second CapsLock seemed to arrive. The agent notes those calls (`Native.changeLEDstate`) and drops that lock key's press and release right after, as it does Windows' own sync key.
- **Alt and Command swapped, if asked** (Options › KeyPasta Agent: a default and the BMC's own, by the host in the viewer's title; or `swapAltCmd=true`): Command is the remote's Alt (the right one its AltGr), Option its Windows key, so a Mac keyboard has Alt next to the space bar, as on a PC. What Karabiner-Elements' rule did, without Karabiner, and in the container too. Elsewhere it swaps Alt and the Windows key, which is what Command is in the container's browser view. By the key's side: Linux Java gives the Windows keys and AltGr no side, the agent takes it from the X key code (133/134, 108). Shortcuts macOS or the browser keep for themselves (Cmd+Tab, Cmd+Q, Cmd+W in a browser tab) still don't reach the remote.
- **Focus loss releases what the remote has down,** with Alt and Win/Cmd broken up by a Ctrl tap first: otherwise Alt+Tab or Cmd+Tab away leaves the remote with a lone Alt or Win (menu bar, Start menu).
- **macOS reports no key release while Cmd is held:** such keys are released when Cmd goes up.
- **Keys for another part of the viewer window** (its toolbar, a button: the focus can stay there after a dialog, e.g. Record's) go to the remote too, and the viewer gets the focus back when such a dialog closes. Text fields, combo boxes and open menus keep their keys.
- **Media and browser keys** on Windows keep no position: their extended scan codes' low byte is a letter's (Volume Up E0 30 = B).
- **iKVM's own "Keyboard layout" setting is ignored for the keys** while the keyboard fixes are on: German would swap Y/Z and minus, French A/Q, W/Z, M; "Swiss" in that list has no effect at all. The viewer also switches the local input method to that setting's language (and its virtual keyboard to its own): on macOS that changed the Mac's keyboard layout, e.g. to ABC for English, so a Swiss keyboard typed QWERTY. Those switches are left out too.
- **Input methods are off for the viewer** (Windows, Linux: on Linux they swallowed dead keys). Not on macOS: there, turning them off made every mouse movement slow. Instead, a dead key's composition is ended right away, otherwise the next key's press doesn't reach Java.

Nothing else in iKVM is changed for the keys, so any viewer version works as long as its key class is `tw.com.aten.ikvm.ui.RemoteVideo`. The Options menu gets a "KeyPasta Agent" entry to turn the keyboard fixes and the paste hotkey off (and for the paste settings, see below).

### Java viewer with AutoHotkey only

Java builds its key table from the layout named in the last `WM_INPUTLANGCHANGE` message it received. The script sends the viewer such a message naming the US layout whenever an iKVM Java window becomes active (and again after a layout change). Windows stays on the local layout, only Java's table changes. The script then sends each physical key of the main block as the US key code of that position (the ISO key as F21, which iKVM maps there) and drops the extra Ctrl of AltGr. On suspend and exit, Java gets its real table back. If the US layout isn't loaded, it's loaded in the background (not activated, not shown in the language bar) and unloaded on exit.

Lock keys only work when iKVM sends them as one press+release message, which it only does for keys released within its "Repeat Key timeout" (default 200 ms; that's also why the timeout must not be 0). So the script sends every CapsLock press as one quick tap. NumLock and ScrollLock: press them briefly (the same trick for NumLock keeps it from reaching Java at all).

### HTML5 viewer

- **With the userscript:** it replaces the viewer's keyboard handling and sends the browser's physical key position (`event.code`) as USB key code, right Alt and the ISO key included. A key pressed with Cmd held on macOS is sent as one tap right away (macOS reports no release while Cmd is held; the key would otherwise stick on the remote and repeat).
- **AutoHotkey only:** the script sends, for each key, the character US has at that position, so the viewer maps it back to the right position. AltGr characters and the ISO key go as alt codes, as the viewer can't send them.

### What works where

See the table in the README. In short: everything works with the agent or the userscript; with AutoHotkey alone, the HTML5 viewer gets AltGr characters only as alt codes, and dead keys only without AltGr.

## 4. Paste

`Alt+Shift+V` types the clipboard into the remote (macOS: `Option+Shift+V` or `Cmd+Shift+V` in the Java viewer, `Cmd+Shift+V` in the browser). The agent, the userscript and the AutoHotkey script paste the same way; the agent and the userscript from inside the viewer, sending the same key events as typed keys.

**The remote's layout can't be known, only said.** Each character is typed with the key that produces it on the remote's layout. Fast paste knows four layouts: Swiss German, Swiss French, German and United States (the agent's and the userscript's tables are identical and checked against X11's `ch`, `ch(fr)`, `de`, `us`). Default: the first of these installed locally, else Swiss German. Where it's set:

- AutoHotkey: tray menu "Remote layout", kept per BMC (registry).
- Agent: Options › KeyPasta Agent: a default (Swiss German unless set, or the `remoteLayout=` option) and optionally the BMC's own (by the host in the viewer's title), kept in Java's user preferences.
- Userscript: its settings dialog: a default and this BMC's own (by host), kept in the extension's storage.

If a character is on several keys, the one with the fewest modifiers wins. Dead-key characters and everything not on the keyboard are sent as **alt codes** (Alt + numpad digits):

- Windows reads `Alt+nnn` as OEM code page and `Alt+0nnn` as ANSI; the Linux console reads both as Unicode. So 160–255 always get the leading 0 and work on both; only the Windows-1252 characters 128–159 (€, curly quotes, dashes) differ, hence the "Remote OS" setting.
- ¦ always goes as an alt code: it's AltGr+1 on Windows' Swiss layouts but `|` on Linux.
- Line breaks are sent as one Enter each.
- Alt codes only type characters (no shortcuts, no dead keys), only on Windows and the Linux console, and on Windows only with NumLock on.

**Safe paste** (CapsLock on while pasting, or the layout set to "other"): everything as alt codes except line breaks, Tab and Space (the same on every layout). Slower, but works with any remote layout.

**Questions before pasting.** If the text has line breaks or AltGr characters (harmful if the remote uses another layout) or characters that aren't on the keyboard, a short dialog asks: fast paste, safe paste or cancel. Once the layout is set, line breaks and AltGr characters aren't asked about any more; what to do with characters not on the keyboard can be set too (ask, alt codes, leave out).

**Stopping.** Switching to another window or pressing Esc stops a running paste. Keys pressed during a paste (agent) are swallowed together with their release, so the remote doesn't get half a key.

**Speed.** The Java app paces the keys itself (`keyDelay=` for the agent; `JavaKeyDelay`, `JavaKeyPressDuration` in the AutoHotkey script). The HTML5 viewer takes keys much faster than the BMC types them: the rest piles up in the BMC, freezes the viewer and keeps typing after Esc and even a page reload. So pasting there waits 10 ms per keystroke (`HtmlKeyDelay`, userscript `KEY_DELAY`).

**The hotkey** is matched by letter, like Ctrl+V, wherever V is on the local layout (`paste=` for the agent, `PasteHotkey` in the AutoHotkey script; the userscript's is fixed). On macOS, Option+Shift+V types no character on the Swiss layouts, and Java dropped such key events entirely; the agent's key patch gives them their unmodified character so they arrive. Cmd+Shift+V is matched by the physical V key, as macOS reported it as C with Cmd held.

**In the container's browser view** the hotkey pastes the Mac's clipboard, without noVNC's clipboard panel: a small script in the page (`mac/container/keypasta.js`) takes the hotkey before noVNC does, reads the browser's clipboard, hands it to the container's clipboard (noVNC's clipboard, TigerVNC's extended clipboard: UTF-8; Ubuntu 22.04's noVNC 1.0.0 had Latin-1 only, so the image takes 24.04's 1.3.0), then sends the hotkey's key on, where the agent pastes as anywhere. Chrome and Edge ask once per port whether the page may read the clipboard; not allowed: the container's clipboard is pasted. The app's Preferences set the hotkey for the agent (`paste=`) and the page (`keypasta_paste=` in its address). The app records the hotkey by the key's place on a US keyboard, where the agent looks for it on macOS (the physical key) and in the container (its X layout is US).

**The userscript** needs the BMC opened with `https://` (browsers give the clipboard to secure pages only), and the browser may ask for permission (Firefox shows a small "Paste" button each time).

## 5. The Java agent: loading, safety, options, log

**Loading.** Java loads the agent for every Java program started with `JAVA_TOOL_OPTIONS=-javaagent:<path to the jar>`. The agent does nothing in programs that aren't IPMIView or the iKVM viewer: it installs its keyboard part only when the viewer's class `tw.com.aten.ikvm.ui.RemoteVideo` loads, and its IPMIView part only when IPMIView's main class loads. Its changes to IPMIView's and the viewer's code are made in memory while the classes load (bytecode, mostly redirecting a call to the agent's own method), never on disk: IPMIView's and the viewer's files stay unchanged, and an update of either just means the agent's change doesn't apply (logged) where the code changed.

**Safety.**

- `premain` never throws: an exception there would stop the JVM, i.e. IPMIView. The key dispatcher passes a key on unchanged if it fails.
- **On the bootstrap class path** (`Boot-Class-Path` in the jar's manifest): Java Web Start (.jnlp) runs the viewer under a security manager that gives class path code no permissions. Loaded by the bootstrap loader, the agent has them.
- **A missing jar stops every Java program.** If `JAVA_TOOL_OPTIONS` points to a jar that isn't there, *any* Java program silently doesn't start. The Windows launchers set the variable only for their own start, and skip it if the jar is missing; `uninstall.cmd` refuses to remove the jar while the variable points to it.
- **Install location:** the viewer runs as admin on Windows (and loads the jar), so the jar belongs in a folder only admins can write to (`%ProgramFiles%\iKVM-KeyPasta\`). A user-writable copy would be a way to admin rights. On Linux and macOS the viewer runs as the user, so a copy in the user's home gives nothing away; a system-wide copy belongs to root, so that no user changes what the others run.
- **The log never shows typed keys or passwords:** only decisions, the first use of each modifier, program names (not their arguments: the Windows viewer's command line has the user name and password).

**Options:** `-javaagent:...jar=name=value,name=value`:

| Option | Default | |
|---|---|---|
| `paste=` | `alt+shift+V` | paste hotkey: modifiers (ctrl, alt, shift, meta/cmd) and a key, by letter |
| `pasteNonAscii=` | `ask` | characters not on the keyboard: `ask`, `always` (alt codes), `never` (left out) |
| `remoteOs=` | `linux` | `linux` (console) or `windows`: alt codes of the Windows-1252 characters 128–159 |
| `remoteLayout=` | `auto` | the default remote layout: `us`, `de-CH`, `fr-CH`, `de-DE`, `other` (alt codes); auto: Swiss German. The dialog's setting wins. |
| `localLayout=` | `auto` | macOS only, the fallback for key positions: `de-CH`, `fr-CH`, `de-DE`, `us`; auto: the current input source |
| `keyDelay=` | `2` | ms between keys when pasting |
| `swapAltCmd=` | `false` | Alt and Command (elsewhere: the Windows key) swapped, see [3](#3-keys). The dialog's setting wins. |
| `mouseRate=` | `60` | mouse moves sent to the BMC per second at most, `0`: every one (see [6](#6-the-java-agent-fixes-in-the-ikvm-viewer)) |
| `macLed=` | `fallback` | macOS: `native` lets iKVM read the keyboard LEDs itself (needs Input Monitoring; the Mac app passes it once that's allowed) |
| `log=` | (none) | debug log file |

Unknown options and values are ignored with a message on the console. The settings in the viewer's Options › KeyPasta Agent are kept in Java's user preferences, node `iKVM-KeyPasta` (macOS `~/Library/Preferences/com.apple.java.util.prefs.plist`, Windows `HKCU\Software\JavaSoft\Prefs`, Linux `~/.java/.userPrefs`), and win over the options.

**Building:** `java-agent/build.sh` or `build.cmd` (a JDK 9 or newer; the jar runs on Java 8 and newer). `java-agent/stub/` holds compile-only stand-ins for macOS classes, not part of the jar.

## 6. The Java agent: fixes in the iKVM viewer

**Window size.**

- **New remote resolution, window in the background:** the `.jnlp` viewer resizes its window to a new resolution only when the window is activated (and shrank it to 320×240 meanwhile). The agent does it right away.
- **Auto-resize on, window bigger than the video:** packed again (seen under WSLg: wide empty margins right and below).
- **Window left at 320×240:** on connecting and on a new resolution the viewer sets its window to 320×240, then fits it to the picture. In the Mac app's container that second step didn't take, and the window stayed tiny with scroll bars. Still that size a second later with the picture running: fitted to the picture (at most the desktop). A size set by hand is left alone.
- **Wayland and WSL (WSLg): windows stay resizable.** A fixed-size window there kept a wrong size (empty margins right and below the video), and Java lost track of its position (menus and clicks offset, the window jumping back on every resize). Reproduced with Weston's X window manager, the same as WSLg's. The viewer's `setResizable(false)` calls are turned into `true`; a property listener restoring it afterwards was too late.
- **The viewer no longer forces itself on top** (`setAlwaysOnTop(true)` becomes `false`).

**Preferences window:** 140 pixels wider and resizable (it cut its content, worst with the Mac font), every OS.

**Mouse moves** are sent to the BMC at most 60 times a second (`mouseRate=`), always the latest position; buttons and the wheel go at once. *Why:* the viewer sent every mouse move Java reported as its own packet, with a fast mouse or trackpad hundreds a second (Windows passes on nearly every hardware report; macOS merges them to the display rate, so Windows was worst). The BMC can't keep up: the frame rate dropped while the mouse moved, more the longer it moved, and needed a while without movement to recover. Single mouse mode sends movements rather than positions and is left unchanged.

**macOS: the virtual keyboard window** is 8 pixels higher (its bottom row was cut by today's taller title bar).

**macOS: the menus in the Mac menu bar.** The agent turns on Java's screen menu bar (`apple.laf.useScreenMenuBar`) for IPMIView and the viewers, adds its KeyPasta item to the viewer's Options menu (the Mac menu bar mirrors a menu's items and never shows its Swing popup, so the item is placed right away and again whenever the viewer adds one), and removes the viewer's Exit menu (Quit and the close button do that).

**macOS: focus and menus after dialogs.** After the launch, after Preferences closed, and above all after Record's two dialogs (save file, video size), the viewer's app was in front but none of its windows had the focus: keys went nowhere, and the Mac menu bar showed only the app menu or was grey, until the mouse moved over the viewer or another app was activated and the viewer again. What happens (from the JDK 11 sources): when a window becomes key, Java installs its menus, greyed if the window is disabled at that moment. After Record's dialogs macOS made the viewer key while Java still had it blocked by the closing dialog: Java dropped that activation, the menus came in grey, and since macOS had the window as key already, no further activation came. What the agent does, when the app is in front, no window is focused and no other window of it is showing:

1. It asks for the focus (enough after the launch and after Preferences).
2. A second later, if still unfocused and macOS has the viewer as its key window, it hands Java the activation it dropped (the call macOS's "became key" notification makes).
3. Once the viewer has the focus, it rebuilds the viewer's menu bar (taken away and given back), so the menus come back enabled.
4. Then it has the menu bar redrawn: **macOS 27 doesn't redraw the menu bar when an app changes the menus in it**; they show only once the pointer goes to the menu bar or the app is switched. (Also seen by the FlatLaf project, with plain Swing too; their remedy is the same.) Setting the app's main menu to nothing and back makes macOS redraw it. That needs native code; it's in the Mac app's `java-launcher` (the program the app runs the viewers in, see [13](#13-macos-the-app-the-scripts-the-container)), as a JNI library built into that program, so there's no extra file. Without the Mac app, no redraw (logged).

**macOS: keyboard LEDs and Input Monitoring.** iKVM's macOS library reads and sets the keyboard LEDs (CapsLock) by opening the keyboard as a HID device, and *quits the viewer* (`exit(1)`, no crash report) when macOS refuses that, i.e. without the Input Monitoring permission. It does that on every focus change (any dialog), on the BMC's LED reports and for lock keys. Without the permission (`macLed=fallback`, the default), the agent leaves out all LED calls and gives lock keys their state from Java instead; with it (`macLed=native`, passed by the Mac app once allowed), iKVM does it itself.

**macOS: the viewer's stunnel.** A `.jnlp` viewer unpacks its own `stunnel` (the encrypted tunnel to the BMC) into a new temp folder on every start: for the macOS firewall (e.g. LuLu) a new program every time. The agent runs Homebrew's stunnel instead, same arguments, or else a fixed copy of the viewer's own in `~/Library/Application Support/iKVM-KeyPasta/stunnel/` (rewritten only when the viewer brings a different one). The viewer stops its stunnel with `killall` by name when it closes; the agent stops the redirected one itself.

**Icons.** The viewer has no icon of its own (Java's): it gets KeyPasta's on its windows, and on macOS in the Dock, dark or light with the system appearance (followed while running). IPMIView keeps its own window icon; on macOS its Dock icon (Java's otherwise) is set from it.

## 7. The Java agent: fixes in IPMIView

IPMIView is Supermicro's management program; it lists BMCs, logs in to them and starts the Java viewer. IPMIView's About dialog gets a "KeyPasta agent" tab with the project page; it lists these changes as they apply on the running OS.

**Faster console launch.**

- After starting its tunnel (stunnel), IPMIView waited a fixed 4 seconds. Now only until the tunnel is ready, usually a fraction of a second (checked by the tunnel's port being taken).
- On Linux and macOS the viewer paused 5 seconds after reading its settings from IPMIView, before connecting. That pause is skipped.
- With `log=`, every launch step is logged with its time (BMC questions, tunnel, test login, viewer start, connecting, logged in, viewer window, first picture).

**No settings file with the password.** On Linux and macOS, IPMIView handed the viewer its settings (user name, password, ports) in a file `<BMC>.temp` in the temp folder, readable by other users. When the viewer runs with the agent too (which the Mac app and a global `JAVA_TOOL_OPTIONS` ensure), IPMIView hands them over through the viewer's standard input instead, and the file is never written. Otherwise the file as before.

**No needless questions.**

- IPMIView quits without asking "Are you sure to quit?" (other questions, like saving a changed configuration, stay).
- Closing a BMC's session no longer shows the note about closing its KVM console.

**Main window:** 20 pixels wider on Windows and Linux, 1144 pixels wide on macOS (for the wider Mac font). On macOS also its status line gets some margin (the rounded window corners cut the text).

**Fonts.** IPMIView sets its own font, PMingLiU (a Taiwanese font with thin, hard-to-read Latin letters), on macOS and Linux.

- **macOS:** SF Pro if installed, else Helvetica Neue, 13 pt. Only fonts macOS lists to Java are drawn with macOS's own text rendering; the system copy of San Francisco isn't listed, and loaded from its file Java draws it visibly heavier.
- **Linux:** Noto Sans, DejaVu Sans or Liberation Sans (the first installed), 12 pt, and antialiased: Java takes antialiasing from the desktop's settings, and without a desktop (e.g. WSL) it was off, showing PMingLiU's jagged built-in bitmaps.
- **Text cut by the wider font** (IPMIView's fixed label widths were made for PMingLiU): labels and buttons are widened where there's room, else made smaller or given a tooltip; dialogs grow towards their preferred size. **Windows laid out by coordinates** (the Flash Tool) are made big enough for their content (under WSL their frame took a part of them).
- **macOS: no boxes in boxes.** Aqua's tab panes draw a rounded box around their content; inside IPMIView's own boxed panels that gave boxes in boxes. The agent turns that box off for IPMIView's tab panes.

**Login.** IPMIView's "Save ID and Password" keeps the password in `account.properties`, obfuscated (AES with the device name as key; IPMIView decrypts it itself to fill the login view).

- The password field of the login view gets an **eye button** that shows the password.
- The firmware update's login popup ("Please input ID and Password") is **filled with the BMC's saved ID and password** (it asked again although they were saved).
- **Removing a system** from IPMIView's list also removes its saved ID and password (by name, and by IP address if no other system has it).

**Sensors.** A BMC's Sensors tab opens in its **text view** (the graphic view was the default), which gets a **"Clear Chassis Intrusion"** button next to Refresh (only the graphic view had one). It asks IPMIView's own question, sends the same Supermicro command as the graphic view's "Clear" (`ipmitool raw 0x30 0x03`), then reads the sensors again.

**Faster first login.** IPMIView looked up the computer's own address (`InetAddress.getLocalHost`) for every connection to a BMC and every packet it sent. That resolves the computer's own name, which returns all addresses of all its network adapters; Java keeps the answer only 5 seconds and holds a lock while it asks. IPMIView checks the status of all listed BMCs every 20 seconds, one connection each, and the login queued up behind those lookups: on Windows with many adapters or VPN addresses, the first login after the start took long, longer the more addresses the computer has. In the classes changed, the address was only used where any address of the computer does (as the placeholder address of a packet to receive, and to wake IPMIView's own receiving connection), so they get the loopback address 127.0.0.1 without a lookup. Where the BMC is told the address (the old serial console redirection), or where the adapter matters (a MAC address used as a key), the lookup stays.

**macOS without Homebrew's stunnel:** IPMIView starts anyway, and a red note below "Launch KVM Console" says that the encrypted console needs it.

**Login diagnosis:** with `log=`, opening a BMC's session view or pressing a button in it logs 20 seconds of what IPMIView's threads do (where they wait), to find delays.

## 8. The HTML5 userscript

`iKVM-KeyPasta.user.js` runs in the BMC's HTML5 viewer page (Tampermonkey or Violentmonkey).

- **Keys** by physical position (`event.code`), sent as USB key codes through the viewer's own functions, right Alt and the ISO key included (see [3](#html5-viewer)). Focus loss releases what the remote has down.
- **Paste** from the clipboard (see [4](#4-paste)).
- **Settings** (the extension's menu, "KeyPasta settings…", in the viewer's tab): the remote's layout (a default, and this BMC's own by host), characters not on the keyboard (ask, alt codes, leave out), the remote system for alt codes. Kept in the extension's storage, not in the BMC's site data. The script's dialogs live in their own shadow root with their own styles (light and dark), so the BMC page's CSS doesn't reach them.
- **The viewer's own hotkeys** (Options › Hotkey Settings, e.g. Ctrl+Shift+F5 for Ctrl+Alt+Del) work again: the script's key handling had starved them; it now asks them first, and a key that matches one isn't sent.
- **Large remote screens:** the page no longer sticks out to the right (Bootstrap's fixed-width container): it's centered while it fits the browser window, else starts at the left edge.
- **Video recording outside Chrome:** the viewer records in Chrome only, and elsewhere popped up its warning at every start. The script keeps that warning for when it's asked for: a grayed out "Video recording (unavailable)" item (older viewer: in the Capture menu; newer viewer with a row of buttons, under `/redfish/…IKVM`: the record button, grayed out) shows it when clicked.
- **Both viewer generations:** the newer viewer (Bootstrap 5, row of buttons) has the same keyboard internals as the older one, so keys and paste work the same; only its recording warning and button needed their own handling.

## 9. The login-fix userscript

`login-fix.user.js` makes the BMC's login form fillable by password managers again, which Supermicro/ATEN made harder with each BMC generation: it adds the `autocomplete` attributes, makes the password field a real password field, and puts the focus on the user name. It matches BMCs addressed by IP address (IPv4, IPv6, `*.ipv6-literal.net`); host names can be added in the extension's script settings.

## 10. The AutoHotkey script

`windows/iKVM-KeyPasta.ahk` (AutoHotkey v2, Windows). Where the agent or the userscript is active (title marker), it only adds what they can't do; elsewhere it fixes the viewers itself (see [3](#3-keys) and [4](#4-paste)).

- **Ctrl+Alt+End sends Ctrl+Alt+Del to the remote**, as in Remote Desktop (the real one always goes to the local Windows). It asks first, Cancel being the default, since on a Linux console Ctrl+Alt+Del reboots the server right away; "Don't ask again for 4 hours" turns the question off for a while, `ConfirmCtrlAltDel := false` for good. Windows would make a local Ctrl+Alt+Del of a Delete sent while Ctrl and Alt are held, so Ctrl and Alt are sent and the Delete is posted to the viewer window as a message.
- **Alt+Tab in the Java app goes to the remote.** Windows opens its task switcher for every Alt+Tab, even a sent one, before Java sees it, so the Tab is blocked and posted to the Java window as a message. Locally, use Win+Tab or the mouse. (The HTML5 viewer can't get it.)
- **Paste in other programs:** `Alt+Shift+V` pastes plain text anywhere (tray menu to turn it off).
- **Tray menu:** remote layout (per BMC), remote OS (alt codes of €, curly quotes, dashes), non-ASCII characters (ask, include, omit), paste in any window or iKVM only, suspend.
- **Rights.** Windows refuses keystrokes and messages to programs running as admin (the iKVM Java app may) unless the script has UI Access or runs as admin itself. When that happens, it restarts itself with UI Access (`AutoHotkey*_UIA.exe`, part of the AutoHotkey installation), or else as admin (UAC prompt); declined: a notification, and the tray menu's first entry tries again. UI Access is only granted to programs in a protected folder (`%ProgramFiles%`): in a folder you can write to, any program running as you could change the script and get its rights. A compiled exe also needs to be signed (the README shows how with a self-signed certificate).
- **One instance:** starting the script again closes the running one, .ahk or compiled exe, from any folder and with any rights (the new one first restarts itself with the same rights, as Windows doesn't let a normal process close a privileged one).
- **`DebugMode := true`** records key history, executed lines and the messages to the Java app (tray menu). Never leave it on: the key history contains passwords.

## 11. Windows: installer and launchers

**`windows/install.cmd`** (as admin) copies whatever of the jar, the jnlp launcher, the IPMIView launcher, the .ahk or a compiled exe and the icons is there to `%ProgramFiles%\iKVM-KeyPasta\` (closing an installed exe first, as a running exe can't be overwritten), then as the user: registers the jnlp launcher, creates the Start menu shortcut "IPMIView with KeyPasta" (if IPMIView is installed) and a Startup shortcut for the script, and starts it. Without AutoHotkey v2 it offers to install it with winget (machine-wide: UI Access needs `%ProgramFiles%`); without OpenWebStart it offers that too. `windows/uninstall.cmd` undoes it; it refuses while `JAVA_TOOL_OPTIONS` points to the jar (see [5](#5-the-java-agent-loading-safety-options-log)). The copied `.jnlp` files in `%TEMP%` stay.

**`windows/iKVM-IPMIView-launcher.cmd`** (the Start menu shortcut): restarts itself as admin, sets `JAVA_TOOL_OPTIONS` for this start only and starts IPMIView. *Why:* the viewer runs as admin, and a process elevated by UAC gets its environment from the registry, not from the program that started it, so a variable set just for one start must be set inside the elevated process.

**`windows/iKVM-jnlp-launcher.cmd`** (meant as the program for all `.jnlp` files; `/register` adds it to "Open with", where it's made the default by hand, as Windows doesn't let programs set defaults): an iKVM `.jnlp` gets the same treatment (elevation, `JAVA_TOOL_OPTIONS` for this start only), is moved out of the Downloads folder to `%TEMP%\iKVM-KeyPasta\` under a name with date, time and BMC, and is started with OpenWebStart. Any other `.jnlp` goes to OpenWebStart unchanged. Started without a file, it takes `Downloads\launch.jnlp`. Settings at its top: `JNLP`, `OWS` (OpenWebStart folder), `JAVAVERSION` (default `1.8*`).

**OpenWebStart with Java 8:** Java 11 and newer have no `javaws` for `.jnlp` files any more, OpenWebStart provides one. It must run the viewer with Java 8: the `.jnlp` files ask for Java options that Java 17 and newer refuse ("Unrecognized VM option 'PermSize=32M'"). Current Java 8 refuses TLS 1.0 and 1.1, which old BMCs may need (`jdk.tls.disabledAlgorithms` in that Java's `java.security`).

## 12. Linux: the desktop launcher

`linux/install.sh` puts IPMIView and iKVM Viewer (for `.jnlp` files) into the desktop's app menu (GNOME, KDE and others following the freedesktop.org standards), and the command `ipmiview`, all with the agent.

- **Where it goes follows IPMIView.** IPMIView in the user's home: everything for that user, without root (`~/.local/share/iKVM-KeyPasta` for the agent and the starters, `~/.local/share/applications`, `~/.local/share/icons`, `~/.local/bin/ipmiview`). IPMIView elsewhere, e.g. under `/opt`: everything for all users, as root (`/opt/iKVM-KeyPasta`, `/usr/local/share/applications`, `/usr/local/share/icons`, `/usr/local/bin/ipmiview`), so that no user can change what the others run. `--user` and `--system` override it; installing one kind removes the other. The viewer runs as the user on Linux, so a copy in the home gives nothing away (unlike Windows, where it runs as admin).
- The menu entries: `IPMIView.desktop` (with IPMIView's folder in its command), `iKVM-Viewer.desktop` (the program for `.jnlp` files; it also gives the viewer's windows their name and icon, whether started from IPMIView or a `.jnlp`) and the icon in all sizes, with the install's paths filled in. iKVM Viewer becomes the program for `.jnlp` files if none is set or it's OpenWebStart's; else the installer says how.
- `ipmiview-keypasta.sh` sets `JAVA_TOOL_OPTIONS` for IPMIView only (the viewers it starts inherit it) and starts IPMIView in its folder, where it keeps its settings (`IPMIView.properties` with the BMC list, `account.properties` with saved IDs and passwords, a few more).
- **IPMIView installed for all users:** a normal user can't write its folder, so the BMC list and logins couldn't be saved. Then IPMIView runs in `~/.config/ipmiview` instead, which links to everything in IPMIView's folder (it finds its files relative to the folder it runs in), except the settings files, which are the user's own. On the first start the folder's settings files are copied as a starting point (e.g. a BMC list prepared there), except `account.properties`: saved passwords are personal. The links are made again on every start. As root, or with a folder you may write to, IPMIView runs in its folder as before. (The Mac script does the same, always.) Without the jar, or with a space in its path (`JAVA_TOOL_OPTIONS` can't quote it), IPMIView starts without the agent rather than not at all. IPMIView's folder: the menu entry's, else the first one found in the home folder, `~/.local/bin`, `~/Applications`, `/opt` or `/usr/local`.
- **`jnlp-keypasta.sh`** works like the Windows jnlp launcher (no admin rights needed on Linux): an iKVM `.jnlp` (one naming `tw.com.aten.ikvm`) is started with OpenWebStart, the agent for this start only and Java 8 asked for in the file (`JAVAVERSION`), and moved out of Downloads to `~/.cache/iKVM-KeyPasta/launch-<date>-<time>-<BMC>-<random>.jnlp`, readable by the user only (it holds the console session's login data), and kept there. Any other `.jnlp` goes to OpenWebStart unchanged. Started without a file: `launch.jnlp` from the Downloads folder. OpenWebStart's `javaws`: `$JAVAWS`, else in `PATH`, else `~/openwebstart` or `/opt/openwebstart`. With `--debug` the log is followed until Ctrl+C, as OpenWebStart may hand the viewer to a JVM of its own and return.
- **Window classes.** A desktop ties windows to their menu entry by their window class (`StartupWMClass`): name and icon in the dock, windows grouped. Java takes the class from where its window system was started: IPMIView's own launcher gave "com-zerog-lax-LAX", with the agent "java-lang-Thread", meaningless either way. The agent sets "IPMIView" and "iKVM-Viewer" right after Java's window toolkit starts, before the first window.
- **The command `ipmiview`:** a link to `ipmiview-keypasta.sh` (in `~/.local/bin` or `/usr/local/bin`, see above; most systems put `~/.local/bin` into `PATH` once it exists). An `ipmiview` that isn't this link is left alone. The starters follow links to find the agent next to themselves, and the installer notes IPMIView's folder next to them (`ipmiview-folder`), so a bare `ipmiview` finds it.
- **`--debug`** (`-d`), when started from a terminal: the agent logs to `~/.local/state/iKVM-KeyPasta/agent.log` (the run before: `agent.log.old`), and the script shows it there as it grows, next to IPMIView's own output, until IPMIView ends. A file rather than the terminal itself, because IPMIView starts the viewers with their output connected to IPMIView, not to the terminal; the viewers inherit the agent's options and write to the same file. Not `/var/log`: only root may write there.
- `bash linux/install.sh --uninstall` removes all of it.

## 13. macOS: the app, the scripts, the container

Supermicro offers no working Java console for macOS: IPMIView (2.25) refuses the KVM console there for BMCs with encrypted KVM ("The function can't support on mac"), and the `.jnlp` viewer needs an Intel Java and OpenWebStart. The `mac/` folder makes both work, with the agent.

### The app (`mac/launcher-app`)

"IPMIView KeyPasta" (built with `build.sh`, Xcode Command Line Tools only) starts IPMIView or a dropped `.jnlp` with the agent, and shows their output in its window.

- **One fixed identity for macOS's permissions.** Input Monitoring (keyboard LEDs, see [6](#6-the-java-agent-fixes-in-the-ikvm-viewer)), Local Network and the firewall are granted to this app once; the viewers and the tunnel run as its children and count as the app, so nothing asks again. macOS ties Input Monitoring to the exact build (the app is signed ad hoc), so after an update the old entry may need removing and adding again; the app asks once per build.
- **The viewers are its children:** quitting the app ends them and their sessions, so it asks first while any is running.
- **`.jnlp` files** run through OpenWebStart's own engine (IcedTea-Web) with a separate profile of the app's, in the app's process tree: OpenWebStart's macOS launcher ignores a file passed to it and forks a detached process.
- **Status dot:** green everything works as it should, yellow with a shortcoming, orange only IPMIView or only `.jnlp` files, red nothing.
- **One window,** no File › New Window and no tabs; File › Open .jnlp… (`Cmd+O`) opens a `.jnlp`, as the drop area does. While IPMIView or a `.jnlp` starts, a throbber takes the place of the button's symbol: until its window is there (natively: the app named "IPMIView" or "iKVM Viewer" appears, see `java-launcher`) or its console answers (container), 90 s at most.
- **Container mode** (see below), for when the native viewer can't run. While IPMIView's container runs, the launch button opens its console instead (starting it again would replace the container and end IPMIView and its viewers); Stop is next to it in the list of running containers.
- **Browser** (Preferences, container mode): where the consoles open. Automatic (Chrome or Edge if installed: their fullscreen passes Ctrl+Tab and Alt+Tab to the remote; else the default browser), the default browser, one of the browsers macOS knows for web pages, another one chosen with "Select other…", or a command: run by `/bin/sh` with `URL` in its environment, so `"${URL}"` in it is the console's address, quoted as written (appended if missing). Example, Chrome's profile "Profile 1" in app mode, a window per console without tabs and address bar: `open -na "Google Chrome" --args --profile-directory="Profile 1" --app="${URL}"`.
- **Paste hotkey** (Preferences): recorded from a key press, Control, Option or Command with a letter, digit or F-key, by its place on a US keyboard; for the agent (native and container) and the container's browser view.
- The agent jar is bundled in the app. `JAVA_TOOL_OPTIONS` can't quote paths with spaces, and the app's name has one, so the jar is used from a copy in the temp folder.

### `ipmiview-keypasta.sh`

The script the app runs for IPMIView (also usable alone). IPMIView's Mac code for the encrypted console is still there, only switched off in one method (`com.supermicro.ipmi.stunnel.StunnelFacotry.createStunnel`); the script starts IPMIView with a stand-in for that one class (`mac/patch/`, compiled on the first start) in front of `IPMIView20.jar`. IPMIView's files stay unchanged. It also:

- renames the Linux package's `jre` folder to `jre-linux` (else IPMIView looks for the viewer's Java there);
- puts a small `stunnel` wrapper into `BMCSecurity/mac/` that starts Homebrew's stunnel (IPMIView copies its tunnel program to a new temp folder for every console, and a copied program makes the firewall ask every time);
- sets `proxy_ip=127.0.0.1` in `stunnel.properties` (else the tunnel listens on the network address, which the firewall asks about too);
- runs IPMIView in `~/.config/ipmiview`, linked to everything in the IPMIView folder: IPMIView keeps its settings (`IPMIView.properties` with the BMC list, `account.properties`) in the folder it runs in, so they stay apart from IPMIView and survive an update.

The viewer needs an **Intel Java** (it loads x86_64-only native libraries; on Apple Silicon it runs through Rosetta 2), IPMIView itself runs on any. The encrypted console needs **Homebrew's stunnel**. stunnel's log: `/tmp/iKVM-KeyPasta-stunnel.log`.

### `java-launcher` and the names in the Dock

The Dock and Cmd-Tab name a program without an app bundle by its executable's file name: "java" for every Java program (Java's `-Xdock:name` reaches only the menu bar since OS X 10.9, an open OpenJDK bug). So `java-name.sh` (first in `PATH` as `java`, since IPMIView starts the viewers as `java`) runs IPMIView through a copy of `java-launcher` named "IPMIView", and the viewer through one named "iKVM Viewer"; anything else as plain java. `java-launcher` starts Java inside its own process. The two copies live in `~/Library/Application Support/iKVM-KeyPasta/Launchers`, replaced only when they change: two programs for the firewall, asked about once.

`java-launcher` also carries the agent's only native code, the menu bar redraw for macOS 27 (see [6](#6-the-java-agent-fixes-in-the-ikvm-viewer)): Java finds a JNI library built into the program it runs in, so that needs no file of its own.

### Container mode (`mac/container`)

The whole console in an amd64 Linux container (OrbStack, Docker Desktop, Colima or Podman; Colima is an engine without Docker Desktop that needs Homebrew's `docker` command, Podman has its own `podman` command, which `run.sh` uses when there is no `docker`; a missing Podman VM is made with `podman machine init`). Colima and Podman share only the home folder (and a few others) with their Linux VM, so `run.sh` puts what it mounts from elsewhere into `~/Library/Application Support/iKVM-KeyPasta/container` first: the agent jar (the app's copy is in the temp folder, `/var/folders`; it came out as an empty folder and the agent wasn't loaded) and a `.jnlp` (was `/tmp`), a copy per container, replaced whole so a running one keeps its own. An IPMIView, virtual media or screenshots folder outside the home folder gets a note (it may be empty in the container). Reaching the BMCs is the engine's business, not checked by the app: Colima's user-mode network (and likely Podman's) runs in a helper program that macOS's Local Network permission silently denies (macOS 15 on), so every BMC connection was refused while the Mac itself reached it; `colima start --network-address` (a root helper, which the permission doesn't apply to) or the permission granted fixes it, `--vm-type vz --vz-rosetta` replaces QEMU's x86 emulation with Rosetta. `bmc-check HOST` in the container (`docker exec ikvm-console bmc-check 192.0.2.40`) shows whether a BMC answers there (UDP 623 IPMI, TCP 623/5900/443/80) and how x86 code runs, shown in the browser (noVNC). *Why:* the viewer's native libraries are x86_64 only; macOS 28 removes Rosetta 2, and then only an emulated Linux can run them. In Linux, IPMIView's own encrypted console works without the stand-in class. The app builds the image on first use and opens the browser view when it's up. Folders for virtual media images and for screenshots/recordings can be mounted; the desktop follows the browser window's size; fonts are antialiased (over VNC, Swing looked awful without). IPMIView's main window fills the desktop without a frame (a window manager rule for its window class; the agent then leaves its size alone). The container shares IPMIView's settings with the native start: the BMC list (`IPMIView.properties`) and the saved logins (`account.properties`) are the ones in the Mac's `~/.config/ipmiview`, mounted into the container; IPMIView runs in a folder that links to everything else in the IPMIView folder, as natively. The `.jnlp` start's settings and the certificates you chose to trust ("Always trust content from this publisher") are kept too, in the Mac's `~/.config/ipmiview/icedtea-web`, so you're asked once per publisher, not on every start. Not in OpenWebStart's `~/.config/icedtea-web`: that holds Mac paths and OpenWebStart's own choices. The agent's settings (its KeyPasta dialog) are kept the same way, in `~/.config/ipmiview/java` (Java's preferences; the native start has its own). The desktop's menu (right-click) opens IPMIView, IcedTea-Web's settings (Java Web Start's settings and certificates; open-source Java has no other Java control panel), or restarts the container.

**A `.jnlp`'s container and a viewer's own tab are alike:** the viewer's main window fills the desktop without a frame (only it: matched by window class and its opening title "Java Viewer"; IPMIView's own main window by "IPMI*View*", not its SOL, Trap Receiver or keyboard windows), its other windows keep their frames, a window list at the bottom (tint2), and the desktop menu (right-click) has "End this console" (the viewer's tab: ends that viewer, TERM then KILL after 3 s; the `.jnlp`'s: ends the container) and, for a `.jnlp`, IcedTea-Web's settings.

**One IPMIView container, any number of `.jnlp` ones** (up to ten): IPMIView's is `ikvm-console` on port 6080, a `.jnlp` gets a container of its own, `ikvm-jnlp-PORT` on the first free port of 6090–6099, next to it and the others, and its tab is titled "iKVM <BMC>" (the `.jnlp`'s first argument). Its viewer fills the desktop without a frame, as in a viewer's own tab (window manager rule for its window class and the title it opens with, "Java Viewer", so only the main window: its virtual keyboard, preferences and macro windows keep their frames; `KEYPASTA_VIEWER_TAB=1` for the agent); IcedTea-Web's dialogs stay windows. It ends with its viewer and is removed then (a closed viewer or a cancelled start); its desktop menu has "End this console" instead of a restart. The app lists the running ones with Open and Stop, and notices every 5 s which ended.

**noVNC's address is `/novnc/vnc.html`,** served with "Cache-Control: no-cache" (`keypasta-websockify`: websockify with that header). Browsers keep pages without that header for a time they guess from the file dates: after the image changed to noVNC 1.3.0, one kept 1.0.0's `ui.js` and ran it with the new page ("Cannot read properties of null (reading 'addEventListener')"). Under the new address no old file is found; from now on the browser asks each time (unchanged: a short "304"). The old address `/vnc.html` leads there.

**Keys, from the Mac to the remote.** Each layer passes a key on by its place, not by its character, so the remote's own layout makes the character:

1. *macOS → browser:* the browser gets the key's place (`code`) and its character. macOS and the browser keep some shortcuts (Cmd+Tab, Cmd+Space, Cmd+Q; Cmd+W, Cmd+T in a tab). In noVNC's fullscreen the page locks the keyboard where the browser can (Chrome, Edge: Keyboard Lock): most of those go to the remote then; hold Esc to leave fullscreen.
2. *browser → noVNC* (`keypasta.js` first, then noVNC): on an ISO keyboard macOS gives the key left of 1 and the key left of Z each other's place, and some browsers pass that on; told apart by the character as the agent does natively (§ ° ± ¶ • \` ~ ^ ¬ and dead keys are left of 1). macOS sends no release for a key pressed with Command held (the remote kept it down: with Alt and Command swapped, Cmd+C left C repeating): released when Command goes up. noVNC's own swap of Option and Command for a Mac (Command as Alt, Option as AltGr) is taken out of the image: Command is the Windows key, Option Alt, as natively; the agent swaps them per BMC if asked (see [3](#3-keys)).
3. *noVNC → Xvnc:* noVNC sends each key's place (QEMU extended key event) and a character. Xvnc went by the character, giving a key the container's layout lacks (ö, é, §) a made-up key code, which the agent can't place: nothing reached the remote. With `RawKeyboard=1` it goes by the place.
4. *Xvnc → Java:* the container's layout is the Mac's (the app passes its current input source, `--layout`, the PC variant: right Option is AltGr), so typing into IPMIView's own fields there gives the same characters as on the Mac.
5. *Java → agent → remote:* the agent sends the place (X key code), see [3](#3-keys).

Tested here with Chromium posing as a Mac (Chrome DevTools key events with a Swiss character on a US place): § with the ISO key's code reached Java as the key left of 1, < the other way round; Cmd+C without C's release: C released before Command; ö and Swiss Z by their places with RawKeyboard, a made-up key code without.

**Clipboard, shared both ways** (`keypasta.js`): copied in the container (its clipboard, not a mere selection: Xvnc `SendPrimary=0`, a selection used to land in noVNC's clipboard panel) goes to the Mac's clipboard (Chrome and Edge while the page has the focus, else when it gets it back); the Mac's goes to the container's whenever the page gets the focus, once reading it is allowed (Chrome and Edge ask once, at the first paste hotkey). Not on focus in Safari and Firefox: they would ask every time; the paste hotkey works there anyway. Tested here: both ways with Chromium, a selection stayed in the container.

**Viewers in browser tabs** (the app's "Open iKVM Viewer windows in separate browser tabs", on by default): each console IPMIView opens gets a desktop of its own (up to nine), filled by the viewer's window without a frame, and the app opens it in a new browser tab, titled "iKVM <BMC>"; the tab's desktop follows the tab's size. How: IPMIView starts its viewers as `./jre/bin/java -jar iKVM….jar` in the folder it runs in; there `jre/bin/java` is a small script that starts a desktop (Xvnc on display 1–9) with its own window manager and browser connection (ports 6081–6089, published by `run.sh`), runs the viewer there, and removes it all when the viewer ends; anything else goes to the real Java. The app polls those ports while the container runs and opens a tab for each that comes up. The viewer resizes its own window on connecting and on every new resolution, which would undo the maximizing: with `KEYPASTA_VIEWER_TAB=1` (set by that script) the agent keeps the window maximized and resizable and leaves out its other size fixes. A closed viewer leaves its tab on noVNC's "disconnected" page: browsers don't let a page close a tab it didn't open. What it does is in the container's log (`docker logs ikvm-console`): a line per viewer started and ended, with its port.

### Expired iKVM certificate

Old BMC firmware ships an iKVM TLS certificate with a fixed expiry (X10 AST2400 firmware 03.93: 17 May 2026). After that date the stunnel log shows `certificate has expired` and the console won't open. The HTML5 viewer still works (it doesn't use this certificate), but it can't mount a remote ISO.

The tunnel is mutual TLS: the BMC presents its certificate *and* requires the client's, and both expired the same day. Without changing the firmware, two steps together:

1. The app's "Accept the BMC's expired iKVM certificate" (`IGNORE_EXPIRED_CERT=true` for the script): the tunnel stops checking the BMC's certificate (`verify = 0`). The console stays encrypted, but the BMC's identity isn't checked, for every BMC opened that way: leave it off otherwise.
2. Set the BMC's clock back before the expiry (NTP off, date set in Configuration › Date and Time, or `ipmitool ... sel time set "01/01/2025 12:00:00"`), because the BMC checks *our* expired certificate against its own clock. SEL timestamps are wrong meanwhile.

Newer firmware (04.07) has certificates valid to 2041; updating the BMC is the lasting fix.

### Karabiner-Elements rules (`mac/karabiner`)

Before the agent could swap them itself (see [3](#3-keys); not both at once, or they cancel out). Only in the iKVM viewer: Option and Command swapped (the keys next to the space bar become the remote's Alt and AltGr, the outer ones its Windows key, as on a PC keyboard; the agent's Option+Shift+V is then the physical Cmd+Shift+V), and F1–F12 without fn for the remote.

### Icons (`mac/icons`)

Light and dark `.icns` and SVGs, including layers for Icon Composer (an `.icns` can't follow dark/light mode, and macOS 26 puts icons that aren't rounded squares into a grey square unless they come from Icon Composer). The 16 and 32 pixel sizes use Apple's classic format, not PNG: small list views (e.g. the Input Monitoring list) showed PNG there as colored noise.

## 14. Logs and diagnosis

- **Agent:** `log=<file>` (Mac app: `~/Library/Logs/iKVM-KeyPasta/agent.log`; Linux launcher with `--debug`: `~/.local/state/iKVM-KeyPasta/agent.log`). Decisions only, never typed keys or passwords.
- **stunnel on macOS:** `/tmp/iKVM-KeyPasta-stunnel.log`.
- **Is it active?** The viewer's title (Java) or tab title (HTML5) ends with ⌨.
- **AutoHotkey:** `DebugMode` (see [10](#10-the-autohotkey-script)).

## 15. Tried and dropped

Kept here so nobody tries them again without a new reason.

- **macOS, menus after Record's dialogs:** asking for the focus repeatedly and bringing the window to front (no effect: macOS had it as key already); a focus round trip through an invisible 1×1 window (keys came back, the menus disappeared: that window took the menu bar, and the viewer, still the main window, didn't get its menus back); handing the window its menu bar again (no visible effect on macOS 27); removing a stuck native dialog block (never happened). See [6](#6-the-java-agent-fixes-in-the-ikvm-viewer) for what works.
- **WSLg:** `_JAVA_AWT_WM_NONREPARENTING` (didn't change the frame sizes); restoring "resizable" right after the viewer turned it off (too late).
- **Fonts on macOS:** loading San Francisco from its file (drawn heavier than native text); Helvetica 11 (too small); window widths of +20 %, +15 % and automatic widening (rejected in favour of a fixed 1144 pixels).
- **Dock names:** one launcher copy per BMC (one firewall rule each); app bundles (the Dock still showed the executable's name); setting LaunchServices' display name from inside Java (only Force Quit and Activity Monitor followed).
- **Input methods off on macOS:** every mouse movement got slow.
- **IPMIView's own-address lookup:** caching the first answer (could go stale when a network adapter goes away; the loopback address needs no lookup at all).
