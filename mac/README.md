# iKVM-KeyPasta on macOS

Supermicro's Java remote console doesn't run on a Mac out of the box: IPMIView refuses it for most BMCs ("The function can't support on mac"), and the `.jnlp` viewer from the BMC's web interface needs an Intel Java and a Java Web Start. **IPMIView KeyPasta**, a small Mac app, runs both, with the iKVM-KeyPasta keyboard fixes and paste.

Not part of the release, use at your own risk. How it works and why: [DOCUMENTATION.md](../DOCUMENTATION.md#13-macos-the-app-the-scripts-the-container).

## What you need

- IPMIView for Linux (x64) from Supermicro's website, unpacked anywhere.
- An Intel (x86_64) Java 11 runtime, e.g. Temurin's JRE `.pkg` for macOS x64: the viewer's native libraries are Intel only (on Apple Silicon it runs through Rosetta 2).
- [Homebrew](https://brew.sh)'s stunnel, for BMCs with encrypted KVM: `brew install stunnel`.
- For `.jnlp` files: [OpenWebStart](https://openwebstart.com/download/).
- To build the app: the Xcode Command Line Tools (`xcode-select --install`).

Without Rosetta (macOS 28 on) or without an Intel Java, the app can run the whole console in a Linux container instead (OrbStack, Docker Desktop, Podman, or Colima with `brew install colima docker`), shown in your browser.

## Build and install

```
cd mac/launcher-app
./build.sh
```

Move `IPMIView KeyPasta.app` to Applications and open it (right-click › Open the first time). In its Preferences (app menu, `Cmd+,`), set the IPMIView folder and, if not found by itself, the Intel Java and OpenWebStart.

## Use

- **Launch IPMIView**, then open a BMC's console from it as usual. With IPMIView's container running, the same button opens its console in the browser.
- **`.jnlp` files**: drop one on the app's window, click the drop area to choose one, or open `Downloads/launch.jnlp`.
- **Keyboard LEDs:** allow the app Input Monitoring when asked (System Settings › Privacy & Security). Without it everything works too, without CapsLock LED sync.
- **Paste:** `Option+Shift+V` or `Cmd+Shift+V` in the viewer, or your own hotkey (Preferences). In the container's browser view it pastes your Mac's clipboard; Chrome and Edge ask once whether they may read it. After that the clipboard is shared both ways there: copy in the container, paste on the Mac, and the other way round.
- **Alt next to the space bar:** in the viewer, Options › KeyPasta Agent swaps Option and Command (for all BMCs or one), natively and in the container.
- The container and the native start share IPMIView's BMC list and saved logins (in `~/.config/ipmiview`). The container keeps the publishers you chose to always trust there too; right-click its desktop for IcedTea-Web's settings.
- In the container, each console opens in a browser tab of its own (Preferences: "Open iKVM Viewer windows in separate browser tabs"); close the tab when you've closed the console. A `.jnlp` runs in a container of its own, next to IPMIView's and other ones.
- **Browser** (Preferences): where the consoles open: automatic, a browser of your choice, or a command, e.g. Chrome with a profile in app mode (the example is there).
- Quitting the app ends the consoles it started; it asks first.

**Old BMC firmware with an expired KVM certificate** ("certificate has expired" in `/tmp/iKVM-KeyPasta-stunnel.log`): turn on "Accept the BMC's expired iKVM certificate" in Preferences and set the BMC's clock back before the expiry. Details in the [documentation](../DOCUMENTATION.md#expired-ikvm-certificate).

## Extras

- **Karabiner-Elements rules** (`karabiner/`, only in the iKVM viewer): `ikvm-option-command.json` swaps Option and Command (the agent does that now, see Use; not both), so the keys next to the space bar are the remote's Alt and AltGr, like on a PC keyboard; `ikvm-function-keys.json` gives the remote F1–F12 without fn. Install: Karabiner-Elements Settings › Complex Modifications › Add your own rule, paste the file's content (`pbcopy < karabiner/ikvm-option-command.json`), Save.
- **Icons** (`icons/`): light and dark `.icns`, and SVG layers for an icon that follows dark/light mode in Icon Composer (silhouette as back layer, symbol on top; Default: silhouette white, symbol black; Dark: the other way round).
- **Without the app:** `bash ipmiview-keypasta.sh [IPMIView folder]` starts IPMIView the same way (settings at the top of the script).
