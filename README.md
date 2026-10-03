# iKVM-SwissBugPasta

Makes the keyboard work properly in the Supermicro/ATEN iKVM remote console (Java app and HTML5 browser viewer), whatever the local keyboard layout (made for Swiss ones, hence the name), and adds pasting the clipboard with `Alt+Shift+V`.  
Every key arrives at its physical position on the remote, so the remote's keyboard layout decides what it types, as if your keyboard were plugged into the server: AltGr, dead keys and shortcuts included.

## Installation

1. Install [AutoHotkey](https://www.autohotkey.com/) v2 and run `iKVM-SwissBugPasta.ahk` (or compile it into an exe yourself, I will not publish executable binaries).
2. Recommended for the HTML5 viewer: install the userscript `iKVM-HTML5-positional.user.js` ("Supermicro IPMI / ATEN BMC keyboard fix"):
   - Install [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/) in Firefox or Chrome.
   - Open the `.user.js` file with the extension, or paste its content into a new script.
   - Chrome 138 and newer: enable "Allow User Scripts" in the extension's details page (older Chrome: developer mode), otherwise the userscript silently doesn't run.
   - Reload open viewer pages after installing, enabling or disabling the userscript.

   The userscript also works on its own, without AutoHotkey. AutoHotkey without the userscript works too, with limitations (see below).

## Usage

Keep the script running and type as usual. It only acts in iKVM windows:

- Java app: windows titled `Java iKVM Viewer [...]`
- HTML5 viewer: tabs titled `Resolution:... FPS :...` (with the userscript active, the title ends with ⌨)

**Paste:** `Alt+Shift+V` (configurable: `PasteHotkey` at the top of the script, by letter like Ctrl+V) types the clipboard into the remote, for a Swiss layout on the remote. If the result is garbled (the remote uses another layout), turn CapsLock on and paste again (safe paste): slower, but works with any layout, as everything is sent as alt codes. Turn CapsLock off again afterwards (it toggles on the remote, too). A running paste stops when you switch to another window or press Esc. If the text has line breaks or AltGr characters (harmful on a non-Swiss remote) or characters that aren't on the keyboard (typed slowly as Alt + number), you're asked first: fast paste, safe paste or cancel (tray menu "Non-ASCII characters" to never ask about the latter). In other programs, `Alt+Shift+V` pastes plain text (can be turned off in the tray menu).

**Ctrl+Alt+End** (left Alt) sends Ctrl+Alt+Del to the remote, as in Remote Desktop: the real one always goes to the local Windows. It asks first (Cancel is the default), as on a Linux console Ctrl+Alt+Del reboots the server right away. The dialog's "Don't ask again for 4 hours" turns the question off for a while; `ConfirmCtrlAltDel := false` at the top of the script turns it off for good.

**Alt+Tab** in the Java app goes to the remote, like the other keys. To switch windows locally, use Win+Tab or the mouse. (The HTML5 viewer can't get it: there, Alt+Tab switches locally.)

**Tray menu:**
- Remote OS: Linux console or Windows, only matters for alt codes of € and the other Windows-1252 special characters (curly quotes, dashes, ...)
- Non-ASCII characters: ask, always include or always omit them when pasting
- Suspend hotkeys: everything off, the iKVM windows get their original behaviour back

Java viewer options: leave "Keyboard layout" at its default (English), and don't set "Repeat Key timeout" to 0 ms (default 200 ms): lock keys (CapsLock, NumLock, ScrollLock) don't reach the remote then.

## What works where

| | Java app | HTML5 with userscript | HTML5 without userscript |
|---|---|---|---|
| Keys by position (plain, Shift) | ✓ | ✓ | ✓ (ISO key `< >` as alt codes) |
| AltGr on the remote | ✓ | ✓ | alt codes only |
| Dead keys, shortcuts | ✓ | ✓ | without AltGr only |
| Numpad decimal | ✓ | ✓ | arrives as full stop |
| Paste | ✓ | ✓ | ✓ (AltGr characters as alt codes) |
| Ctrl+Alt+Del on the remote (Ctrl+Alt+End) | ✓ | ✓ | ✓ |
| Alt+Tab on the remote | ✓ | – | – |

Alt codes only type characters: they don't work for shortcuts or dead keys, on Windows not in every program, and Unicode beyond Latin-1 depends entirely on the remote.

Alt codes only exist on the Linux console and on Windows:

- BIOS/UEFI setup, boot loaders and Linux desktops (X11, Wayland) don't know them: safe paste types nothing there, and a normal paste leaves out the characters that aren't on the keyboard. A BIOS uses a US layout, so a normal paste there swaps y/z and garbles symbols: type such things by hand.
- Windows only reads them with NumLock on (on the remote): with NumLock off, the numpad digits arrive as arrow keys, Home, End etc.

## Technical details

### Java app

The Java app doesn't forward key positions. It turns each Windows key code into a Java key code, via the character the key produces on the *local* layout, and looks that up in a fixed US table. With a Swiss layout several positions (`^`, `¨`, `$`, `-`) can't be reached at all, AltGr arrives with an extra Ctrl, and Y/Z are swapped.

The fix: the Java runtime builds its key table from the layout named in the last `WM_INPUTLANGCHANGE` message it received. The script sends it such a message naming the US layout whenever an iKVM Java window becomes active (and again after a layout change). Windows stays on the Swiss layout, only Java's table changes. The script then sends each physical key of the main block as the US key code of that position, whatever the local layout (the ISO key as F21, which iKVM maps there), and drops the extra Ctrl Windows adds to AltGr. On suspend and exit, Java gets its real table back.

If the US layout isn't loaded, it's loaded in the background (not activated, not shown in the language bar) and unloaded on exit.

Lock keys only work on the remote when iKVM sends them as one press+release message, which it only does for keys released within its "Repeat Key timeout" (stable keyboard mode, default on, 200 ms). The script therefore sends every CapsLock press as one quick tap (NumLock and ScrollLock: press them briefly). In the same mode, a pressed key is held back until the next key goes down, except left Ctrl, which is dropped then. A key release however sends it: so left Ctrl is followed by the release of F24 (never pressed: no effect on Linux or Windows remotes).

Windows opens its task switcher for every Alt+Tab, even one sent by a program, before the Java app sees it. So the script blocks the Tab and posts it to the Java window directly as a window message. Ctrl+Alt+End works the same way: a Delete sent while Ctrl and Alt are held would still make a local Ctrl+Alt+Del, so after the confirmation, Ctrl and Alt are sent and the Delete is posted to the viewer window (Java app and browser).

The viewer's own "Keyboard layout" setting would change things too (Germany: Y/Z and minus), but it's stored per BMC; "Swiss" in that list has no effect at all on typing.

### HTML5 viewer

The viewer (an old noVNC) turns the typed *character* into the US key position of that character (`ast2100.js`), sends only left-hand modifiers and never AltGr, and has nothing for the ISO key.

- **With the userscript:** it replaces the viewer's keyboard handling and sends the browser's physical key position (`event.code`) as USB key code, right Alt and ISO key included. It appends ` ⌨` to the page title, so the script knows it's there and leaves the keys alone.
- **Without:** the script sends, for each key, the character US has at that position (as Unicode), so the viewer maps it back to the right position. AltGr characters and the ISO key go as alt codes, as the viewer can't send them.

### Paste

Each character is typed with the key that produces it on the remote's layout (assumed to be the local Swiss layout, Swiss German if the local one isn't Swiss), sent the same way as typed keys. If a character is on several keys, the one with the fewest modifiers wins. Dead-key characters and everything not on the keyboard are sent as alt codes (`Alt`+numpad):

- Windows reads `Alt+nnn` as OEM code page and `Alt+0nnn` as ANSI, the Linux console reads both as Unicode. 160-255 always get the leading 0 and work on both, only the Windows-1252 characters 128-159 differ (tray menu: Remote OS).
- Line breaks are sent as one Enter each.

Safe paste (CapsLock on): everything as alt codes except line breaks, Tab and Space (keys that are the same on every layout).

Speed: the Java app paces the keys itself (`JavaKeyDelay`, `JavaKeyPressDuration` at the top of the script). The HTML5 viewer takes keys much faster than the BMC types them: the rest would pile up in the BMC, freeze the viewer and keep typing after Esc. So the paste waits `HtmlKeyDelay` (10 ms) per keystroke there.

### Admin rights

Windows refuses keystrokes and messages to programs running as admin (the iKVM Java app may), unless the script has UI Access or runs as admin itself. When that happens, the script restarts itself with UI Access (`AutoHotkey*_UIA.exe`, part of the AutoHotkey installation), or else as admin (UAC prompt). If that's declined, a notification says so, and the first entry of the tray menu tries again.

Starting the script again closes the running one, whether .ahk or compiled exe, from any folder (both would remap the keys). If the running one has such rights, it's closed the same way: the new one first restarts itself with the same rights (Windows doesn't let a normal process close it).

A compiled exe gets UI Access if it's signed and placed in a protected folder like `%ProgramFiles%`. With a self-signed certificate (PowerShell):

```
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=My AHK UIAccess" -CertStoreLocation Cert:\CurrentUser\My
$tmp = "$env:TEMP\ahk_uia.cer"
Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Remove-Item $tmp
$installedcert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Subject -eq "CN=My AHK UIAccess"
Set-AuthenticodeSignature -FilePath "iKVM-SwissBugPasta.exe" -Certificate $installedcert
```

### Debug mode

`DebugMode := true` in the script records key history, executed lines and a log of the messages to the Java app, viewable from the tray menu. Never leave it on: the key history contains passwords.

## Licenses

### App icons `PPCH*.ico`
Based on the [logo of the Pirate Party Switzerland](https://www.piratenpartei.ch/logos-und-fotos/). Slightly modified by myself.
License: [CC BY 3.0 CH](https://creativecommons.org/licenses/by/3.0/ch/)
