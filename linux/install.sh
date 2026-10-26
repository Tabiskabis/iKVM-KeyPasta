#!/bin/bash
# iKVM-KeyPasta, Linux: IPMIView and iKVM Viewer (.jnlp files) in the desktop's app menu, and the
# command ipmiview, all with the Java agent.
#
#   bash install.sh [--user|--system] [--jnlp|--no-jnlp] [IPMIView folder or .tar.gz]
#                                                  install or update
#   bash install.sh --remove                       remove it again (both kinds; or --uninstall)
#
# The menu entry and ipmiview start the newest IPMIView* folder (by the version in its name) in
# ~/.local/share, ~/.local/lib, ~/.local/bin, ~/Applications/IPMIView, ~/Applications,
# /opt/SUPERMICRO, /opt, /usr/local/share or /usr/share (see ipmiview-keypasta.sh). A new IPMIView
# needs no new install: unpack its download into one of them (e.g. ~/.local/share). Its settings
# (BMC list, saved logins) are in ~/.config/ipmiview, the same for every version.
#
#   for you (--user, the default; no root needed): ~/.local/share/iKVM-KeyPasta (agent,
#     starters), ~/.local/share/applications, ~/.local/share/icons, ~/.local/bin/ipmiview.
#     IPMIView: the folder or .tar.gz given; else the newest of those in the places above and the
#     downloads (IPMIView*_Linux_x64.tar.gz) in the current folder and Downloads. A download is
#     unpacked into ~/.local/share, a folder given that isn't in one of the places copied there.
#   for all users (--system, as root: asks for sudo, so that no user can change what the others
#     run): /opt/iKVM-KeyPasta, /usr/local/share/applications, /usr/local/share/icons,
#     /usr/local/bin/ipmiview. IPMIView: the folder or .tar.gz given; else the newest of those in
#     /opt/SUPERMICRO, /opt, /usr/local/share, /usr/share and the downloads in the current folder
#     and ~/Downloads. Unpacked or copied into /opt (other users can't read your home folder).
# Installing one kind removes the other (an update of a --system install needs --system again).
# Making iKVM Viewer your program for .jnlp files (other .jnlp files still go to
# OpenWebStart unchanged) is asked first; --jnlp does it without asking, --no-jnlp leaves it as it
# is (as does a run without a terminal to ask in). An ipmiview command that isn't this one is left
# alone.

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIZES="16 24 32 48 64 128 256 512"
JNLPTYPE=application/x-java-jnlp-file
TAB="$(printf '\t')"
# Where IPMIView is looked for, as in ipmiview-keypasta.sh
USER_PLACES=("$HOME/.local/share" "$HOME/.local/lib" "$HOME/.local/bin" "$HOME/Applications/IPMIView" "$HOME/Applications")
SYSTEM_PLACES=(/opt/SUPERMICRO /opt /usr/local/share /usr/share)

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

# Everything of one kind that's there: removed (IPMIView itself stays)
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
        # ipmiview-folder: written by earlier versions
        $AS rm -f "$DEST/ipmiview-keypasta.sh" "$DEST/jnlp-keypasta.sh" "$DEST/iKVM-KeyPasta-agent.jar" "$DEST/ipmiview-folder"
        $AS rmdir "$DEST" 2>/dev/null || echo "$DEST kept: other files in it."
    fi
    refresh
    echo "Removed ($1)."
}

# The newest IPMIView* folder (with IPMIView20.jar) in the given places, by the version in its
# name (from its first digit on: IPMIView_2.25 and IPMIView2.26 compare as 2.25 and 2.26); of equal
# versions, the one in the place given first. (ipmiview-keypasta.sh has the same.)
newest_ipmiview() {
    local i=0 place d n
    for place in "$@"; do
        i=$((i + 1))
        for d in "$place"/IPMIView*; do
            [ -f "$d/IPMIView20.jar" ] || continue
            n="${d##*/}"
            printf '%s\t%d\t%s\n' "${n#"${n%%[0-9]*}"}" "$i" "$d"
        done
    done | sort -t "$TAB" -k1,1V -k2,2nr | tail -n 1 | cut -f 3-
}

# The version in a folder's or download's name: from its first digit on, without .tar.gz
version_of() {
    local n="${1##*/}"
    n="${n%.tar.gz}"
    n="${n%.tgz}"
    echo "${n#"${n%%[0-9]*}"}"
}

# The newest of the given files by the version in their names, whatever folder they're in
newest_file() {
    local f
    for f in "$@"; do [ -f "$f" ] && printf '%s\t%s\n' "$(version_of "$f")" "$f"; done | sort -t "$TAB" -k1,1V | tail -n 1 | cut -f 2-
}

KIND=user
GIVEN=""
JNLPDEFAULT=ask
for arg in "$@"; do
    case "$arg" in
        --remove|--uninstall) remove user; remove system; exit 0 ;;
        --user) KIND=user ;;
        --system) KIND=system ;;
        --jnlp) JNLPDEFAULT=yes ;;
        --no-jnlp) JNLPDEFAULT=no ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) fail "Unknown option $arg" ;;
        *) GIVEN="$arg" ;;
    esac
done

DOWNLOAD=https://www.supermicro.com/Bios/sw_download/1176/IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz
EXAMPLE=IPMIView_2.25.0_build.260812_bundleJRE_Linux_x64.tar.gz

# The agent: built here if it isn't (a git clone has none: *.jar is in .gitignore)
if [ ! -f "$ROOT/iKVM-KeyPasta-agent.jar" ]; then
    command -v javac >/dev/null 2>&1 && command -v jar >/dev/null 2>&1 \
        || fail "iKVM-KeyPasta-agent.jar not found in $ROOT, and no JDK here to build it.
Install a JDK 9 or newer (e.g. sudo apt install default-jdk-headless) and run this again."
    echo "Building iKVM-KeyPasta-agent.jar"
    sh "$ROOT/java-agent/build.sh" || fail "Building iKVM-KeyPasta-agent.jar failed (see above)."
    [ -f "$ROOT/iKVM-KeyPasta-agent.jar" ] || fail "iKVM-KeyPasta-agent.jar not found in $ROOT after building it."
fi

# Where IPMIView is looked for and where a download or folder goes
if [ "$KIND" = system ]; then
    SEARCH=("${SYSTEM_PLACES[@]}")
    TARGET=/opt
    PUT=asroot
    DOWNLOADS="$HOME/Downloads"
    DOWNLOADED=("$PWD"/IPMIView*_Linux_x64.tar.gz "$HOME"/Downloads/IPMIView*_Linux_x64.tar.gz)
else
    SEARCH=("${USER_PLACES[@]}" "${SYSTEM_PLACES[@]}")
    TARGET="$HOME/.local/share"
    PUT=""
    # xdg-user-dir answers $HOME when no Downloads folder is set, so ~/Downloads as well
    DOWNLOADS="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    case "$DOWNLOADS" in ""|"$HOME"|"$HOME/") DOWNLOADS="$HOME/Downloads" ;; esac
    DOWNLOADED=("$PWD"/IPMIView*_Linux_x64.tar.gz "$DOWNLOADS"/IPMIView*_Linux_x64.tar.gz "$HOME"/Downloads/IPMIView*_Linux_x64.tar.gz)
fi

# IPMIView: the folder or download given; else the newest of those there and those downloaded
IPMIVIEW=""
TARBALL=""
if [ -n "$GIVEN" ]; then
    if [ -f "$GIVEN/IPMIView20.jar" ]; then
        IPMIVIEW="$(cd "$GIVEN" && pwd)"
    elif [ -f "$GIVEN" ]; then
        TARBALL="$GIVEN"
    else
        fail "$GIVEN: neither an IPMIView folder nor its download (.tar.gz). E.g.: bash $0 ~/Downloads/$EXAMPLE"
    fi
else
    IPMIVIEW="$(newest_ipmiview "${SEARCH[@]}")"
    TARBALL="$(newest_file "${DOWNLOADED[@]}")"
    if [ -n "$IPMIVIEW" ] && [ -n "$TARBALL" ]; then
        NEWER="$(printf '%s\n' "$(version_of "$IPMIVIEW")" "$(version_of "$TARBALL")" | sort -V | tail -n 1)"
        if [ "$NEWER" = "$(version_of "$IPMIVIEW")" ]; then TARBALL=""; else IPMIVIEW=""; fi
    fi
    [ -n "$IPMIVIEW$TARBALL" ] || fail "IPMIView not found: neither in ${SEARCH[*]} nor downloaded to $PWD or $DOWNLOADS.
Download it ($DOWNLOAD)
and run this again with it, e.g.: bash $0 ~/Downloads/$EXAMPLE"
fi

# A download: unpacked (as is: the starters find it by its folder's name)
if [ -n "$TARBALL" ]; then
    case "$TARBALL" in
        *.tar.gz|*.tgz) ;;
        *) fail "$TARBALL isn't an IPMIView download (.tar.gz) or folder. E.g.: bash $0 ~/Downloads/$EXAMPLE" ;;
    esac
    TOP="$(tar -tzf "$TARBALL" | head -n 1 | cut -d/ -f1)"
    case "$TOP" in
        IPMIView*) ;;
        *) fail "$TARBALL: no IPMIView* folder in it." ;;
    esac
    IPMIVIEW="$TARGET/$TOP"
    if [ -f "$IPMIVIEW/IPMIView20.jar" ]; then
        echo "IPMIView from $TARBALL is in $IPMIVIEW already."
    else
        echo "Unpacking $TARBALL into $TARGET"
        $PUT mkdir -p "$TARGET"
        $PUT tar --no-same-owner -xzf "$TARBALL" -C "$TARGET"
        [ -f "$IPMIVIEW/IPMIView20.jar" ] || fail "$TARBALL: no IPMIView20.jar in $IPMIVIEW."
        if [ "$KIND" = system ]; then asroot chmod -R a+rX,go-w "$IPMIVIEW"; fi
    fi
else
    # A folder: where the starters look, under a name they look for; else copied there
    NAME="${IPMIVIEW##*/}"
    case "$NAME" in
        IPMIView*) ;;
        *) fail "$IPMIVIEW: the menu entry and ipmiview only find folders whose name starts with IPMIView: please rename it." ;;
    esac
    FOUND=""
    for place in "${SEARCH[@]}"; do [ "${IPMIVIEW%/*}" = "$place" ] && FOUND=yes; done
    if [ -z "$FOUND" ]; then
        if [ -f "$TARGET/$NAME/IPMIView20.jar" ]; then
            echo "$TARGET/$NAME is there already: used instead of $IPMIVIEW."
        else
            echo "Copying $IPMIVIEW into $TARGET (where the menu entry and ipmiview look for it)"
            $PUT mkdir -p "$TARGET"
            $PUT cp -R "$IPMIVIEW" "$TARGET/$NAME"
            if [ "$KIND" = system ]; then asroot chmod -R a+rX,go-w "$TARGET/$NAME"; fi
        fi
        IPMIVIEW="$TARGET/$NAME"
    fi
fi
echo "IPMIView: $IPMIVIEW"
STARTS="$(newest_ipmiview "${USER_PLACES[@]}" "${SYSTEM_PLACES[@]}")"
[ "$STARTS" = "$IPMIVIEW" ] || echo "  Note: ipmiview and the menu entry start the newest one there is: $STARTS"

places "$KIND"
OTHER=system; [ "$KIND" = system ] && OTHER=user
if [ "$KIND" = system ]; then
    echo "Installing for all users (sudo may ask for your password)"
else
    echo "Installing for you"
fi
remove "$OTHER" >/dev/null                          # a former install of the other kind
places "$KIND"

# Agent and starters
$AS install -d -m 755 "$DEST"
$AS install -m 644 "$ROOT/iKVM-KeyPasta-agent.jar" "$DEST/iKVM-KeyPasta-agent.jar"
$AS install -m 755 "$HERE/ipmiview-keypasta.sh" "$DEST/ipmiview-keypasta.sh"
$AS install -m 755 "$HERE/jnlp-keypasta.sh" "$DEST/jnlp-keypasta.sh"
$AS rm -f "$DEST/ipmiview-folder"                   # written by earlier versions

# The icons, then the menu entries with this install's paths. The entries name their icon by its
# full path, not by name: WSLg (Linux apps in Windows' Start menu and taskbar) looks names up in
# /usr/share/icons and /usr/share/pixmaps only, not in /usr/local/share/icons or ~/.local/share/icons,
# and showed a blank icon for the pinned entry and its windows. Icons first: WSLg reads an entry as
# soon as it appears.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for s in $SIZES; do
    $AS install -D -m 644 "$ROOT/java-agent/res/keypasta/icon-$s.png" "$ICONS/${s}x$s/apps/ikvm-keypasta.png"
done
# IPMIView's own icon for its launcher (32x32 only); the viewer's launcher keeps the KeyPasta one
$AS install -D -m 644 "$ROOT/java-agent/res/keypasta/ipmiview.png" "$ICONS/32x32/apps/ipmiview-keypasta.png"
for f in IPMIView.desktop iKVM-Viewer.desktop; do
    sed -e "s|@DEST@|$DEST|g" -e "s|@ICONS@|$ICONS|g" "$HERE/$f" > "$TMP/$f"
    $AS install -D -m 644 "$TMP/$f" "$APPS/$f"
done
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

# The program for .jnlp files (yours): asked first, unless --jnlp or --no-jnlp
CURRENT="$(xdg-mime query default "$JNLPTYPE" 2>/dev/null || true)"
HOWTO="To open .jnlp files with iKVM Viewer: right-click one, Open With, iKVM Viewer,
  or: xdg-mime default iKVM-Viewer.desktop $JNLPTYPE (or run this again with --jnlp)"
if [ "$CURRENT" = iKVM-Viewer.desktop ]; then
    echo ".jnlp files open with iKVM Viewer."
else
    case "$CURRENT" in
        ""|*[Oo]pen[Ww]eb[Ss]tart*|*javaws*|*[Ii]ced[Tt]ea*) SUGGEST=y ;;  # Enter: yes
        *) SUGGEST=n ;;                                                     # someone else's: Enter: no
    esac
    if [ "$JNLPDEFAULT" = ask ]; then
        if [ -t 0 ]; then
            if [ "$SUGGEST" = y ]; then PROMPT="[Y/n]"; else PROMPT="[y/N]"; fi
            echo ".jnlp files open with ${CURRENT:-no program set}. iKVM Viewer only takes iKVM's, and passes other .jnlp files to OpenWebStart."
            read -r -p "Open .jnlp files with iKVM Viewer? $PROMPT " answer || answer=""
            case "${answer:-$SUGGEST}" in [Yy]*) JNLPDEFAULT=yes ;; *) JNLPDEFAULT=no ;; esac
        else
            JNLPDEFAULT=no
        fi
    fi
    if [ "$JNLPDEFAULT" = yes ] && xdg-mime default iKVM-Viewer.desktop "$JNLPTYPE" 2>/dev/null; then
        echo ".jnlp files now open with iKVM Viewer (other .jnlp files still go to OpenWebStart)."
    else
        [ "$JNLPDEFAULT" = yes ] && echo "Couldn't set the program for .jnlp files (xdg-mime)."
        echo ".jnlp files open with ${CURRENT:-no program set}. $HOWTO"
    fi
fi

echo "Done: IPMIView and iKVM Viewer are in the app menu."
