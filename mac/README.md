# iKVM-KeyPasta on macOS

Supermicro's Java remote console doesn't run on a Mac out of the box: IPMIView refuses it for most BMCs ("The function can't support on mac"), and the `.jnlp` viewer from the BMC's web interface needs an Intel Java and a Java Web Start. **IPMIView KeyPasta**, a small Mac app, runs both, with the iKVM-KeyPasta keyboard fixes and paste.

Not part of the release, use at your own risk. How it works and why: [DOCUMENTATION.md](../DOCUMENTATION.md#13-macos-the-app-the-scripts-the-container).

## What you need

- IPMIView for Linux (x64) from Supermicro's website, unpacked anywhere.
- An Intel (x86_64) Java 11 runtime, e.g. Temurin's JRE `.pkg` for macOS x64: the viewer's native libraries are Intel only (on Apple Silicon it runs through Rosetta 2).
- [Homebrew](https://brew.sh)'s stunnel, for BMCs with encrypted KVM: `brew install stunnel`.
- For `.jnlp` files: [OpenWebStart](https://openwebstart.com/download/).
- To build the app: the Xcode Command Line Tools (`xcode-select --install`).

Without an Intel Java, the app can run the whole console in a Linux container instead (OrbStack, Docker Desktop, Podman, or Colima with `brew install colima docker`), shown in your browser or a VNC app.

**From macOS 28 on, the console can't run natively any more.** Its viewer contains Intel-only (x86) code, and macOS 28 no longer translates it for Mac apps. The app then runs it in a Linux container. On a Mac every container engine runs inside a small Linux virtual machine, and the x86 code there is translated again: by Rosetta for Linux where the engine and macOS still offer it, otherwise by QEMU emulation, which is much slower. Expect the container to use noticeably more memory and CPU than the native console did: give the engine's VM enough memory (several GB if you open many consoles at once).

## Build and install

```
cd mac/launcher-app
./build.sh
```

Move `IPMIView KeyPasta.app` to Applications and open it (right-click › Open the first time). In its Preferences (app menu, `Cmd+,`): General sets the IPMIView folder and whether it runs natively or in a container; the Native tab the Intel Java and OpenWebStart, if not found by themselves; the Container tab where the consoles open.

## Use

- **Launch IPMIView**, then open a BMC's console from it as usual. With IPMIView's container running, the same button opens its console in the browser.
- **`.jnlp` files**: drop one on the app's window, click the drop area to choose one, or open the newest `launch.jnlp` in Downloads (also `launch (1).jnlp` and so on; the button shows which). An iKVM `.jnlp` is moved to `~/Library/Caches/iKVM-KeyPasta/` when it's successfully opened, so the next download gets the same name again.
- **Paste:** `Option+Shift+V` or `Cmd+Shift+V` in the viewer, or your own hotkey (in the viewer: Options › KeyPasta Preferences, for all BMCs or one). In the container's browser view it pastes your Mac's clipboard; Chrome and Edge ask once whether they may read it. After that the clipboard is shared both ways there: copy in the container, paste on the Mac, and the other way round.
- **Keyboard layout in the container** (for IPMIView's own fields): the Mac's, when a container starts; a layout of your own isn't recognized: choose it in Preferences › Container.
- **Alt next to the space bar:** in the viewer, Options › KeyPasta Preferences swaps Option and Command (for all BMCs or one). These settings are the same natively and in the container, in `~/Library/Application Support/iKVM-KeyPasta/agent.properties` (one file for Mac, Windows and Linux: copy or sync it).
- The container and the native start share IPMIView's BMC list and saved logins (in `~/Library/Application Support/IPMIView`). The container keeps the publishers you chose to always trust there too; right-click its desktop for IcedTea-Web's settings.
- In the container, each console opens in a browser tab or TigerVNC window of its own (Preferences › Container: "Each iKVM Viewer in a tab or window of its own"); close it when you've closed the console. A `.jnlp` runs in a container of its own, next to IPMIView's and other ones.
- **Where the consoles open** (Preferences › Container): in the VNC app if there is one (Automatic: TigerVNC Viewer if installed, `brew install --cask tigervnc-viewer`, better keys and clipboard than a browser), else in the browser. Both dropdowns also take another app or a custom command, e.g. TigerVNC in fullscreen or Chrome with a profile in app mode (the examples are there). Option-click Open console, the launch button or a .jnlp's (or hold Option while dropping one): the other way.
- **Security** (Preferences › Container): the consoles are reachable from this Mac only, without a password (a VNC app that wants one may give any). Turn "Accept any VNC password" off for a password; turn "This Mac only" off to reach them from the network, which always needs the password (for the browser view too).

  | | Browser | VNC |
  |---|---|---|
  | IPMIView | 6100 | 5700 |
  | Consoles opened from IPMIView (1–99) | 6101–6199 | 5701–5799 |
  | `.jnlp` consoles (1–99) | 6201–6299 | 5801–5899 |
- In the viewer, Cmd+Q goes to the remote instead of quitting it (Alt+Q with Alt and Command swapped); close the viewer with its close button or its Quit menu item.
- What runs is listed in the app's window, grouped: **IPMIView** (its container and, below it, its iKVM viewers in tabs of their own, by BMC) and **.jnlp** (its consoles). Each has **Open console** (Option-click: the other way) and Stop (a viewer's: just that viewer); hover over a name for its addresses. IPMIView's viewers open the way its console was opened last. The app finds what already runs when it starts.
- Quitting the app ends the consoles it started; it asks first.

**Old BMC firmware with an expired KVM certificate** ("certificate has expired" in `/tmp/iKVM-KeyPasta-stunnel.log`): turn on "Accept expired firmware certificate" in Preferences › General and set the BMC's clock back before the expiry. Details in the [documentation](../DOCUMENTATION.md#expired-ikvm-certificate).

## Extras

- **Karabiner-Elements rules** (`karabiner/*.json` files): The `swap-fn-fkeys-*.json` Forces the F-Row keys to act as F-Keys. Use the Fn-key to use them as Media keys. The `swap-alt-cmd-*.json` files were made before the agent got the same function. Might still be useful.  
  Install: Karabiner-Elements Settings › Complex Modifications › Add your own rule, paste the file's content, Save.
- **Without the app:** `bash ipmiview-keypasta.sh [IPMIView folder]` starts IPMIView the same way (settings at the top of the script).

## Known bugs

Sometimes the macOS menu bar does not show items. They appear when hovering the mouse pointer over it or switching windows. This is a known issue in macOS 27. The app tries to mitigate it, but it still happens sometimes.
