# AGENTS.md

Notes for AI agents working on iKVM-SwissBugPasta. Read this before changing anything; `README.md` is the user documentation.

## What this is

An AutoHotkey v2 script plus an optional userscript that make the keyboard in the Supermicro/ATEN iKVM remote consoles (Java app and HTML5 browser viewer) behave like a keyboard plugged into the server: every key arrives at its physical position, the remote's layout decides what it types. It also pastes the clipboard (`Alt+Shift+V`), sends Ctrl+Alt+Del (`Ctrl+Alt+End`) and Alt+Tab (Java) to the remote.

## Hard constraints

- **Never require changing the iKVM "Keyboard layout" setting.** It stays English on thousands of BMCs.
- **Never require changing the local input layout,** and don't assume the maintainer's custom layouts: coworkers use the standard Swiss layout. Typing must work with any local layout.
- **Knowing or configuring the remote's layout is not feasible.** Fast paste assumes Swiss; safe paste (CapsLock on) works with any layout.
- **No test-only triggers in the shipped script** (e.g. activating things with F-keys). Experiments go behind `DebugMode`.
- **`DebugMode` must be `false` in anything handed out:** the key history records passwords.

## Files

| File | Notes |
| --- | --- |
| `iKVM-SwissBugPasta.ahk` | The script. UTF-8 **with BOM**, **CRLF**, 4 spaces (no tabs). Edit in place with a read-modify-write that keeps BOM and CRLF. |
| `iKVM-HTML5-positional.user.js` | Userscript for the HTML5 viewer. Bump `@version` on every change. |
| `README.md` | User docs: brief description, install, usage, then technical details at the end. Keep it in sync with the code. |
| `PPCH_outlined_*.ico` | Tray icons (dark = exe main icon, resource 159; light 300; suspended 301/302). |
| `iKVM-SwissBugPasta.exe` | Built by the maintainer with Ahk2Exe. Remind them to recompile after code changes. |
| `dev/` | The maintainer's old scripts. Don't touch; don't leave your own test files there. |

Don't run git in this folder.

## Code map (`iKVM-SwissBugPasta.ahk`, top to bottom)

1. Header, `DebugMode`, Ahk2Exe directives, configuration (`PasteHotkey`, `PasteInOtherApps`, `PasteNonAscii`, `RemoteWindows`, `JavaKeyDelay`, `JavaKeyPressDuration`, `HtmlKeyDelay`, `ConfirmCtrlAltDel`).
2. Argument parsing (`/elevate-stage=`, `/set:`), paste hotkey parsing, `CloseOtherInstances` (replaces `#SingleInstance`, works across .ahk/.exe and privilege levels), `RestartPrivileged` (UI Access, then admin).
3. Window detection by title: `IsJavaKvm`, `IsHtmlKvm`, `IsHtmlPositional` (userscript active: title ends with " ⌨"). WinEvent hooks for activation and title changes.
4. Keyboard layouts: `QuietLayout` (load without activating), `RemoteLayout` (Swiss German/French for paste).
5. Java table trick: `TellJava` posts `WM_INPUTLANGCHANGE` with the US layout to the Java window; `WatchJavaLayout` repeats it after a manual layout change.
6. Sending: `SendKeys` (HTML5: SendInput, else SendEvent), `AltCodeDigits`, `SendAltCode` (vkE8 mask for browsers).
7. Paste: `UsKeyAtPosition` (scan code → US key code, 48 main-block keys), `UsCharAtPosition`, `PositionalKeysForChar`, `CharKeyTable`, `AskUser` (dialog), `SendClipboard`, `PasteIntoKvm`, `IsPasteKey`.
8. Ctrl+Alt+End → confirmation dialog, then Ctrl and Alt sent, Delete posted.
9. Left Ctrl hold-back (`*LCtrl`, `SendPendingCtrl`, `*LCtrl up`): drops AltGr's fake Ctrl, flushes iKVM's held Ctrl with an F24 release.
10. Java key handlers (`JavaKey`, registered for every scan code in `UsKeyAtPosition`), CapsLock tap, Alt+Tab → posted Tab.
11. HTML5 fallback without userscript (`HtmlFallbackKey`, `SwissAltGr`).
12. Tray menu, icons.

## Things that look wrong but are deliberate

- **US key codes via `WM_INPUTLANGCHANGE`:** Java builds its key table from the layout in the last such message, not from Windows' layout. Windows stays on the local layout.
- **ISO key sent as F21** (`vk84`): iKVM maps it to USB 100; there's no US key code for that position.
- **F24 release after left Ctrl** (`{vk87 up}`): in iKVM's stable keyboard mode a held left Ctrl is dropped when the next key goes down, but a key release sends it. F24 is never pressed; no effect on Linux or Windows remotes.
- **CapsLock as one quick tap:** lock keys only work when iKVM sends them as a single tap message (released within the Repeat Key timeout). Don't do the same for NumLock: it then never reaches Java.
- **Alt+Tab and Ctrl+Alt+Del are posted as window messages** (`PostMessage` WM_SYSKEYDOWN/WM_KEYDOWN to the focused control), never sent: Windows opens its switcher / a local Ctrl+Alt+Del even for sent keys while the modifiers are physically held.
- **Paste hotkey by letter, not scan code:** like Ctrl+V. The position handlers see every key first, so they call `IsPasteKey` themselves; everywhere else (other programs, HTML5 with the userscript) `PasteKeyHere` catches it by scan code, as the letter hotkey never fires for a main-block key (next section).
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
   sed 's/^#Warn  /#Warn All, StdOut ;/' iKVM-SwissBugPasta.ahk > check.ahk
   WINEDEBUG=-all wine AutoHotkey64.exe /ErrorStdOut /validate check.ahk
   ```
2. **Simulation under Wine + Xvfb:** a harness script creates a GUI titled like the viewer (`Java iKVM Viewer  [x]  `, or `Resolution:1024x768 FPS :30` for HTML5), logs `WM_KEYDOWN/UP/SYSKEYDOWN/SYSKEYUP` via `OnMessage`, then `#Include`s the script. A **separate** AutoHotkey process sends the keys with `SendLevel 1` and realistic `SetKeyDelay` (same-process sending queues all hotkeys until the Send ends and gives false results). Separate cases with an unhooked key (F13) and send it with `{Blind}`. Log to a file, not stdout. Wine only does a US local layout and no real Java/iKVM.
3. **Hand tests:** one list, numbered. Numbers are never reused or renumbered; new checks get new numbers (last used: 72). Say which remote (Debian CH, Debian US, Windows) and viewer each test runs on, have each check typed on its own line in `cat` on the remote console, and state the expected output exactly. Name keys by what's printed on them; write "Dollar key", never the symbol. Be explicit (e.g. "the key right of 0 in the number row", not "the key right of 0").

## Working with the maintainer

- Ask right away for anything you need; don't assume their setup.
- An unexplained test result is most likely a test mistake: give clear instructions to repeat it rather than guessing at a bug.
- Derive from logic and test by machine before asking for hand tests; keep hand-test lists short.
- Don't claim "all tests done" or "dead code gone" without checking (scan for unused functions/variables, re-validate).
