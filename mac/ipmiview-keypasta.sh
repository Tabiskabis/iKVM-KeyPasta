#!/bin/bash
# iKVM-KeyPasta, experimental: IPMIView's Java KVM console on macOS, also for BMCs with "stunnel"
# (encrypted KVM), which IPMIView refuses on macOS ("The function can't support on mac") although
# its Mac code is still there: the Java agent turns that code back on (MacStunnel), so the
# encrypted console needs the agent. See README.md next to this file.
#
#   bash ipmiview-keypasta.sh [IPMIView folder]
#
# Changes in the IPMIView folder: renames the Linux Java folder jre to jre-linux, adds
# BMCSecurity/mac/ (stunnel wrapper, stunnel.conf) and proxy_ip=127.0.0.1 in stunnel.properties. stunnel's log: /tmp/iKVM-KeyPasta-stunnel.log
# IPMIView's settings (IPMIView.properties, account.properties, ...) are kept in
# ~/Library/Application Support/IPMIView.

# Settings
IPMIVIEW="${1:-${IPMIVIEW:-$HOME/.local/bin/IPMIView_2.25.0_build.260709_bundleJRE_Linux_x64}}"
# Intel (x86_64) Java: IPMIView itself runs on any Java, but the viewer it starts (iKVM.jar) loads
# native libraries (libiKVM64.jnilib, libSharedLibrary64.jnilib) that are x86_64 only, and quits
# without them (on Apple Silicon an Intel Java runs through Rosetta 2)
INTEL_JAVA="${INTEL_JAVA:-/Library/Java/JavaVirtualMachines/temurin-11.jre/Contents/Home}"
AGENT="${AGENT:-/opt/iKVM-KeyPasta/iKVM-KeyPasta-agent.jar}"
# Expired iKVM TLS certificate (old BMC firmware, "certificate has expired" in the stunnel log):
# true turns off this Mac's check of the BMC's certificate (verify = 0: the console stays encrypted
# but isn't verified, a device on the network could pose as the BMC). The BMC still checks OUR cert
# against its own clock, so also roll the BMC clock back before the cert's expiry. Off by default:
# current firmware doesn't need it. See README.md.
IGNORE_EXPIRED_CERT="${IGNORE_EXPIRED_CERT:-false}"

HERE="$(cd "$(dirname "$0")" && pwd)"

fail() {
    echo "$1" >&2
    exit 1
}

[ -f "$IPMIVIEW/IPMIView20.jar" ] || fail "IPMIView20.jar not found in $IPMIVIEW: adjust IPMIVIEW at the top of this file."
[ -x "$INTEL_JAVA/bin/java" ] || fail "No Java in $INTEL_JAVA: adjust INTEL_JAVA at the top of this file."
cd "$IPMIVIEW" || exit 1
IPMIVIEW="$(pwd)"   # absolute (links and class path below)

# In front in PATH: IPMIView starts the viewer as "java"
export JAVA_HOME="$INTEL_JAVA"
export PATH="$INTEL_JAVA/bin:$PATH"

# With a folder jre, IPMIView starts the viewer with ./jre/Contents/Home/bin/java (macOS layout):
# the Linux package's jre has none, without it IPMIView takes "java" from PATH.
if [ -d jre ] && [ ! -e jre/Contents/Home/bin/java ]; then
    mv -n jre jre-linux || fail "Couldn't rename $IPMIVIEW/jre."
    echo "Renamed the Linux Java folder jre to jre-linux."
fi

# stunnel for macOS, where IPMIView's Mac code looks for it. IPMIView copies it into a new temp
# folder for every console: a copy of the binary would be a new program for the macOS firewall
# every time. So a wrapper that starts Homebrew's stunnel from its own, fixed place. Without one,
# IPMIView starts anyway (the agent puts a note below "Launch KVM Console"); the wrapper then only
# says so, in stunnel's log.
STUNNEL="$(command -v stunnel)"
[ -n "$STUNNEL" ] || echo "stunnel not found in PATH: the KVM console of a BMC with encrypted KVM won't open (brew install stunnel)." >&2
mkdir -p BMCSecurity/mac || fail "Couldn't create $IPMIVIEW/BMCSecurity/mac."
TMPW="$(mktemp)" || fail "Couldn't create a temp file."
cat > "$TMPW" <<'EOW'
#!/bin/sh
# iKVM-KeyPasta: stunnel from a fixed place (macOS firewall), see ipmiview-keypasta.sh
#RELAX# # IGNORE_EXPIRED_CERT: accept the BMC's expired iKVM certificate (roll the BMC clock back
#RELAX# # too, it checks ours; see README.md). verify = 0 in the config IPMIView passes.
#RELAX# for f in "$@"; do
#RELAX#     case "$f" in *.conf) [ -f "$f" ] && sed -i '' -E 's/^[[:space:]]*verify[[:space:]]*=.*/verify = 0/' "$f" ;; esac
#RELAX# done
#NONE# echo "iKVM-KeyPasta: stunnel isn't installed (brew install stunnel)" >> /tmp/iKVM-KeyPasta-stunnel.log
#NONE# exit 1
#SOME# exec "__STUNNEL__" "$@"
EOW
if [ "$IGNORE_EXPIRED_CERT" = true ]; then
    sed -i '' 's/^#RELAX# //' "$TMPW"
else
    sed -i '' '/^#RELAX#/d' "$TMPW"
fi
if [ -n "$STUNNEL" ]; then
    sed -i '' -e '/^#NONE#/d' -e 's/^#SOME# //' -e "s|__STUNNEL__|$STUNNEL|" "$TMPW"
else
    sed -i '' -e '/^#SOME#/d' -e 's/^#NONE# //' "$TMPW"
fi
if ! cmp -s "$TMPW" BMCSecurity/mac/stunnel 2>/dev/null; then
    # (removed first: the earlier copy of Homebrew's binary is read-only, r-xr-xr-x)
    rm -f BMCSecurity/mac/stunnel &&
        cp "$TMPW" BMCSecurity/mac/stunnel && chmod 755 BMCSecurity/mac/stunnel ||
        fail "Couldn't write $IPMIVIEW/BMCSecurity/mac/stunnel."
fi
rm -f "$TMPW"
# Linux's stunnel.conf, logging to a file (IPMIView shows none of stunnel's messages)
sed 's|^; *output *=.*|output = /tmp/iKVM-KeyPasta-stunnel.log|' BMCSecurity/linux/stunnel.conf > BMCSecurity/mac/stunnel.conf ||
    fail "Couldn't write $IPMIVIEW/BMCSecurity/mac/stunnel.conf."

# The tunnel's local end: on Linux and macOS IPMIView takes the first network address that isn't
# loopback (the firewall asks, and blocks the viewer's connection meanwhile), unless proxy_ip in
# stunnel.properties says otherwise. Your own proxy_ip stays.
if ! grep -q '^proxy_ip *=' stunnel.properties 2>/dev/null; then
    [ -s stunnel.properties ] && [ -n "$(tail -c 1 stunnel.properties)" ] && echo >> stunnel.properties
    echo "proxy_ip=127.0.0.1" >> stunnel.properties || fail "Couldn't write $IPMIVIEW/stunnel.properties."
fi

# the agent for IPMIView and the viewers it starts (they inherit the variable)
if [ -f "$AGENT" ]; then
    # AGENT_ARGS: agent options (the app passes its log file and the paste hotkey)
    export JAVA_TOOL_OPTIONS="-javaagent:$AGENT${AGENT_ARGS:+=$AGENT_ARGS}"
else
    echo "$AGENT not found: starting without the agent (the encrypted console won't open)."
fi

# Dock names "IPMIView" and "iKVM Viewer" instead of "java" (see java-name.sh): "java" in PATH runs
# through it, for IPMIView and the viewers it starts as java. Needs java-launcher, built by the app
# (KEYPASTA_LAUNCHER); else plain java.
NAMER="$HERE/java-name.sh"
if [ -n "${KEYPASTA_LAUNCHER:-}" ] && [ -x "$KEYPASTA_LAUNCHER" ] && [ -f "$NAMER" ]; then
    BIN="$HOME/Library/Application Support/iKVM-KeyPasta/bin"
    if mkdir -p "$BIN" && ln -sf "$NAMER" "$BIN/java"; then
        export KEYPASTA_JAVA_HOME="$INTEL_JAVA"
        export PATH="$BIN:$PATH"
    fi
fi

# IPMIView's settings (IPMIView.properties: the BMC list; account.properties: saved logins; a few
# more) go to ~/Library/Application Support/IPMIView, not the IPMIView folder: they survive an
# IPMIView update. IPMIView runs in its folder (it finds its files relative to the folder it runs
# in) and gets the settings folder as its second argument; the agent sends the settings files
# IPMIView opens by bare name there too (KEYPASTA_IPMIVIEW_SETTINGS, see SettingsFolder). A
# settings file missing there is copied from the IPMIView folder as a starting point. Not
# $XDG_CONFIG_HOME: the app sets it for IcedTea-Web's own profile.
DATA="$HOME/Library/Application Support/IPMIView"
mkdir -p "$DATA" || fail "Couldn't create $DATA."
find "$DATA" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null   # links of the earlier way
for f in IPMIView.properties account.properties email.properties language.properties proxy.properties \
        smcrakp.properties sort.properties timeout.properties update.properties version.properties; do
    [ -f "$IPMIVIEW/$f" ] && [ ! -e "$DATA/$f" ] && cp -p "$IPMIVIEW/$f" "$DATA/$f"
done
export KEYPASTA_IPMIVIEW_SETTINGS="$DATA/"

# IPMIView20.lax's class path. Its menus in the Mac's menu bar, as Mac apps have
# them (only IPMIView: the viewers it starts keep theirs in the window)
exec java -Xmx512m -Dapple.laf.useScreenMenuBar=true -cp "$IPMIVIEW/iKVM.jar:$IPMIVIEW/IPMIView20.jar:$IPMIVIEW/TrapView.jar:$IPMIVIEW/JViewerX9.jar:$IPMIVIEW/lax.jar" IPMIView20.IPMIView20 - "$DATA/"
