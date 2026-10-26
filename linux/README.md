# iKVM-KeyPasta on Linux

Supermicro's Java remote console runs on Linux as it is, but with the keyboard problems iKVM-KeyPasta fixes. The Linux launchers start **IPMIView** and the **iKVM viewer from `.jnlp` files** (the BMC web interface's "Launch Console") with the iKVM-KeyPasta agent loaded: keys by position whatever the layouts, and paste. They put both into your desktop's app menu.

Not part of the release, use at your own risk. How it works and why: [DOCUMENTATION.md](../DOCUMENTATION.md#12-linux-the-desktop-launcher).

## What you need

- IPMIView for Linux (x64), 2.25 or newer for current BMC firmware: [IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz](https://www.supermicro.com/Bios/sw_download/1176/IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz). Only for IPMIView: a `.jnlp` doesn't need it.
- For `.jnlp` files, one of:
  - [OpenWebStart](https://openwebstart.com/download/): downloads the Java it needs itself.
  - IcedTea-Web (Debian/Ubuntu: `icedtea-netx`), a **Java 11** (e.g. `openjdk-11-jre`, or Temurin 11) and `python3`.
- For BMCs with encrypted KVM: `libnsl.so.1`. Debian and Ubuntu have it; Fedora and others need `sudo dnf install libnsl`. Without it the console only says "connect failed sd:…". The launchers tell you when it's missing.
- From a git clone: a JDK 9 or newer, so the installer can build the agent (`iKVM-KeyPasta-agent.jar`) if it isn't there.

## Install

```
bash linux/install.sh [IPMIView folder or IPMIView_…_Linux_x64.tar.gz]
```

Without an argument it takes the newest IPMIView already installed, or the newest download in the current folder or in Downloads. A download is unpacked into `~/.local/share`.

- **Just for you** (default, no root): `~/.local/share/iKVM-KeyPasta`, menu entries, and the command `ipmiview` in `~/.local/bin`.
- **For all users:** `--system` (asks for sudo): `/opt/iKVM-KeyPasta`, IPMIView in `/opt`. Everyone keeps their own BMC list and logins.
- **`.jnlp` files:** it asks whether iKVM Viewer should open them (`--jnlp`: yes without asking, `--no-jnlp`: leave it). Other `.jnlp` files still go to your Web Start unchanged.
- **Remove:** `bash linux/install.sh --remove`. IPMIView's folders stay.

**New IPMIView version:** unpack its download into `~/.local/share` (for all users: `/opt`). The newest one there is what starts, no new install needed.

Run the installer again after updating iKVM-KeyPasta (`git pull`), so the new agent and launchers are used.

## Use

- **IPMIView** from the app menu or `ipmiview`, then open a BMC's console from it as usual. Its BMC list and saved logins are in `~/.config/ipmiview`, the same for every IPMIView version.
- **`.jnlp` files:** open one (with iKVM Viewer as the program for `.jnlp`, a double-click or the browser's "Open" does it), or start **iKVM Viewer** from the menu: it opens the newest `launch.jnlp` in Downloads (also `launch (1).jnlp` and so on).
  - The viewer runs from a copy in `~/.cache/iKVM-KeyPasta/`, readable by you only, kept for a week. The `.jnlp` in Downloads is removed only once a viewer window has opened from it, so the next download gets the same name again. If no window opens, it stays there for another try.
  - With IcedTea-Web, its settings and the publishers you chose to always trust are in `~/.config/iKVM-KeyPasta/icedtea-web`, apart from OpenWebStart's.
- **Paste:** `Alt+Shift+V` in the viewer, or your own hotkey (in the viewer: Options › KeyPasta Preferences, for all BMCs or one). These settings are in `~/.config/iKVM-KeyPasta/agent.properties`, one file for Linux, Windows and Mac: copy or sync it.

**Launcher settings** (top of `jnlp-keypasta.sh`, or as environment variables): `JAVAWS` (which `javaws`: by default OpenWebStart's if installed, else the one in `PATH`), `ITWJAVA` (the Java for IcedTea-Web, by default the newest Java 11 in `/usr/lib/jvm`), `JAVAVERSION` (the Java OpenWebStart uses for the viewer, default `1.8*`), `VIEWERWAIT` (how long to wait for the viewer window before leaving the `.jnlp` in Downloads, default 300 seconds).

## Debugging

Both launchers take `-d` or `--debug` (and `-h` or `--help`). Start them from a terminal:

```
ipmiview --debug [IPMIView folder]
~/.local/share/iKVM-KeyPasta/jnlp-keypasta.sh --debug [file.jnlp]
```

(For all users: `/opt/iKVM-KeyPasta/jnlp-keypasta.sh`. Without a file, the newest `launch*.jnlp` in Downloads.)

- **The agent's log** is shown as it grows: what it does in IPMIView and the viewers, and the viewer's milestones (started, connecting, window shown). It's kept in `~/.local/state/iKVM-KeyPasta/agent.log`, the run before in `agent.log.old`. It never contains typed keys or passwords.
- **`ipmiview --debug`:** IPMIView's own output next to it, until IPMIView ends. The viewers it opens log to the same file.
- **`jnlp-keypasta.sh --debug`:** which `.jnlp` copy, which `javaws` and Java it uses, and whether the `.jnlp` in Downloads was removed or kept. With IcedTea-Web also its own detailed output (`-verbose`): what it loads and why that fails. Ctrl+C ends the display, not the viewer.

The `.jnlp` launcher's debug output contains the console session's login data (the viewer's arguments). It's short-lived, but don't post it publicly.

## Troubleshooting

- **"connect failed sd:…"** right after the viewer starts: the viewer's tunnel (stunnel) can't run. Most often `libnsl.so.1` is missing (see above).
- **"thread 'main' panicked at src/os_access.rs"** when opening a `.jnlp` with IcedTea-Web outside the launcher: its `javaws` can't find a working Java. The launcher sets one; outside it, check `JAVA_HOME` and `deployment.jre.dir` in `~/.config/icedtea-web/deployment.properties`.
- **Old BMC firmware with an expired KVM certificate:** see the [documentation](../DOCUMENTATION.md#expired-ikvm-certificate).
