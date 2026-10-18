#!/bin/bash
# iKVM-KeyPasta, Linux: IPMIView and iKVM Viewer (.jnlp files) in the desktop's app menu, and the
# command ipmiview, all with the Java agent.
#
#   bash install.sh [--user|--system] [IPMIView folder]    install or update
#   bash install.sh --uninstall                            remove it again (both kinds)
#
# Where it goes follows IPMIView:
#   in your home folder (or --user): for you only, no root needed
#     ~/.local/share/iKVM-KeyPasta (agent, starters), ~/.local/share/applications,
#     ~/.local/share/icons, ~/.local/bin/ipmiview
#   elsewhere, e.g. /opt (or --system): for all users, as root (asks for sudo), so that no user
#     can change what the others run
#     /opt/iKVM-KeyPasta, /usr/local/share/applications, /usr/local/share/icons,
#     /usr/local/bin/ipmiview
# The viewer runs as the user on Linux (not as admin as on Windows), so a copy in your home gives
# nothing away. IPMIView's folder is noted next to the starters (ipmiview-folder) for ipmiview,
# and is in the IPMIView menu entry. iKVM Viewer becomes your program for .jnlp files if none is
# set or it's OpenWebStart's (other .jnlp files still go there unchanged); else it says how. An
# ipmiview command that isn't this one is left alone.

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIZES="16 24 32 48 64 128 256 512"
JNLPTYPE=application/x-java-jnlp-file

fail() {
    echo "$1" >&2
    exit 1
}

asroot() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

# The places of one kind: user or system
places() {
    if [ "$1" = user ]; then
        DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
        DEST="$DATA/iKVM-KeyPasta"
        APPS="$DATA/applications"
        ICONS="$DATA/icons/hicolor"
        BIN="$HOME/.local/bin"
        AS=""
    else
        DEST=/opt/iKVM-KeyPasta
        APPS=/usr/local/share/applications
        ICONS=/usr/local/share/icons/hicolor
        BIN=/usr/local/bin
        AS=asroot
    fi
}

refresh() {
    command -v update-desktop-database >/dev/null && $AS update-desktop-database -q "$APPS" || true
    command -v gtk-update-icon-cache >/dev/null && $AS gtk-update-icon-cache -q -t "$ICONS" || true
}

# Everything of one kind that's there: removed
remove() {
    places "$1"
    [ -e "$DEST" ] || [ -e "$APPS/IPMIView.desktop" ] || [ -L "$BIN/ipmiview" ] || return 0
    if [ -L "$BIN/ipmiview" ] && [ "$(readlink "$BIN/ipmiview")" = "$DEST/ipmiview-keypasta.sh" ]; then
        $AS rm -f "$BIN/ipmiview"
    fi
    $AS rm -f "$APPS/IPMIView.desktop" "$APPS/iKVM-Viewer.desktop"
    for s in $SIZES; do $AS rm -f "$ICONS/${s}x$s/apps/ikvm-keypasta.png"; done
    $AS rm -f "$ICONS/32x32/apps/ipmiview-keypasta.png"
    if [ -d "$DEST" ]; then
        $AS rm -f "$DEST/ipmiview-keypasta.sh" "$DEST/jnlp-keypasta.sh" "$DEST/iKVM-KeyPasta-agent.jar" "$DEST/ipmiview-folder"
        $AS rmdir "$DEST" 2>/dev/null || echo "$DEST kept: other files in it."
    fi
    refresh
    echo "Removed ($1)."
}

KIND=""
IPMIVIEW=""
for arg in "$@"; do
    case "$arg" in
        --uninstall) remove user; remove system; exit 0 ;;
        --user) KIND=user ;;
        --system) KIND=system ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) fail "Unknown option $arg" ;;
        *) IPMIVIEW="$arg" ;;
    esac
done

# IPMIView's folder: the argument, else the first found where the starter looks too
if [ -z "$IPMIVIEW" ]; then
    for d in "$HOME"/IPMIView* "$HOME"/.local/bin/IPMIView* "$HOME"/Applications/IPMIView* /opt/IPMIView* /usr/local/IPMIView*; do
        [ -f "$d/IPMIView20.jar" ] && { IPMIVIEW="$d"; break; }
    done
fi
[ -n "$IPMIVIEW" ] && [ -f "$IPMIVIEW/IPMIView20.jar" ] \
    || fail "IPMIView not found${IPMIVIEW:+ in $IPMIVIEW}. Run: bash install.sh <IPMIView folder>"
IPMIVIEW="$(cd "$IPMIVIEW" && pwd)"
case "$IPMIVIEW" in
    *[\"\`\$\\]*) fail "Please use an IPMIView folder without \" \` \$ \\ in its path." ;;
esac
[ -f "$ROOT/iKVM-KeyPasta-agent.jar" ] || fail "iKVM-KeyPasta-agent.jar not found in $ROOT."

# For you or for all: as IPMIView
if [ -z "$KIND" ]; then
    case "$IPMIVIEW/" in "$HOME"/*) KIND=user ;; *) KIND=system ;; esac
fi
places "$KIND"
OTHER=system; [ "$KIND" = system ] && OTHER=user
if [ "$KIND" = system ]; then
    echo "Installing for all users (IPMIView is in $IPMIVIEW; sudo may ask for your password)"
else
    echo "Installing for you (IPMIView is in your home folder)"
fi
remove "$OTHER" >/dev/null                          # a former install of the other kind
places "$KIND"

# Agent, starters, IPMIView's folder for them
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "$IPMIVIEW" > "$TMP/ipmiview-folder"
$AS install -d -m 755 "$DEST"
$AS install -m 644 "$ROOT/iKVM-KeyPasta-agent.jar" "$DEST/iKVM-KeyPasta-agent.jar"
$AS install -m 755 "$HERE/ipmiview-keypasta.sh" "$DEST/ipmiview-keypasta.sh"
$AS install -m 755 "$HERE/jnlp-keypasta.sh" "$DEST/jnlp-keypasta.sh"
$AS install -m 644 "$TMP/ipmiview-folder" "$DEST/ipmiview-folder"

# Menu entries, with this install's paths, and the icon
for f in IPMIView.desktop iKVM-Viewer.desktop; do
    sed -e "s|@DEST@|$DEST|g" -e "s|@IPMIVIEW@|\"$IPMIVIEW\"|g" "$HERE/$f" > "$TMP/$f"
    $AS install -D -m 644 "$TMP/$f" "$APPS/$f"
done
for s in $SIZES; do
    $AS install -D -m 644 "$ROOT/java-agent/res/keypasta/icon-$s.png" "$ICONS/${s}x$s/apps/ikvm-keypasta.png"
done
# IPMIView's own icon for its launcher (32x32 only); the viewer's launcher keeps the KeyPasta one
$AS install -D -m 644 "$ROOT/java-agent/res/keypasta/ipmiview.png" "$ICONS/32x32/apps/ipmiview-keypasta.png"
refresh

# The command ipmiview
LINK="$BIN/ipmiview"
if [ -e "$LINK" ] && ! { [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$DEST/ipmiview-keypasta.sh" ]; }; then
    echo "$LINK exists and isn't this launcher: left alone (start with $DEST/ipmiview-keypasta.sh instead)."
else
    $AS mkdir -p "$BIN"
    $AS ln -sfn "$DEST/ipmiview-keypasta.sh" "$LINK"
    echo "Command: ipmiview ($LINK; ipmiview --debug shows the agent's log)."
    case ":$PATH:" in
        *":$BIN:"*|*":$BIN/:"*) ;;
        *) echo "  $BIN isn't in your PATH yet (most systems add it at the next login if it exists)." ;;
    esac
fi

# The program for .jnlp files (yours)
CURRENT="$(xdg-mime query default "$JNLPTYPE" 2>/dev/null || true)"
case "$CURRENT" in
    ""|*[Oo]pen[Ww]eb[Ss]tart*|*javaws*|*[Ii]ced[Tt]ea*|iKVM-Viewer.desktop)
        if xdg-mime default iKVM-Viewer.desktop "$JNLPTYPE" 2>/dev/null; then
            echo ".jnlp files now open with iKVM Viewer (other .jnlp files still go to OpenWebStart)."
        else
            echo "To open .jnlp files with it: right-click one, Open With, iKVM Viewer."
        fi ;;
    *)
        echo ".jnlp files open with $CURRENT. To use iKVM Viewer: right-click one, Open With, iKVM Viewer,"
        echo "  or: xdg-mime default iKVM-Viewer.desktop $JNLPTYPE" ;;
esac

echo "Done: IPMIView and iKVM Viewer are in the app menu."
