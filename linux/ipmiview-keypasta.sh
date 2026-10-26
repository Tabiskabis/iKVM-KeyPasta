#!/bin/bash
# iKVM-KeyPasta, Linux: starts IPMIView with the Java agent. Run by the desktop launcher
# (IPMIView.desktop, see install.sh) and as the command ipmiview.
#
# IPMIView's settings (IPMIView.properties: the BMC list; account.properties: saved IDs and
# passwords; a few more) are kept in ~/.config/ipmiview (under $XDG_CONFIG_HOME), the same for
# every IPMIView version; IPMIView's own folder stays as unpacked. IPMIView runs in its folder (it
# finds its files relative to the folder it runs in) and gets the settings folder as its second
# argument; the agent sends the settings files IPMIView opens by bare name there too
# (KEYPASTA_IPMIVIEW_SETTINGS). A settings file missing there is copied from IPMIView's folder as
# a starting point (e.g. a BMC list set up there), account.properties (saved passwords) only from
# an IPMIView folder of your own.
#
#   ipmiview-keypasta.sh [-d|--debug] [IPMIView folder]     (install.sh links it as ipmiview)
#
#   -d, --debug   the agent logs (decisions only, never typed keys or passwords) to
#                 ~/.local/state/iKVM-KeyPasta/agent.log, IPMIView's and its viewers' together,
#                 and the log is shown here as it grows, next to IPMIView's own output. The log
#                 of the run before: agent.log.old.
#
# IPMIView folder: the argument, else the newest IPMIView* folder (by the version in its name;
# of equal names, the one in the place listed first) in ~/.local/share, ~/.local/lib,
# ~/.local/bin, ~/Applications/IPMIView, ~/Applications, /opt/SUPERMICRO, /opt, /usr/local/share
# or /usr/share. So a new version is used as soon as its download is unpacked into one of them
# (e.g. tar -xzf IPMIView_<version>_Linux_x64.tar.gz -C ~/.local/share). The agent: next to this
# script (not next to a link to it).

HERE="$(dirname "$(readlink -f "$0")")"
AGENT="$HERE/iKVM-KeyPasta-agent.jar"

fail() {
    echo "$1" >&2
    command -v notify-send >/dev/null && notify-send -i ikvm-keypasta "IPMIView" "$1"
    exit 1
}

# The newest IPMIView* folder (with IPMIView20.jar) in the given places, by the version in its
# name (from its first digit on: IPMIView_2.25 and IPMIView2.26 compare as 2.25 and 2.26); of equal
# versions, the one in the place given first. (install.sh has the same.)
newest_ipmiview() {
    local i=0 place d n
    for place in "$@"; do
        i=$((i + 1))
        for d in "$place"/IPMIView*; do
            [ -f "$d/IPMIView20.jar" ] || continue
            n="${d##*/}"
            printf '%s\t%d\t%s\n' "${n#"${n%%[0-9]*}"}" "$i" "$d"
        done
    done | sort -t "$(printf '\t')" -k1,1V -k2,2nr | tail -n 1 | cut -f 3-
}

DEBUG=false
FOLDER=""
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=true ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) fail "Unknown option $arg (-d or --debug: log shown here)" ;;
        *) FOLDER="$arg" ;;
    esac
done

IPMIVIEW="$FOLDER"
[ -n "$IPMIVIEW" ] || IPMIVIEW="$(newest_ipmiview "$HOME/.local/share" "$HOME/.local/lib" "$HOME/.local/bin" \
    "$HOME/Applications/IPMIView" "$HOME/Applications" /opt/SUPERMICRO /opt /usr/local/share /usr/share)"
[ -n "$IPMIVIEW" ] && [ -f "$IPMIVIEW/IPMIView20.jar" ] \
    || fail "IPMIView not found${FOLDER:+ in $FOLDER}. Unpack its download (IPMIView_<version>_Linux_x64.tar.gz) into ~/.local/share, or give its folder: ipmiview <folder>"
[ -x "$IPMIVIEW/IPMIView20" ] || fail "$IPMIVIEW/IPMIView20 missing or not executable."

# The log: in the user's state folder, unless its path has a space or comma (JAVA_TOOL_OPTIONS
# can't quote, the agent's options are split at commas): then in the temp folder.
LOG=""
if $DEBUG; then
    LOG="${XDG_STATE_HOME:-$HOME/.local/state}/iKVM-KeyPasta/agent.log"
    case "$LOG" in *[\ ,]*) LOG="${TMPDIR:-/tmp}/iKVM-KeyPasta-$(id -u)/agent.log" ;; esac
    mkdir -p "$(dirname "$LOG")" || fail "Can't create $(dirname "$LOG")."
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
    : > "$LOG"
fi

# A -javaagent path that doesn't exist stops every Java program, and JAVA_TOOL_OPTIONS can't quote
# spaces: without the jar, or with a space in its path, IPMIView starts without the agent.
if [ -f "$AGENT" ] && [ "$AGENT" = "${AGENT// /}" ]; then
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-javaagent:$AGENT${LOG:+=log=$LOG}"
else
    echo "iKVM-KeyPasta agent not used: $AGENT missing or its path has a space." >&2
    LOG=""
fi

SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/ipmiview"
mkdir -p "$SETTINGS" || fail "Can't create $SETTINGS for IPMIView's settings."
find "$SETTINGS" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null   # links of the earlier way
for f in IPMIView.properties account.properties email.properties language.properties proxy.properties \
        smcrakp.properties sort.properties timeout.properties update.properties version.properties; do
    [ -f "$IPMIVIEW/$f" ] && [ ! -e "$SETTINGS/$f" ] || continue
    [ "$f" = account.properties ] && [ ! -O "$IPMIVIEW" ] && continue
    cp -p "$IPMIVIEW/$f" "$SETTINGS/$f"
done
export KEYPASTA_IPMIVIEW_SETTINGS="$SETTINGS/"
# IPMIView's tunnel for encrypted consoles (BMCSecurity/linux/stunnel64, also the one the .jnlp
# viewer brings) needs libnsl.so.1, an old glibc library (Fedora and others: a package of its own).
# Without it the console says "connect failed sd:N". Said here; IPMIView starts anyway.
if ! { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q 'libnsl\.so\.1 .*x86-64'; then
    echo "libnsl.so.1 is missing: encrypted KVM consoles won't connect (Fedora: sudo dnf install libnsl)." >&2
fi
cd "$IPMIVIEW" || exit 1
if [ -z "$LOG" ]; then
    exec ./IPMIView20 - "$SETTINGS/"
fi

# Debug: IPMIView in the foreground (its output here), the agent's log followed alongside; Ctrl+C
# ends both. Viewers still open keep running and logging to the file.
echo "IPMIView: $IPMIVIEW (settings in $SETTINGS)"
echo "Agent log: $LOG"
tail -n +1 -F "$LOG" 2>/dev/null &
TAIL=$!
trap 'kill $TAIL 2>/dev/null' EXIT
./IPMIView20 - "$SETTINGS/"
