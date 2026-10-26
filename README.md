# The iKVM-KeyPasta Project

Makes the keyboard work properly in the Supermicro/ATEN iKVM remote console (Java app and HTML5 browser viewer). Regardless of local or remote keyboard layout, keypresses arrive as typed on your physical keyboard, even dead keys and AltGr. Adds pasting from the local clipboard with `Alt+Shift+V` (macOS: `⌥⇧V` or `⇧⌘V` in the Java viewer, `⇧⌘V` in the browser).


## Components

### Core

- **`iKVM-KeyPasta-agent.jar`** Java agent for IPMIView and .jnlp files: fixes the problems at their source, inside the iKVM viewer and IPMIView itself (details in [DOCUMENTATION.md](DOCUMENTATION.md#7-the-java-agent-fixes-in-ipmiview)).

- **`iKVM-KeyPasta.user.js`** userscript for the HTML5 viewer: fixes the problems at their source, inside the HTML viewer. Any browser with Tampermonkey or Violentmonkey, any system. No admin rights needed.

Extra: **`login-fix.user.js`** userscript for the BMC's login page: makes the BMC Web's login form fillable by password managers.

### Windows

- **`iKVM-KeyPasta.ahk`** AutoHotkey v2 script that tries to fix keyboard layout issues in iKVM viewer, and enables windows clipboard paste on the remote. The project originated from this only, hence the name, Key+Pasta. Simple and well tested, but less well integrated. Keystrokes may come out imperfect. AHK needs admin rights to install. The script runs with UI Access through the AutoHotkey installation instead of as admin. Also adds Ctrl+Alt+Del to the remote, Alt+Tab in the Java app, and the paste shortcut works in other programs than iKVM, too.  

- **`iKVM-IPMIView-launcher.cmd`** Batch script that loads the Java agent into IPMIView and iKVM viewers spawning from it. Tries to start with admin elevation (unless started with `/noadmin`), so viewers don't request elevation again, and to have write access for the admin-protected `.properties` files. If the user's `%AppData%\IPMIView` directory exists, it also advises IPMIView to store its configuration there (instead of the default `%ProgramFiles%\SUPERMICRO\IPMIView`, where only admins can write to but is readable by all users).  

- **`iKVM-jnlp-launcher.cmd`** Launcher for .jnlp files downloaded from the BMC. Loads the Java agent into the iKVM viewer. Double function to literally "Open with" .jnlp files.  
  This launcher requests admin elevation before OpenWebStart downloads the iKVM application from the BMC, which is the only way to run some older versions of the viewer, while newer ones would otherwise request elevation and then start over. This approach is also the safest way to pass the agent to an elevated javaws environment.  

Mix and match any of the core components and the windows specific parts to your liking. Where the agent or the userscript is active, the AHK script leaves that viewer alone and only adds Ctrl+Alt+Del via Ctrl+Alt+End (mimicking RDP) and Alt+Tab (Java app).

### Mac

**iKVM-KeyPasta.app** is a launcher for IPMIView, including Java iKVM remote, and .jnlp files from the BMC's WebUI (both originally unsupported on macOS). Includes the Java agent.  
For Apple silicon Macs up to macOS 27 and Intel-based Macs, all components work more or less natively thanks to Rosetta. Only x86-64 Java 8 or 11 is required.  
Alternatively, the launcher builds virtualized x86-64 containers to run the Java apps. They can be used with a VNC client or a Browser. Needs considerably more resources and a Docker compatible container manager.

### Linux

**Launchers** (CLI and Desktop) for IPMIView and .jnlp files. Load the Java agent in the applications and use standard path for IPMIView settings (usually ~/.config/ipmiview).  
The jnlp launcher still requires OpenWebStart. IcedTea-Web support will follow.


## Scope

The goal is to keep the stack lean and as close to the host OS and Supermicro's tools as possible: it fixes bugs in IPMIView, the iKVM viewer and the HTML5 viewer where they run, rather than replacing them. If you want a containerized IPMI management solution (also suitable for other IPMI manufacturers) instead, have a look at [ipmi-bmc-toolkit](https://github.com/dillonbrowne/ipmi-bmc-toolkit).

For iKVM to work with current BMC firmware, IPMIView 2.25 or newer is required: [IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz](https://www.supermicro.com/Bios/sw_download/1176/IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz), [IPMIView_2.25.0_build.260812_Windows.zip](https://www.supermicro.com/Bios/sw_download/1173/IPMIView_2.25.0_build.260812_Windows.zip).


## Quick install

**Windows:** run `windows\install.cmd` (requires admin elevation). It copies the available files to `%ProgramFiles%\iKVM-KeyPasta\`, registers the jnlp launcher, puts the AHK in autostart and starts it. It also creates a new shortcut in the Start menu that starts IPMIView with the Java agent as administrator.
It asks to install AutoHotkey v2 and OpenWebStart, but does not import the userscript to your browser. Associating .jnlp files with the jnlp launcher also is a manual task (see below).  

**Linux:** run `bash linux/install.sh`, optionally with IPMIView's folder or its .tar.gz download. It puts IPMIView and iKVM Viewer, both with the agent, into your desktop's app menu, just for you (`--system`: for all users, asks for sudo). For a new IPMIView version, just unpack its download into `~/.local/share`: the newest one there is started. iKVM Viewer opens .jnlp files with OpenWebStart (install that first, see below); without a file it opens the launch.jnlp in your Downloads folder. With IPMIView installed for all users, everyone's BMC list and logins are kept in their own `~/.config/ipmiview`. From a terminal, `ipmiview` starts IPMIView; `--debug` shows the agent's log there (`ipmiview --debug`, `/opt/iKVM-KeyPasta/jnlp-keypasta.sh --debug file.jnlp`). `bash linux/install.sh --remove` removes it all again.  

**macOS:** No quick install. Run `bash mac/launcher-app/build.sh` to build the app yourself. Requires JDK for the Java agent and Xcode for the Swift app).  


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

## Usage

Type as usual. Everything only acts in iKVM windows:

- Java app: windows titled `Java iKVM Viewer [...]` or `Java iKVM Viewer v1.69.44 [...]` (with the agent active, the title ends with ⌨)
- HTML5 viewer: tabs titled `Resolution:... FPS :...` (with the userscript active, the title ends with ⌨)

**Paste** types the clipboard into the remote: `Alt+Shift+V`, on macOS `⌥⇧V` or `⇧⌘V` in the Java viewer and `⇧⌘V` in the browser. Another hotkey can be set in the Java viewer's Options › KeyPasta Preferences and in the userscript's settings, a default and per BMC.

- It types for the remote's keyboard layout: Swiss German, Swiss French, German or United States. By default the first of these among your local layouts, else Swiss German. Set it in the AutoHotkey tray menu ("Remote layout"), in the Java viewer's Options › KeyPasta Preferences, or in the userscript's settings. All three keep it per BMC.
- Garbled result (the remote uses another layout)? Turn CapsLock on and paste again (safe paste): slower, but works with any layout, as everything is sent as alt codes. Turn CapsLock off again afterwards (it toggles on the remote, too).
- Text with line breaks or AltGr characters, or with characters that aren't on the keyboard (typed slowly as Alt + number): you're asked first, fast paste, safe paste or cancel. Once the remote layout is set, only the latter are asked about, and that can be set ahead too.
- Switching to another window or pressing Esc stops a running paste.
- In other programs, `Alt+Shift+V` pastes plain text (AutoHotkey; can be turned off in the tray menu).
- The userscript needs the BMC opened with `https://` (browsers give the clipboard to secure pages only), and the browser may ask for permission to read it (Firefox shows a small "Paste" button each time).

**Ctrl+Alt+End** (left Alt, AutoHotkey) sends Ctrl+Alt+Del to the remote, as in Remote Desktop: the real one always goes to the local Windows. It asks first (Cancel is the default), as on a Linux console Ctrl+Alt+Del reboots the server right away. The dialog's "Don't ask again for 4 hours" turns the question off for a while; `ConfirmCtrlAltDel := false` at the top of the script turns it off for good.

**Alt+Tab** in the Java app goes to the remote (AutoHotkey), like the other keys. To switch windows locally, use Win+Tab or the mouse. (The HTML5 viewer can't get it: there, Alt+Tab switches locally.)

**Tray menu** (AutoHotkey):
- Remote layout: for the BMC of the last active Java viewer
- Remote OS: Linux console or Windows, only matters for alt codes of € and the other Windows-1252 special characters (curly quotes, dashes, ...)
- Non-ASCII characters: ask, always include or always omit them when pasting
- Alt+Shift+V pastes in: any window (plain text in other programs) or iKVM windows only
- Suspend hotkeys: everything off, the iKVM windows get their original behaviour back

What each part does, how and why (including what was tried and dropped) is in [DOCUMENTATION.md](DOCUMENTATION.md).

### Advanced configuration

**Agent options:** `-javaagent:...jar=name=value,name=value`: `paste=alt+shift+V` (the default hotkey, on macOS too; the dialog's setting wins), `pasteNonAscii=ask` (`always`, `never`), `remoteOs=linux` (`windows`), `remoteLayout=auto` (the default layout: `us`, `de-CH`, `fr-CH`, `de-DE`, `other` (alt codes); auto: Swiss German; the dialog's setting wins), `localLayout=auto` (macOS only: `de-CH`, `fr-CH`, `de-DE`, `us`; auto: the current input source), `keyDelay=2` (ms per key when pasting), `mouseRate=60` (mouse moves sent to the BMC per second at most, `0`: every one), `log=path` (debug log). Unknown options and values are ignored with a message on the console.

**Agent settings** (the viewer's Options › KeyPasta Preferences, a default and per host) are kept in a plain text file, `agent.properties`, and win over the agent options. The same file works on every platform, so it can be copied or synced between users and computers:

- Windows: `%AppData%\iKVM-KeyPasta\agent.properties`
- macOS: `~/Library/Application Support/iKVM-KeyPasta/agent.properties` (the Mac app's container uses this one, too)
- Linux: `~/.config/iKVM-KeyPasta/agent.properties` (or under `$XDG_CONFIG_HOME`)

One line per setting, `name=value` for the default, `name@host=value` for a host's own, e.g. `remoteLayout@192.0.2.5=us`. `KEYPASTA_SETTINGS_DIR` sets another folder.

**Userscript settings** (the extension's menu, "KeyPasta settings…", in the viewer's tab): the remote's keyboard layout (Swiss German unless set) and the paste hotkey, each a default and this BMC's own (by host), characters not on the keyboard (ask, alt codes, leave out), the remote system for alt codes (Linux console, Windows; also in the paste dialog). Kept in the extension's storage, not in the BMC's site data. `KEY_DELAY` (ms per keystroke when pasting) is at the top of the script.

**AutoHotkey settings** (top of the script): `PasteHotkey`, `ConfirmCtrlAltDel`, and the paste speeds `JavaKeyDelay`, `JavaKeyPressDuration`, `HtmlKeyDelay`.

**Launcher settings** (top of `iKVM-jnlp-launcher.cmd`): `JNLP` (file used when started without one), `OWS` (OpenWebStart folder), `JAVAVERSION` (Java version for the viewer, default `1.8*`, empty: as the .jnlp asks).


## Manual installation

### AutoHotkey (Windows only)

 - Install [AutoHotkey](https://www.autohotkey.com/) v2, e.g. via `winget install AutoHotkey.AutoHotkey --scope machine`

 - Copy `iKVM-KeyPasta.ahk` and the `PPCH_outlined_*.ico` files from the `windows` folder to `%ProgramFiles%\iKVM-KeyPasta\` and run it from there.  
   It runs with UI Access, which can control programs running as admin: in a folder you can write to, any program running as you could change the script and so get that control.

   - Alternatively, compile it into an exe yourself (I will not publish executable binaries), and put that there instead.  
   Windows only grants UI Access to an exe that is signed and in a protected folder like `%ProgramFiles%`. Example for signing and trusting a self-signed certificate (PowerShell):

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

### HTML5 viewer userscript

 - Install [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/) in Firefox or Chrome.

 - Import the `iKVM-KeyPasta.user.js` file in the extension's dashboard (Tampermonkey: Utilities, Import from file), or create a new script there and paste the file's content.

 - Chrome 138 and newer: enable "Allow User Scripts" in the extension's details page (older Chrome: developer mode), otherwise the userscript silently doesn't run.

 - Reload open viewer pages after installing. If the viewer tab's title ends with ⌨, the script works.

### Java agent

 - Copy `iKVM-KeyPasta-agent.jar` to a protected location on your system. Usually `%ProgramFiles%\iKVM-KeyPasta\`.  
   The viewer runs as admin on Windows and loads the jar. In a folder you can write to, any program running as you could replace it and get admin rights. On Linux the viewer runs as you: a jar in your home is fine, a system-wide one belongs to root.

 - To load the agent with iKVM, set the environment variable `JAVA_TOOL_OPTIONS` to `-javaagent:` followed by the full path of `iKVM-KeyPasta-agent.jar` (no spaces in it).  
   If the viewer is not started as admin, it will request admin elevation and not work otherwise. This elevation will use a new environment which may not have the variable, so either:

   - Set the environment permanently. Simplest, but caveat:  
   ***Remember*** to **remove this variable** before deleting or moving the `iKVM-KeyPasta-agent.jar`!  
   An inaccessible path in -javaagent will cause *any* Java program to *silently* not start anymore.

   - Set the variable in an elevated environment and start the viewer (via IPMIView or OpenWebStart) from there.

   - Recommended: on Windows, use the `IPMIView with KeyPasta` Start menu shortcut and open .jnlp files with the provided launcher; on Linux, the IPMIView launcher from `linux/install.sh`; on macOS, the Mac app. They set the variable for IPMIView and its viewers only.

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

- Apple Silicon Macs: the .jnlp brings the viewer's native library only for Intel Macs. The viewer needs an Intel Java (runs through Rosetta 2), set in the Mac app's preferences.
- Current Java 8 refuses TLS 1.0 and 1.1. If an old BMC fails with "connection failed", enable them again for that Java (`jdk.tls.disabledAlgorithms` in its `java.security`).

### Open .jnlp files with the custom handler

Linux: `linux/install.sh` does it (see Quick install). Windows:

Run `iKVM-jnlp-launcher.cmd /register` (not as admin) where it's installed: `windows\install.cmd` puts it in `%ProgramFiles%\iKVM-KeyPasta\` next to the jar (by hand: copy it there from the `windows` folder together with `iKVM-KeyPasta-agent.jar` and `PPCH_outlined_dark.ico`). Then in the right-click › "Open with" dialog, make it the default for all .jnlp files.

It takes care of elevation and setting the environment, and keeps your Downloads folder clean of iKVM's launch.jnlp files by moving them to `%TEMP%\iKVM-KeyPasta`. Other .jnlp files go to OpenWebStart unchanged.

`/unregister` removes it again. Started without arguments, it opens the launch.jnlp in your Downloads folder.

### Java iKVM viewer setup

The Java iKVM viewer comes either from IPMIView or as a `.jnlp` file from the BMC's web interface. You probably don't need to change anything in it.

 * Leave "Keyboard layout" at its default (English). Surprisingly, this setting may be saved and read from the remote machine.
 * Don't set "Repeat Key timeout" to 0 ms (default 200 ms): lock keys (CapsLock, NumLock, ScrollLock) don't reach the remote then.
 * Because the AHK script captures Alt+Tab, you may want to remember what hotkey "Exit Remote Location" is bound to (default is `F2`).


## Licenses

### App icons `PPCH*.ico`

Back when it was handwritten without AI help, this project used to be called Swiss-Pasta, because it was limited to the Swiss keyboard layouts. One of the few parts that survived the generalisation rewrite is the icon. It still fits the project, as all parts putsch original software to improve it 🏴‍☠️.  
Based on the [logo of the Pirate Party Switzerland](https://www.piratenpartei.ch/logos-und-fotos/). License: [CC BY 3.0 CH](https://creativecommons.org/licenses/by/3.0/ch/).  
Modifications, done by myself:  
 * Removed the outer rings  
 * Added the fat plus sign that roughly resembles the Swiss cross  
