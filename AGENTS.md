# AGENTS.md

Notes for AI agents working on iKVM-KeyPasta. Read this before changing anything; `README.md` is the user documentation.

## What this is

A Java agent, a userscript and an AutoHotkey v2 script that make the keyboard in the Supermicro/ATEN iKVM remote consoles (Java app and HTML5 browser viewer) behave like a keyboard plugged into the server: every key arrives at its physical position, the remote's layout decides what it types. It also pastes the clipboard (`Alt+Shift+V`, macOS `Cmd+Shift+V`), sends Ctrl+Alt+Del (`Ctrl+Alt+End`) and Alt+Tab (Java) to the remote.

Fix things at their source: the Java agent for the Java viewer, the userscript for the HTML5 viewer (both cross-platform). The AutoHotkey script (Windows only) keeps what only works from outside (Ctrl+Alt+Del, Alt+Tab, paste in other programs) and fixes both viewers itself when the agent or the userscript is missing. Each marks the window title with " ⌨"; the AutoHotkey script then leaves that window's keys alone (`IsJavaPlain`, `IsHtmlPositional`).

## Hard constraints

- **Never require changing the iKVM "Keyboard layout" setting.** It stays English on countless BMCs.
- **Never require changing the local input layout,** and don't assume the maintainer's custom layouts: the target audience uses a Swiss layout. Typing must work with any local layout.
- **Knowing or configuring the remote's layout is not feasible.** Fast paste assumes Swiss; safe paste (CapsLock on) works with any layout.
- **No test-only triggers in the shipped script** (e.g. activating things with F-keys). Experiments go behind `DebugMode`.
- **`DebugMode` must be `false` in anything handed out:** the key history records secrets.

## Files

| File | Notes |
| --- | --- |
| `iKVM-KeyPasta.ahk` | The script. UTF-8 **without BOM** (AutoHotkey v2 reads scripts as UTF-8 anyway; the maintainer doesn't want a BOM), **CRLF**, 4 spaces (no tabs). Edit in place with a read-modify-write that keeps CRLF and adds no BOM. |
| `iKVM-KeyPasta.user.js` | Userscript for the HTML5 viewer: keys by `event.code`, paste via `navigator.clipboard`. Bump `@version` on every change. |
| `java-agent/` | Agent source (`src/keypasta/*.java`, Java 8 compatible: no newer APIs, `--release 8`), `manifest.txt`, `build.cmd`/`build.sh` → `iKVM-KeyPasta-agent.jar`. Rebuild the jar after every source change. |
| `iKVM-KeyPasta-agent.jar` | Built agent. Loaded with `JAVA_TOOL_OPTIONS=-javaagent:...`, set permanently per user (README "Java viewer setup": the viewer runs as admin, and a UAC-elevated process gets its environment from the registry, not from its parent; .jnlp files are opened by the browser through OpenWebStart); installs itself only when `tw.com.aten.ikvm.ui.RemoteVideo` loads; changes no classes (a `KeyEventDispatcher` in front of the viewer). |
| `iKVM-jnlp-launcher.cmd` | Windows helper for .jnlp files: meant as the program for all .jnlp files (`/register` adds a ProgID in HKCU and lists it in `.jnlp\OpenWithProgids`; the user picks it in Open with: Windows doesn't let programs set defaults). Only a .jnlp containing `tw.com.aten.ikvm` gets the treatment below; any other one goes to OpenWebStart unchanged, as the user, not moved. For the viewer it restarts itself as admin (`fltmc` check, PowerShell `Start-Process -Verb RunAs`, `/elevated` against loops; the user's .jnlp path and %TEMP% passed along as arguments, as an admin account answering the prompt has its own, built with `[char]34` for the quotes), sets `JAVA_TOOL_OPTIONS` for that start only (skipped if the jar is missing: a missing agent jar stops every JVM), moves `Downloads\launch.jnlp` to `%TEMP%\iKVM-KeyPasta\launch-<yyyyMMdd>-<HHmmss>-<codebase host>-<random>.jnlp` (name from one PowerShell call; no `"` inside it, as cmd would end its quoting there: `\x22` in the regex) and starts it with OpenWebStart's `javaws.exe`; the files are kept. No `( )` blocks around paths that may contain ")". Tested under Wine with fake fltmc/powershell/javaws executables (Wine 9 cmd gets `&&`/`||` and `move`'s errorlevel wrong: use `if errorlevel` and existence checks). |
| `iKVM-IPMIView-launcher.cmd` | Windows: started by the Start menu shortcut; not admin: starts itself again as admin (UAC prompt, `cmd /c ""script" /elevated"`); sets `JAVA_TOOL_OPTIONS` for this start only and starts `IPMIVIEW` (`%ProgramFiles%\SUPERMICRO\IPMIView\IPMIView20.exe`, IPMIView's only exe name) with its folder as working directory. |
| `install.cmd`, `uninstall.cmd` | Windows: `install.cmd` copies the files to `%ProgramFiles%\iKVM-KeyPasta\` as admin (whatever of jar, launcher, .ahk, exe, icons is there, checked with `fc` as a running exe can't be overwritten; `icacls /reset`; `Unblock-File`), then as the user: launcher `/register /quiet`, Start menu shortcut "IPMIView with KeyPasta.lnk" (uninstall.cmd also removes the earlier name "IPMIView (iKVM-KeyPasta).lnk") (only if `%ProgramFiles%\SUPERMICRO\IPMIView\IPMIView20.exe` exists; `%ComSpec% /c ""iKVM-IPMIView-launcher.cmd""`, project icon; the script elevates itself, the shortcut has no Run as administrator flag), a Startup-folder shortcut to the exe, else the .ahk (project icon), and starts it (skipped for an .ahk without association). Before copying, an installed exe is closed with `/exit` (else the copy of the running exe fails). Without the exe: AutoHotkey major version from the uninstall entry's `DisplayVersion` (HKLM, WOW6432Node, HKCU `...\Uninstall\AutoHotkey`); below 2: asks to run `winget install --exact --id AutoHotkey.AutoHotkey --scope machine` (UI Access needs %ProgramFiles%), checks again, else no start. At the end, if `%ProgramFiles%\OpenWebStart\javaws.exe` is missing: asks (`set /p` Y/N) to run `winget install --exact --id Karakun.OpenWebStart` (machine-scope installer, asks for admin itself), without winget only the link. `uninstall.cmd` undoes it: as the user `/unregister` + shortcut, refuses while `JAVA_TOOL_OPTIONS` (user: asks to remove it; machine: stops) points to the jar; as admin the running script closes itself (`iKVM-KeyPasta.ahk /exit`: a new instance with `/exit` only runs `CloseOtherInstances`, passed on through `RestartPrivileged`), files deleted, folder if empty. The .jnlp copies in %TEMP% stay. **Elevation always as `cmd /c ""script" args"`** (`Start-Process -Verb RunAs -FilePath $env:ComSpec`): a .cmd started directly runs as `cmd /C "script" args`, and cmd strips the first and last quote when there are more than two quotes or ( ) & in the path. Wine's `fc`, `choice` and errorlevels of `&&`/`||`/`move` are unreliable. |
| `README.md` | User docs: brief description, install, usage, then technical details at the end. Keep it in sync with the code. |
| `PPCH_outlined_*.ico` | Tray icons (dark = exe main icon, resource 159; light 300; suspended 301/302). |
| `iKVM-KeyPasta.exe` | Built by the maintainer with Ahk2Exe. Remind them to recompile after code changes. |
| `dev/` | The maintainer's old scripts. Don't touch; don't leave your own test files there. |

Don't run git in this folder.

## Code map (`iKVM-KeyPasta.ahk`, top to bottom)

1. Header, `DebugMode`, Ahk2Exe directives, configuration (`PasteHotkey`, `PasteInOtherApps`, `PasteNonAscii`, `RemoteWindows`, `JavaKeyDelay`, `JavaKeyPressDuration`, `HtmlKeyDelay`, `ConfirmCtrlAltDel`).
2. Argument parsing (`/elevate-stage=`, `/set:`), paste hotkey parsing, `CloseOtherInstances` (replaces `#SingleInstance`, works across .ahk/.exe and privilege levels; waits 10 s, then `ProcessClose`), `RestartPrivileged` (UI Access, then admin). `/exit` (install.cmd, uninstall.cmd) is checked first of all: no tray icon, hotkeys suspended, only `CloseOtherInstances`, exit code 1 if the other one is still running.
3. Window detection by title: `IsJavaKvm` (IPMIView's `Java iKVM Viewer  [ip]`, or .jnlp viewers with a version: `Java iKVM Viewer v1.69.44 [ip]`), `IsHtmlKvm`, `IsHtmlPositional` (userscript active: title contains " ⌨", browsers append their name). WinEvent hooks for activation and title changes.
4. Keyboard layouts: `QuietLayout` (load without activating), `RemoteLayout` (Swiss German/French for paste).
5. Java table trick: `TellJava` posts `WM_INPUTLANGCHANGE` with the US layout to the Java window; `WatchJavaLayout` repeats it after a manual layout change.
6. Sending: `SendKeys` (HTML5: SendInput, else SendEvent), `AltCodeDigits`, `SendAltCode` (vkE8 mask for browsers).
7. Paste: `UsKeyAtPosition` (scan code → US key code, 48 main-block keys), `UsCharAtPosition`, `PositionalKeysForChar`, `CharKeyTable`, `AskUser` (dialog), `SendClipboard`, `PasteIntoKvm`, `IsPasteKey`.
8. Ctrl+Alt+End → confirmation dialog, then Ctrl and Alt sent, Delete posted.
9. Left Ctrl hold-back (`*LCtrl`, `SendPendingCtrl`, `*LCtrl up`): drops AltGr's fake Ctrl, flushes iKVM's held Ctrl with an F24 release.
10. Java key handlers (`JavaKey`, registered for every scan code in `UsKeyAtPosition`), CapsLock tap, Alt+Tab → posted Tab.
11. HTML5 fallback without userscript (`HtmlFallbackKey`, `SwissAltGr`).
12. Tray menu, icons.

## Java agent map (`java-agent/src/keypasta/`)

- `Agent`: premain, opens `java.awt.event` (Java 9+) for the private `KeyEvent.scancode`/`rawCode`, waits for the viewer class.
- `KeyFix`: the dispatcher. Position per OS (Windows `scancode & 0xFF`, Linux `rawCode - 8`, macOS: Java gives the US key code of the position for every key but letters, digits and dead keys, whose key code comes from the character: only those mapped via `Layouts.macPositions` for the local layout), `setKeyCode(US key code)` in place; AltGr Ctrl hold-back (Windows, 20 ms, dropped if right Alt follows within 10 ms); every left Ctrl followed by a synthetic F24 release; CapsLock tap (Windows); input methods off for the viewer; drops key events with neither key code nor position; title marker.
- `Paste`: hotkey, dialog (`JOptionPane`, same texts as the AutoHotkey dialog), synthetic key events into the viewer through `KeyFix.send` (past the dispatcher), paced by `keyDelay`, Esc or focus loss stops it. Keys pressed during a paste are swallowed with their release (`swallowed`, key code * 10 + location; modifiers too, except the key repeat of ones held since before, whose release goes through); a swallowed key's key repeat after the paste takes it out again, so its release reaches the remote.
- `Layouts`: scan code → US key code, Swiss German/French tables, alt code digits. `Config`: agent options; the `paste=` key is only resolved to a key code in `KeyFix` (`resolvePaste`), as `KeyEvent`'s own code would load AWT in premain of every Java program (headless ones turned non-headless).

## Things that look wrong but are deliberate

- **US key codes via `WM_INPUTLANGCHANGE`:** Java builds its key table from the layout in the last such message, not from Windows' layout. Windows stays on the local layout.
- **ISO key sent as F21** (`vk84`): iKVM maps it to USB 100; there's no US key code for that position.
- **F24 release after left Ctrl** (`{vk87 up}`): in iKVM's stable keyboard mode a held left Ctrl is dropped when the next key goes down, but a key release sends it. F24 is never pressed; no effect on Linux or Windows remotes.
- **CapsLock as one quick tap:** lock keys only work when iKVM sends them as a single tap message (released within the Repeat Key timeout). Don't do the same for NumLock: it then never reaches Java.
- **Alt+Tab and Ctrl+Alt+Del are posted as window messages** (`PostMessage` WM_SYSKEYDOWN/WM_KEYDOWN to the focused control), never sent: Windows opens its switcher / a local Ctrl+Alt+Del even for sent keys while the modifiers are physically held.
- **Agent windows get one `WM_INPUTLANGCHANGE` with their real layout** (`RightsChecked`): nothing else is sent to them, but Alt+Tab and Ctrl+Alt+End must reach the viewer, which runs as admin. The refused message is what triggers `RestartPrivileged`.
- **Install folders:** the jar, the .ahk (with its icons) and a compiled exe belong in `%ProgramFiles%` (Linux/macOS: root-owned `/opt`): the viewer runs as admin and loads the jar, the script runs with UI Access/admin. A user-writable copy would be a way to admin rights. The README documents that setup, not the maintainer's development setup (files in their Documents folder).
- **Paste hotkey by letter, not scan code:** like Ctrl+V. The position handlers see every key first, so they call `IsPasteKey` themselves; in other programs `PasteKeyHere` catches it by scan code, as the letter hotkey never fires for a main-block key (next section). Windows with the agent or the userscript (" ⌨") get no paste hotkey from AutoHotkey at all: they paste themselves, so any combination of installed parts works.
- **Agent on the bootstrap class path (`Boot-Class-Path` in `manifest.txt`, by the jar's file name):** Java Web Start (.jnlp) runs the viewer under a security manager, on IcedTea-Web installed before premain, that gives class path code no permissions. Loaded by the bootstrap loader, the agent has all of them; `Privileged` wraps entry points (install, log, paste thread). `premain` never throws (an exception there stops the JVM, i.e. IPMIView), and `dispatchKeyEvent` passes the key on if it fails. Tested with IcedTea-Web and a signed test JNLP, and on Windows Java under Wine with a strict policy.
- **Focus loss releases what the remote has down** (agent `KeyFix.reset`, userscript `releaseAll`), Alt and Win/Cmd broken up by a Ctrl tap first (else Alt+Tab or Cmd+Tab away gives the remote a lone Alt/Win: menu bar, Start menu).
- **Agent on Windows: media and browser keys** (Windows key codes 0xA6–0xB7) keep no position: their extended scan codes' low byte is a letter's (Volume Up E0 30 = B).
- **¦ is always an alt code when pasting:** AltGr+1 on Windows' Swiss layouts, but `|` on Linux (xkb `ch`).
- **The userscript marks the title only once `UI.rfb._rfb_insydevnc` is set:** a viewer it can't handle stays with the AutoHotkey fallback.
- **The agent watches the title of every frame,** not only those already titled "Java iKVM Viewer": the .jnlp viewer opens with another title and sets the real one after connecting (the marker was missing until the paste dialog reactivated the window).
- **macOS reports no key release while Cmd is held:** the agent releases such keys when Cmd goes up, the userscript sends a key pressed with Cmd held as one tap right away (else Cmd+key would leave the key stuck on the remote, repeating), and the paste hotkey's key release is only expected until that key is pressed again.
- **`HtmlKeyDelay`:** the BMC types slower than the browser sends; without pacing the backlog freezes the viewer and keeps typing after Esc and a page reload.
- **Alt codes 160–255 with a leading 0:** works on both Windows (ANSI) and the Linux console (Unicode). Only Windows-1252 128–159 depends on `RemoteWindows`.

## AutoHotkey v2 pitfalls hit in this project

- `#Warn` is on: a local variable with the same name as a global **or a built-in function** (e.g. a loop variable `Mod`) pops a warning box at startup. Give globals distinctive names (`HtmlKeySc`, `PasteModifier`).
- `Case` is reserved (switch).
- Default parameter values must be constants (`SendNonAscii := ""`, not a global).
- `Format("{vk{:02X}}")` breaks on the braces; concatenate instead.
- **A scan code hotkey (`*SC02F`) always beats a letter hotkey (`!+v`) on the same key, even in windows where the scan code hotkey's `#HotIf` is false:** the key then just passes through. This silently broke the paste hotkey outside the Java viewer and the HTML5 fallback once every main-block key got a scan code hotkey.
- New threads are uninterruptible for their first 15 ms: a hotkey pressed meanwhile is queued, not run.
- `Sleep 10` is about 15.6 ms unless `timeBeginPeriod(1)` is active.
- A tray tooltip (`A_IconTip`) is cut at 127 characters.
- `A_MaxHotkeysPerInterval` defaults to 70 per 2 s, press and release both counted. With every key a hotkey in iKVM windows, about 18 keys/s trips it and AutoHotkey stops with a warning box (measured). Keep it raised.
- UIPI: a normal-rights process can't post to or close a UI Access/admin one (hence `RestartPrivileged`).

## Testing

Check by machine first; ask the maintainer to test only what needs the real Java app, iKVM, the BMC or Windows' own key handling.

1. **Load check under Wine** (catches syntax errors and `#Warn` warnings):
   ```
   apt-get install -y wine64 wine xvfb
   # AutoHotkey v2 portable: github.com/AutoHotkey/AutoHotkey/releases (AutoHotkey64.exe)
   sed 's/^#Warn  /#Warn All, StdOut ;/' iKVM-KeyPasta.ahk > check.ahk
   WINEDEBUG=-all wine AutoHotkey64.exe /ErrorStdOut /validate check.ahk
   ```
2. **Simulation under Wine + Xvfb:** a harness script creates a GUI titled like the viewer (`Java iKVM Viewer  [x]  `, or `Resolution:1024x768 FPS :30` for HTML5), logs `WM_KEYDOWN/UP/SYSKEYDOWN/SYSKEYUP` via `OnMessage`, then `#Include`s the script. A **separate** AutoHotkey process sends the keys with `SendLevel 1` and realistic `SetKeyDelay` (same-process sending queues all hotkeys until the Send ends and gives false results). Separate cases with an unhooked key (F13) and send it with `{Blind}`. Log to a file, not stdout. Wine only does a US local layout and no real Java/iKVM.
3. **Java agent:** a stand-in viewer (`tw.com.aten.ikvm.ui.RemoteVideo extends JPanel`, logging `KeyMap.VKtoHID(keyCode, location)` from the real iKVM jar on the classpath) in a `JFrame` titled `Java iKVM Viewer  [x]  `, run with `-javaagent:`. Physical keys: Xvfb + openbox (focus needs a window manager) + `setxkbmap ch`, keys injected as raw X keycodes with python-xlib XTest (xdotool types by keysym through the US map and misleads). Linux: Java 8, 17, 21 from apt. Windows: Temurin Windows JREs from GitHub releases under Wine (`setxkbmap ch -option lv3:ralt_alt` and LCtrl+RAlt pressed together to imitate Windows' AltGr). Clipboard with `xclip`. Focus changes: a second window (`xmessage`) activated with xdotool. Java Web Start: IcedTea-Web (`icedtea-netx`, Java 8 via `JAVA_HOME`) with a self-signed all-permissions test JNLP of the stand-in viewer; the Debian GNOME accessibility bridge breaks it in the container (comment out `assistive_technologies` in `/etc/java-8-openjdk/accessibility.properties`). Wine's own AltGr and openbox's Alt+Tab aren't representative. macOS can't be tested here.
4. **Userscript:** Playwright Chromium (`/opt/npm-tools/node_modules/playwright`) on a local page with a fake `UI.rfb` and `RFB.messages.keyEventInsyde` that log USB codes, plus a `document` keydown listener standing in for noVNC's own handler (keys must never reach it); clipboard permissions granted to the origin. macOS via `navigator.platform` overridden in an init script.
5. **Hand tests:** one list, numbered. Numbers are never reused or renumbered; new checks get new numbers (last used: 114; 104-114 is the release check for 2.0.0 and replaces the open ones before it). Say which remote (Debian CH, Debian US, Windows) and viewer each test runs on, have each check typed on its own line in `cat` on the remote console, and state the expected output exactly. Name keys by what's printed on them; write "Dollar key", never the symbol. Be explicit (e.g. "the key right of 0 in the number row", not "the key right of 0").

## Working with the maintainer

- Ask right away for anything you need; don't assume their setup.
- An unexplained test result is most likely a test mistake: give clear instructions to repeat it rather than guessing at a bug.
- Derive from logic and test by machine before asking for hand tests; keep hand-test lists short.
- Don't claim "all tests done" or "dead code gone" without checking (scan for unused functions/variables, re-validate).
