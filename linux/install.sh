#!/bin/bash
# iKVM-KeyPasta, Linux: IPMIView and iKVM Viewer (.jnlp files) in the desktop's app menu, and the
# command ipmiview, all with the Java agent.
#
#   bash install.sh [--user|--system] [IPMIView folder or .tar.gz]   install or update
#   bash install.sh --uninstall                                      remove it again (both kinds)
#
# IPMIView: the folder or downloaded .tar.gz given; else an IPMIView already there (the one the
# last install used, else the newest in ~, ~/.local/bin, ~/Applications, /opt, /usr/local); else
# the newest IPMIView_*_Linux_x64.tar.gz in the current folder. A .tar.gz is unpacked into your
# home folder (--system: /opt), unless its folder is there already; the settings files (BMC list,
# saved logins) of the IPMIView the last install used are copied into a new one.
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

DOWNLOAD=https://www.supermicro.com/Bios/sw_download/1176/IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz
EXAMPLE=IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz

# The IPMIView folder the last install used (either kind), if it's still there
PREVIOUS=""
for note in "${XDG_DATA_HOME:-$HOME/.local/share}/iKVM-KeyPasta/ipmiview-folder" /opt/iKVM-KeyPasta/ipmiview-folder; do
    [ -f "$note" ] || continue
    d="$(cat "$note")"
    [ -f "$d/IPMIView20.jar" ] && { PREVIOUS="$d"; break; }
done

# The newest of the given paths (by the version in their names)
newest() {
    [ $# -gt 0 ] || return 0
    printf '%s\n' "$@" | sort -V | tail -n 1
}

# IPMIView: the argument; else one installed; else the newest download in the current folder
TARBALL=""
if [ -n "$IPMIVIEW" ] && [ -f "$IPMIVIEW" ]; then
    TARBALL="$IPMIVIEW"
    IPMIVIEW=""
elif [ -z "$IPMIVIEW" ]; then
    IPMIVIEW="$PREVIOUS"
    if [ -z "$IPMIVIEW" ]; then
        found=()
        for d in "$HOME"/IPMIView* "$HOME"/.local/bin/IPMIView* "$HOME"/Applications/IPMIView* /opt/IPMIView* /usr/local/IPMIView*; do
            [ -f "$d/IPMIView20.jar" ] && found+=("$d")
        done
        IPMIVIEW="$(newest "${found[@]}")"
    fi
    if [ -z "$IPMIVIEW" ]; then
        found=()
        for f in IPMIView*_Linux_x64.tar.gz; do
            [ -f "$f" ] && found+=("$PWD/$f")
        done
        TARBALL="$(newest "${found[@]}")"
        [ -n "$TARBALL" ] || fail "IPMIView not found: neither installed nor its download in this folder.
Download it ($DOWNLOAD)
and run this again with it, e.g.: bash $0 ~/Downloads/$EXAMPLE"
    fi
fi

# A download: unpacked into the home folder (--system: /opt), unless it's there already
if [ -n "$TARBALL" ]; then
    case "$TARBALL" in
        *.tar.gz|*.tgz) ;;
        *) fail "$TARBALL isn't an IPMIView download (.tar.gz) or folder. E.g.: bash $0 ~/Downloads/$EXAMPLE" ;;
    esac
    TOP="$(tar -tzf "$TARBALL" | head -n 1 | cut -d/ -f1)"
    [ -n "$TOP" ] && [ "$TOP" != . ] || fail "$TARBALL: no IPMIView folder in it."
    if [ "$KIND" = system ]; then PARENT=/opt; UNPACK=asroot; else PARENT="$HOME"; UNPACK=""; fi
    IPMIVIEW="$PARENT/$TOP"
    if [ -f "$IPMIVIEW/IPMIView20.jar" ]; then
        echo "IPMIView from $TARBALL is in $IPMIVIEW already."
    else
        echo "Unpacking $TARBALL into $PARENT"
        $UNPACK tar -xzf "$TARBALL" -C "$PARENT"
        [ -f "$IPMIVIEW/IPMIView20.jar" ] || fail "$TARBALL: no IPMIView20.jar in $IPMIVIEW."
        # the settings of the IPMIView used so far (its BMC list, saved logins and the like)
        if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$IPMIVIEW" ]; then
            for f in "$PREVIOUS"/*.properties; do
                [ -f "$f" ] && $UNPACK cp -p "$f" "$IPMIVIEW/"
            done
            echo "Settings copied from $PREVIOUS."
        fi
    fi
fi
[ -n "$IPMIVIEW" ] && [ -f "$IPMIVIEW/IPMIView20.jar" ] \
    || fail "IPMIView not found${IPMIVIEW:+ in $IPMIVIEW}. Run: bash $0 <IPMIView folder or download>, e.g. bash $0 ~/Downloads/$EXAMPLE"
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
