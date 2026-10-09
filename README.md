# The iKVM-KeyPasta Project

Makes the keyboard work properly in the Supermicro/ATEN iKVM remote console (Java app and HTML5 browser viewer). Regardless of local or remote keyboard layout, keypresses arrive as typed on your physical keyboard, even dead keys and AltGr. Adds pasting from local clipboard with `Alt+Shift+V` (macOS: `⇧⌘C`).  

Mix and match any of the three parts:

- **`iKVM-KeyPasta.ahk`** (AutoHotkey v2, Windows only): simple and well tested script for both viewers, but less well integrated. Keystrokes may come out imperfect. AHK needs admin rights to install. The script runs with UI Access through the AutoHotkey installation instead of as admin. Also adds Ctrl+Alt+Del to the remote, Alt+Tab in the Java app, and the paste shortcut works in other programs than iKVM, too.

- **`iKVM-KeyPasta.user.js`** (userscript for HTML5 viewer): fixes the problems at their source, inside the viewer. Any browser with Tampermonkey or Violentmonkey, any system. No admin rights needed.

- **`iKVM-KeyPasta-agent.jar`** (Java agent with support for IPMIView and .jnlp files): fixes the problems at their source, inside the viewer. Windows, Linux and macOS. Needs admin rights to install.

Where the agent or the userscript is active, the AutoHotkey script leaves that viewer to it and only adds Ctrl+Alt+Del (and Alt+Tab in the Java app).


## Quick install

On Windows, run `install.cmd` (requires Admin elevation). It copies the available files to `%ProgramFiles%\iKVM-KeyPasta\`, registers the jnlp-launcher, puts the AHK in autostart and starts it. It also creates a new shortcut in the start menu that starts IPMIView with the java agent as administrator. 
It asks to install AutoHotkey v2 and OpenWebStart, but does not import the userscript to your browser. Associating .jnlp files to open with the jnlp-launcher also is a manual task.

Linux and Mac users are on their own for now. I expect Linux users to be savvy enough to hack a launcher for IPMIView or jnlp files themselves.  
I did not test any of this on macOS. But it's probably not hard to create an Automator/AppleScript to open jnlp files with or start IPMIView with the correct environment.


## Manual installation

### AutoHotkey (Windows only)

 - Install [AutoHotkey](https://www.autohotkey.com/) v2, e.g. via `winget install AutoHotkey.AutoHotkey --scope machine`
 
 - Copy `iKVM-KeyPasta.ahk` and the `PPCH_outlined_*.ico` files to `%ProgramFiles%\iKVM-KeyPasta\` and run it from there.  
   It runs with UI Access, which can control programs running as admin: in a folder you can write to, any program running as you could change the script and so get that control.  

   - Alternatively, compile it into an exe yourself (I will not publish executable binaries), and put that there instead.  
   Windows only grants UI Access to an exe in a protected folder (see [Admin rights](#admin-rights)).

### HTML5 viewer userscript

 - Install [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/) in Firefox or Chrome.

 - Import the `iKVM-KeyPasta.user.js` file in the extension's dashboard (Tampermonkey: Utilities, Import from file), or create a new script there and paste the file's content.

 - Chrome 138 and newer: enable "Allow User Scripts" in the extension's details page (older Chrome: developer mode), otherwise the userscript silently doesn't run.

 - Reload open viewer pages after installing. If the viewer tab's title ends with ⌨, the script works.

### Java agent

 - Copy `iKVM-KeyPasta-agent.jar` to a protected location on your system. Usually `%ProgramFiles%\iKVM-KeyPasta\` or `/opt/iKVM-KeyPasta/`.  

   The viewer will run as admin (on Windows at least) and load the jar. In a folder you can write to, any program running as you could replace it and get admin rights.  

 - To load the agent with iKVM, set the environment variable `JAVA_TOOL_OPTIONS` to `-javaagent:` followed by the full path of `iKVM-KeyPasta-agent.jar`.   
   If the viewer is not started as admin, it will request admin elevation and not work otherwise. This elevation will use a new environment which may not have the variable, so either:

   - Set the environment permanently. Simplest, but caveat: 
   ***Remember*** to **remove this variable** before deleting or moving the `iKVM-KeyPasta-agent.jar`!  
   An inaccessible path in -javaagent will cause *any* Java program to *silently* not start anymore.  

   - Set the envvar in an elevated environment and start the viewer (via IPMIView or OpenWebStart) from there.  

   - Recommended on Windows: Just use the `IPMIView with KeyPasta` start menu shortcut and associate .jnlp files to open with the provided launcher.

 - If the viewer's title ends with ⌨, the agent is loaded.

### .jnlp files: OpenWebStart

Java 11 and newer no longer come with a program for .jnlp files (`javaws`). [OpenWebStart](https://openwebstart.com/download/) runs them on Windows, macOS and Linux, and downloads the Java it needs itself.

1. Download and install it.
2. Make it use Java 8: the .jnlp files ask for Java options that Java 17 and newer refuse ("Unrecognized VM option 'PermSize=32M'"). Add this line to `deployment.properties` (create the file if it doesn't exist) in `%USERPROFILE%\.config\icedtea-web\` on Windows, `~/.config/icedtea-web/` on macOS and Linux:
   ```
   ows.jvm.manager.versionRange=1.8*
   ```
3. Windows: add OpenWebStart's folder (usually `C:\Program Files\OpenWebStart`) to your `PATH`, otherwise starting a .jnlp fails with something like "javaws not found" (the jnlp launcher tries to fix that).  

Notes:

- Apple Silicon Macs: the .jnlp brings the viewer's native library only for Intel Macs. If the viewer doesn't start, it probably needs an Intel Java 8 (runs through Rosetta 2).
- Current Java 8 refuses TLS 1.0 and 1.1. If an old BMC fails with "connection failed", enable them again for that Java (`jdk.tls.disabledAlgorithms` in its `java.security`).

### Java iKVM viewer setup

The Java iKVM viewer comes either from IPMIView or as a `.jnlp` file from the BMC's web interface. You probably don't need to change anything in it.

 * Leave "Keyboard layout" at its default (English). Surprisingly, this setting may be saved and read from the remote machine.
 * Don't set "Repeat Key timeout" to 0 ms (default 200 ms): lock keys (CapsLock, NumLock, ScrollLock) don't reach the remote then.
 * Because the AHK script captures Alt+Tab, you may want to remember what hotkey "Exit Remote Location" is bound to (default is `F2`). 


### Open .jnlp files with the custom handler

Run `iKVM-jnlp-launcher.cmd /register` (not as admin) and in the right-click -> "Open with" dialog make it the default launcher for all .jnlp files.  

It takes care of elevation and setting the environment, and keeps your Downloads directory clean of iKVM's launch.jnlp files by moving them to the `%TEMP%\iKVM-KeyPasta` directory.  

  `/unregister` removes it again.

If you just start the cmd file (without arguments) it will do the same, but only with the launch.jnlp in your Downloads directory.


## Usage

Type as usual. Everything only acts in iKVM windows:

- Java app: windows titled `Java iKVM Viewer [...]` or `Java iKVM Viewer v1.69.44 [...]` (with the agent active, the title ends with ⌨)
- HTML5 viewer: tabs titled `Resolution:... FPS :...` (with the userscript active, the title ends with ⌨)

**Paste:** `Alt+Shift+V`, on macOS `Cmd+Shift+V` (configurable, by letter like Ctrl+V: `PasteHotkey` in the AutoHotkey script, `paste=` for the agent) types the clipboard into the remote, for a Swiss layout on the remote. If the result is garbled (the remote uses another layout), turn CapsLock on and paste again (safe paste): slower, but works with any layout, as everything is sent as alt codes. Turn CapsLock off again afterwards (it toggles on the remote, too). A running paste stops when you switch to another window or press Esc. If the text has line breaks or AltGr characters (harmful on a non-Swiss remote) or characters that aren't on the keyboard (typed slowly as Alt + number), you're asked first: fast paste, safe paste or cancel (tray menu "Non-ASCII characters" to never ask about the latter). In other programs, `Alt+Shift+V` pastes plain text (AutoHotkey; can be turned off in the tray menu). Where the agent or the userscript is active, it pastes itself, with the same dialog (AutoHotkey leaves the hotkey to it); without them, AutoHotkey pastes. The userscript needs the BMC opened with `https://` (browsers give the clipboard to secure pages only), and the browser may ask for permission to read it (Firefox shows a small "Paste" button each time).

**Ctrl+Alt+End** (left Alt, AutoHotkey) sends Ctrl+Alt+Del to the remote, as in Remote Desktop: the real one always goes to the local Windows. It asks first (Cancel is the default), as on a Linux console Ctrl+Alt+Del reboots the server right away. The dialog's "Don't ask again for 4 hours" turns the question off for a while; `ConfirmCtrlAltDel := false` at the top of the script turns it off for good.

**Alt+Tab** in the Java app goes to the remote (AutoHotkey), like the other keys. To switch windows locally, use Win+Tab or the mouse. (The HTML5 viewer can't get it: there, Alt+Tab switches locally.)

**Tray menu** (AutoHotkey):
- Remote OS: Linux console or Windows, only matters for alt codes of € and the other Windows-1252 special characters (curly quotes, dashes, ...)
- Non-ASCII characters: ask, always include or always omit them when pasting
- Alt+Shift+V pastes in: any window (plain text in other programs) or iKVM windows only
- Suspend hotkeys: everything off, the iKVM windows get their original behaviour back

### Advanced configuration

**Agent options:** `-javaagent:...jar=name=value,name=value`: `paste=alt+shift+V` (hotkey; default on macOS `cmd+shift+V`), `pasteNonAscii=ask` (`always`, `never`), `remoteOs=linux` (`windows`), `remoteLayout=auto` (`de-CH`, `fr-CH`; auto: the local one if Swiss French, else Swiss German), `localLayout=auto` (macOS only: `de-CH`, `fr-CH`, `us`; auto: from the input language, or the system's region if that has none), `keyDelay=2` (ms per key when pasting), `log=path` (debug log). Unknown options and values are ignored with a message on the console.

**Userscript settings** (at the top of the script): `REMOTE_LAYOUT` (`"de-CH"` or `"fr-CH"`, for fast paste), `PASTE_NON_ASCII` (`"ask"`, `"always"`, `"never"`), `KEY_DELAY` (ms per keystroke when pasting), `remoteWindows` (`false`: Linux console, `true`: Windows, only matters for alt codes of € and the other Windows-1252 special characters; can also be changed in the paste dialog). Its paste hotkey is fixed: `Alt+Shift+V`, on macOS `Cmd+Shift+V`.

**Launcher settings** (top of iKVM-jnlp-launcher.cmd): `JNLP` (file used when started without one), `OWS` (OpenWebStart folder), `JAVAVERSION` (Java version for the viewer, default `1.8*`, empty: as the .jnlp asks).


## What works where

| | Java app with agent | Java app, AutoHotkey only | HTML5 with userscript | HTML5, AutoHotkey only |
|---|---|---|---|---|
| Keys by position (plain, Shift) | ✓ | ✓ | ✓ | ✓ (ISO key `< >` as alt codes) |
| AltGr on the remote | ✓ | ✓ | ✓ | alt codes only |
| Dead keys, shortcuts | ✓ | ✓ | ✓ | without AltGr only |
| Numpad decimal | ✓ | ✓ | ✓ | arrives as full stop |
| Paste | ✓ | ✓ | ✓ | ✓ (AltGr characters as alt codes) |
| Ctrl+Alt+Del on the remote (Ctrl+Alt+End) | with AutoHotkey | ✓ | with AutoHotkey | ✓ |
| Alt+Tab on the remote | with AutoHotkey | ✓ | – | – |
| Local system | Windows, Linux, macOS | Windows | any | Windows |

Alt codes only type characters: they don't work for shortcuts or dead keys, on Windows not in every program, and Unicode beyond Latin-1 depends entirely on the remote.

Alt codes only exist on the Linux console and on Windows:

- BIOS/UEFI setup, boot loaders and Linux desktops (X11, Wayland) don't know them: safe paste types nothing there, and a normal paste leaves out the characters that aren't on the keyboard. A BIOS uses a US layout, so a normal paste there swaps y/z and garbles symbols: type such things by hand.
- Windows only reads them with NumLock on (on the remote): with NumLock off, the numpad digits arrive as arrow keys, Home, End etc.


## Technical details

### Java app

The Java app doesn't forward key positions. It turns each Windows key code into a Java key code, via the character the key produces on the *local* layout, and looks that up in a fixed US table. With a Swiss layout several positions (`^`, `¨`, `$`, `-`) can't be reached at all, AltGr arrives with an extra Ctrl, and Y/Z are swapped.

**With the agent:** a `KeyEventDispatcher` sees every key event before the viewer and gives each key of the main block the US key code of its physical position, so iKVM's US table turns it into exactly that position. The position comes from Java's key event: the scan code on Windows, the X keycode on Linux. macOS doesn't pass it to Java, but gives every key except letters and digits the US key code of its position anyway. For letters and digits the agent derives the position with a known local layout (Swiss German, Swiss French or US, see `localLayout=` above; untested so far), and maps Command to the remote's Windows key. Input methods are switched off for the viewer (on Linux they swallowed dead keys). The rest works as described below for AutoHotkey, inside Java: the AltGr Ctrl dropped, left Ctrl followed by an F24 release, CapsLock as one tap (Windows), paste with key events into the viewer. Nothing in iKVM is changed, so any viewer version works as long as its key class is `tw.com.aten.ikvm.ui.RemoteVideo`.

**AutoHotkey only:** the Java runtime builds its key table from the layout named in the last `WM_INPUTLANGCHANGE` message it received. The script sends it such a message naming the US layout whenever an iKVM Java window becomes active (and again after a layout change). Windows stays on the Swiss layout, only Java's table changes. The script then sends each physical key of the main block as the US key code of that position, whatever the local layout (the ISO key as F21, which iKVM maps there), and drops the extra Ctrl Windows adds to AltGr. On suspend and exit, Java gets its real table back.

If the US layout isn't loaded, it's loaded in the background (not activated, not shown in the language bar) and unloaded on exit.

Lock keys only work on the remote when iKVM sends them as one press+release message, which it only does for keys released within its "Repeat Key timeout" (stable keyboard mode, default on, 200 ms). The script therefore sends every CapsLock press as one quick tap (NumLock and ScrollLock: press them briefly). In the same mode, a pressed key is held back until the next key goes down, except left Ctrl, which is dropped then. A key release however sends it: so left Ctrl is followed by the release of F24 (never pressed: no effect on Linux or Windows remotes).

Windows opens its task switcher for every Alt+Tab, even one sent by a program, before the Java app sees it. So the script blocks the Tab and posts it to the Java window directly as a window message. Ctrl+Alt+End works the same way: a Delete sent while Ctrl and Alt are held would still make a local Ctrl+Alt+Del, so after the confirmation, Ctrl and Alt are sent and the Delete is posted to the viewer window (Java app and browser).

The viewer's own "Keyboard layout" setting would change things too (Germany: Y/Z and minus), but it's stored per BMC; "Swiss" in that list has no effect at all on typing.

### HTML5 viewer

The viewer (an old noVNC) turns the typed *character* into the US key position of that character (`ast2100.js`), sends only left-hand modifiers and never AltGr, and has nothing for the ISO key.

- **With the userscript:** it replaces the viewer's keyboard handling and sends the browser's physical key position (`event.code`) as USB key code, right Alt and ISO key included. It appends ` ⌨` to the page title, so the script knows it's there and leaves the keys alone.
- **Without:** the script sends, for each key, the character US has at that position (as Unicode), so the viewer maps it back to the right position. AltGr characters and the ISO key go as alt codes, as the viewer can't send them.

### Paste

The agent and the userscript paste the same way as the AutoHotkey script, from inside the viewer. Each character is typed with the key that produces it on the remote's layout, sent the same way as typed keys. That layout is assumed to be the local one if it's Swiss, otherwise Swiss German (agent: `remoteLayout=`; userscript: Swiss German unless `REMOTE_LAYOUT` says otherwise). If a character is on several keys, the one with the fewest modifiers wins. Dead-key characters and everything not on the keyboard are sent as alt codes (`Alt`+numpad):

- Windows reads `Alt+nnn` as OEM code page and `Alt+0nnn` as ANSI, the Linux console reads both as Unicode. 160-255 always get the leading 0 and work on both, only the Windows-1252 characters 128-159 differ (tray menu: Remote OS).
- Line breaks are sent as one Enter each.

Safe paste (CapsLock on): everything as alt codes except line breaks, Tab and Space (keys that are the same on every layout).

Speed: the Java app paces the keys itself (`JavaKeyDelay`, `JavaKeyPressDuration` at the top of the script). The HTML5 viewer takes keys much faster than the BMC types them: the rest would pile up in the BMC, freeze the viewer and keep typing after Esc. So the paste waits `HtmlKeyDelay` (10 ms) per keystroke there (userscript: `KEY_DELAY`).

### Admin rights

Windows refuses keystrokes and messages to programs running as admin (the iKVM Java app may), unless the script has UI Access or runs as admin itself. When that happens, the script restarts itself with UI Access (`AutoHotkey*_UIA.exe`, part of the AutoHotkey installation), or else as admin (UAC prompt). If that's declined, a notification says so, and the first entry of the tray menu tries again.

Starting the script again closes the running one, whether .ahk or compiled exe, from any folder (both would remap the keys). If the running one has such rights, it's closed the same way: the new one first restarts itself with the same rights (Windows doesn't let a normal process close it).

A compiled exe requesting UI Access in its manifest only gets UIA granted when it's located in a protected folder like `%ProgramFiles%` and is signed. Example for signing and trusting a self-signed certificate (PowerShell):

```
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=My AHK UIAccess" -CertStoreLocation Cert:\CurrentUser\My
$tmp = "$env:TEMP\ahk_uia.cer"
Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Remove-Item $tmp
$installedcert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Subject -eq "CN=My AHK UIAccess"
Set-AuthenticodeSignature -FilePath "iKVM-KeyPasta.exe" -Certificate $installedcert
```

### Debug mode

`DebugMode := true` in the script records key history, executed lines and a log of the messages to the Java app, viewable from the tray menu. Never leave it on: the key history contains passwords.


## Licenses

### App icons `PPCH*.ico`

Back when it was handwritten without AI help, this project used to be called Swiss-Pasta, because it was limited to the Swiss keyboard layouts. One of the few parts that survived the generalisation rewrite is the icon.  
It's based on the [logo of the Pirate Party Switzerland](https://www.piratenpartei.ch/logos-und-fotos/). Slightly modified by myself.  
License: [CC BY 3.0 CH](https://creativecommons.org/licenses/by/3.0/ch/)
