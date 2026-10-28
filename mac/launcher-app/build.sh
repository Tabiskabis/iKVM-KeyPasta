#!/bin/bash
# Build "IPMIView+iKVM KeyPasta launcher.app" (named iKVM-KeyPasta in its menus and window) from
# IPMIViewKeyPasta.swift.
# Needs the Xcode Command Line Tools (xcode-select --install) — no full Xcode.
#
#   ./build.sh             build it here (mac/launcher-app/)
#   ./build.sh --install   then put it in /Applications (~/Applications if /Applications isn't
#                          writable for you): an app already there goes to the Trash first. No
#                          admin rights needed (admins may write /Applications; else your own).

# The app's version: APP_VERSION, then the version of the agent jar it bundles (its manifest)
# without its last number, which is always 0 (agent 3.0.0 -> app 1.3.0).
APP_VERSION=1

INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "Unknown option $arg (--install: build, then install)" >&2; exit 1 ;;
    esac
done

set -e
cd "$(dirname "$0")"
MAC="$(cd .. && pwd)"                 # the mac/ folder
APP="IPMIView+iKVM KeyPasta launcher.app"
EXEC="IPMIViewKeyPasta"
ID="iKVM-KeyPasta"
# The agent jar: the project's, at its top folder, built first every time with java-agent/build.sh
# (needs a JDK 9 or newer) if the project's java-agent folder is here. That fails: the jar already
# there, with a warning.
AGENT_JAR="$MAC/../iKVM-KeyPasta-agent.jar"
if [ -f "$MAC/../java-agent/build.sh" ] && ! sh "$MAC/../java-agent/build.sh" && [ -f "$AGENT_JAR" ]; then
    echo "WARNING: the agent jar not rebuilt (see above): bundling the one already there." >&2
fi
[ -f "$AGENT_JAR" ] || { echo "ERROR: $AGENT_JAR not found. Build it with java-agent/build.sh, or copy it there." >&2; exit 1; }
AGENT_VER="$(unzip -p "$AGENT_JAR" META-INF/MANIFEST.MF | sed -n 's/^Implementation-Version:[[:space:]]*//p' | head -1 | tr -d '\r')"
[ -n "$AGENT_VER" ] || { echo "No Implementation-Version in $AGENT_JAR" >&2; exit 1; }
VER="$APP_VERSION.${AGENT_VER%.*}"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install" >&2; exit 1; }
command -v clang >/dev/null || { echo "clang not found. Run: xcode-select --install" >&2; exit 1; }

# Oldest macOS it runs on: 13 (Ventura; SwiftUI's Window scene and windowResizability). Built for
# that, whatever macOS builds it, and universal (Apple silicon and Intel).
MIN_MACOS=13.0
ARCHS="arm64 x86_64"

rm -rf "$APP" build-arch
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>iKVM-KeyPasta</string>
    <key>CFBundleDisplayName</key>     <string>iKVM-KeyPasta</string>
    <key>CFBundleIdentifier</key>      <string>$ID</string>
    <key>CFBundleExecutable</key>      <string>$EXEC</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VER</string>
    <key>CFBundleVersion</key>         <string>$VER</string>
    <key>LSMinimumSystemVersion</key>  <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Connects to the BMC's KVM console over the local network.</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>        <string>Java Web Start</string>
            <key>CFBundleTypeExtensions</key>  <array><string>jnlp</string></array>
            <key>CFBundleTypeRole</key>        <string>Viewer</string>
            <key>LSHandlerRank</key>           <string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

mkdir -p build-arch
for arch in $ARCHS; do
    echo "Compiling ($arch, macOS $MIN_MACOS and newer)…"
    swiftc -O -parse-as-library -target "$arch-apple-macos$MIN_MACOS" -o "build-arch/$EXEC-$arch" \
        IPMIViewKeyPasta.swift -framework SwiftUI -framework AppKit
done
lipo -create -output "$APP/Contents/MacOS/$EXEC" $(for arch in $ARCHS; do echo "build-arch/$EXEC-$arch"; done)
rm -rf build-arch
lipo -info "$APP/Contents/MacOS/$EXEC"

# Bundle the launcher script.
cp "$MAC/ipmiview-keypasta.sh" "$APP/Contents/Resources/ipmiview-keypasta.sh"
chmod +x "$APP/Contents/Resources/ipmiview-keypasta.sh"
# Dock names "IPMIView" and "iKVM Viewer" instead of "java": java-name.sh and its launcher, Intel
# like the viewer's Java (Rosetta 2)
cp "$MAC/java-name.sh" "$APP/Contents/Resources/java-name.sh"
chmod +x "$APP/Contents/Resources/java-name.sh"
clang -arch x86_64 -mmacosx-version-min="$MIN_MACOS" -O2 -Wall -o "$APP/Contents/Resources/java-launcher" java-launcher.c -lobjc
cp -R "$MAC/container" "$APP/Contents/Resources/container"
chmod +x "$APP/Contents/Resources/container/run.sh" "$APP/Contents/Resources/container/entrypoint.sh"
# Bundle the agent jar (found above)
cp "$AGENT_JAR" "$APP/Contents/Resources/iKVM-KeyPasta-agent.jar"
echo "Bundled agent: $AGENT_JAR"

# Icon: the outline-free dark glyph (falls back to any .icns).
ICNS="$(ls "$MAC"/icons/iKVM-KeyPasta.icns "$MAC"/icons/*.icns 2>/dev/null | head -1 || true)"
[ -n "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# Dock icon while running, following dark/light mode (the app switches it)
cp "$MAC/icons/iKVM-KeyPasta-dark-mode.icns" "$APP/Contents/Resources/AppIcon-dark.icns"
cp "$MAC/icons/iKVM-KeyPasta-light-mode.icns" "$APP/Contents/Resources/AppIcon-light.icns"

# Clear any quarantine the synced folder may carry, then ad-hoc sign (executable first, then the
# bundle) so Gatekeeper accepts it and the identity stays stable across launches (TCC grants stick).
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/java-launcher"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$EXEC"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP" || { echo "codesign verify failed" >&2; exit 1; }

echo "Built: $(pwd)/$APP"
if ! $INSTALL; then
    echo "Move it to /Applications and open it (right-click → Open the first time), or run ./build.sh --install."
    exit 0
fi

# --install: /Applications if you may write there (admins may), else ~/Applications
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
OLD="$DEST/$APP"
[ "$DEST" = "$HOME/Applications" ] && [ -e "/Applications/$APP" ] \
    && echo "Note: /Applications/$APP stays (not writable for you); the new one goes to $DEST." >&2
if [ -e "$OLD" ]; then
    # still running: it keeps running from the Trash until quit (pgrep takes a regular
    # expression: the path's + and . escaped; "[" last, as "[." in brackets starts a collating symbol)
    pgrep -f "$(printf '%s' "$OLD/Contents/MacOS/$EXEC" | sed 's/[].*^$+?(){}|[]/\\&/g')" >/dev/null 2>&1 \
        && echo "The installed app is running: quit it and open it again to use the new one." >&2
    # to the Trash by the system: macOS 15's trash command, else its trash function
    # (FileManager.trashItem) through osascript's JavaScript
    if [ -x /usr/bin/trash ]; then
        /usr/bin/trash "$OLD" || :
    else
        osascript -l JavaScript -e 'ObjC.import("Foundation")' -e 'function run(argv) {
            $.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(argv[0]), null, null) }' \
            "$OLD" >/dev/null || :
    fi
    [ -e "$OLD" ] && { echo "Couldn't move $OLD to the Trash: the new app stays in $(pwd)." >&2; exit 1; }
    echo "Moved the previous app to the Trash."
fi
mv "$APP" "$OLD"
# Launch Services: the new app (its version, .jnlp files) right away
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$OLD" >/dev/null 2>&1 || true
echo "Installed: $OLD"
echo "Open it from there (right-click → Open the first time)."
