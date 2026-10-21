#!/bin/bash
# Build "IPMIView KeyPasta.app" from IPMIViewKeyPasta.swift.
# Needs the Xcode Command Line Tools (xcode-select --install) — no full Xcode.

# The app's version: APP_VERSION, then the version of the agent jar it bundles (its manifest)
# without its last number, which is always 0 (agent 3.0.0 -> app 1.3.0).
APP_VERSION=1

set -e
cd "$(dirname "$0")"
MAC="$(cd .. && pwd)"                 # the mac/ folder
APP="IPMIView KeyPasta.app"
EXEC="IPMIViewKeyPasta"
ID="iKVM-KeyPasta"
# The agent jar: the project's, at its top folder. Not there: built with java-agent/build.sh
# (needs a JDK 9 or newer), if the project's java-agent folder is here.
AGENT_JAR="$MAC/../iKVM-KeyPasta-agent.jar"
if [ ! -f "$AGENT_JAR" ] && [ -f "$MAC/../java-agent/build.sh" ]; then
    echo "$AGENT_JAR not found, building it."
    sh "$MAC/../java-agent/build.sh" || echo "Building the agent jar failed." >&2
fi
[ -f "$AGENT_JAR" ] || { echo "ERROR: $AGENT_JAR not found. Build it with java-agent/build.sh, or copy it there." >&2; exit 1; }
AGENT_VER="$(unzip -p "$AGENT_JAR" META-INF/MANIFEST.MF | sed -n 's/^Implementation-Version:[[:space:]]*//p' | head -1 | tr -d '\r')"
[ -n "$AGENT_VER" ] || { echo "No Implementation-Version in $AGENT_JAR" >&2; exit 1; }
VER="$APP_VERSION.${AGENT_VER%.*}"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install" >&2; exit 1; }
command -v clang >/dev/null || { echo "clang not found. Run: xcode-select --install" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>IPMIView KeyPasta</string>
    <key>CFBundleDisplayName</key>     <string>IPMIView KeyPasta</string>
    <key>CFBundleIdentifier</key>      <string>$ID</string>
    <key>CFBundleExecutable</key>      <string>$EXEC</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VER</string>
    <key>CFBundleVersion</key>         <string>$VER</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
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

echo "Compiling…"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/$EXEC" IPMIViewKeyPasta.swift \
    -framework SwiftUI -framework AppKit

# Bundle the launcher script.
cp "$MAC/ipmiview-keypasta.sh" "$APP/Contents/Resources/ipmiview-keypasta.sh"
chmod +x "$APP/Contents/Resources/ipmiview-keypasta.sh"
# Dock names "IPMIView" and "iKVM Viewer" instead of "java": java-name.sh and its launcher, Intel
# like the viewer's Java (Rosetta 2)
cp "$MAC/java-name.sh" "$APP/Contents/Resources/java-name.sh"
chmod +x "$APP/Contents/Resources/java-name.sh"
clang -arch x86_64 -O2 -Wall -o "$APP/Contents/Resources/java-launcher" java-launcher.c -lobjc
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
echo "Move it to /Applications and open it (right-click → Open the first time)."
