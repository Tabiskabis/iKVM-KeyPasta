#!/bin/bash
# iKVM-KeyPasta, Linux: starts IPMIView with the Java agent. Run by the desktop launcher
# (IPMIView.desktop, see install.sh) and as the command ipmiview.
#
# IPMIView keeps its settings (IPMIView.properties: the BMC list; account.properties: saved IDs
# and passwords; a few more) in the folder it runs in. If you may write to IPMIView's folder (or
# you're root), it runs there. Otherwise (installed for all users) it runs in ~/.config/ipmiview,
# which links to everything in IPMIView's folder (it finds its files relative to the folder it
# runs in), except the settings files: those are your own. On the first start, the folder's
# settings files are copied as your starting point (e.g. a BMC list set up there), except
# account.properties (passwords are personal). The links are made again on every start.
#
#   ipmiview-keypasta.sh [-d|--debug] [IPMIView folder]     (install.sh links it as ipmiview)
#
#   -d, --debug   the agent logs (decisions only, never typed keys or passwords) to
#                 ~/.local/state/iKVM-KeyPasta/agent.log, IPMIView's and its viewers' together,
#                 and the log is shown here as it grows, next to IPMIView's own output. The log
#                 of the run before: agent.log.old.
#
# IPMIView folder: the argument, else $IPMIVIEW, else the one install.sh noted next to this
# script (ipmiview-folder), else the first IPMIView folder found in the home
# folder, ~/.local/bin, ~/Applications, /opt or /usr/local. The agent: next to this script (not
# next to a link to it).

HERE="$(dirname "$(readlink -f "$0")")"
NOTED="$HERE/ipmiview-folder"
AGENT="$HERE/iKVM-KeyPasta-agent.jar"

fail() {
    echo "$1" >&2
    command -v notify-send >/dev/null && notify-send -i ikvm-keypasta "IPMIView" "$1"
    exit 1
}

find_ipmiview() {
    local d
    for d in "$HOME"/IPMIView* "$HOME"/.local/bin/IPMIView* "$HOME"/Applications/IPMIView* /opt/IPMIView* /usr/local/IPMIView*; do
        [ -f "$d/IPMIView20.jar" ] && { echo "$d"; return; }
    done
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

[ -z "$FOLDER" ] && [ -z "${IPMIVIEW:-}" ] && [ -f "$NOTED" ] && IPMIVIEW="$(head -n 1 "$NOTED")"
IPMIVIEW="${FOLDER:-${IPMIVIEW:-$(find_ipmiview)}}"
[ -n "$IPMIVIEW" ] && [ -f "$IPMIVIEW/IPMIView20.jar" ] \
    || fail "IPMIView not found${IPMIVIEW:+ in $IPMIVIEW}. Give its folder: ipmiview-keypasta.sh <folder>"
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

cd "$IPMIVIEW" || exit 1
if [ "$(id -u)" != 0 ] && [ ! -w "$IPMIVIEW" ]; then
    WORK="${XDG_CONFIG_HOME:-$HOME/.config}/ipmiview"
    mkdir -p "$WORK" || fail "Can't create $WORK for IPMIView's settings."
    find "$WORK" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null
    for e in "$IPMIVIEW"/* "$IPMIVIEW"/.[!.]*; do
        [ -e "$e" ] || continue
        name="${e##*/}"
        [ -e "$WORK/$name" ] && continue
        case "$name" in
            account.properties) ;;
            *.properties) cp "$e" "$WORK/$name" ;;
            *) ln -s "$e" "$WORK/$name" ;;
        esac
    done
    cd "$WORK" || exit 1
fi
if [ -z "$LOG" ]; then
    exec ./IPMIView20
fi

# Debug: IPMIView in the foreground (its output here), the agent's log followed alongside; Ctrl+C
# ends both. Viewers still open keep running and logging to the file.
echo "IPMIView: $IPMIVIEW (runs in $(pwd))"
echo "Agent log: $LOG"
tail -n +1 -F "$LOG" 2>/dev/null &
TAIL=$!
trap 'kill $TAIL 2>/dev/null' EXIT
./IPMIView20
