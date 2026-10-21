#!/bin/bash
# iKVM-KeyPasta, Linux: opens .jnlp files (Java Web Start) with OpenWebStart. The program for
# .jnlp files (iKVM-Viewer.desktop, see install.sh), or started without a file: then it takes
# launch.jnlp from your Downloads folder (BMC web interface, "Launch Console").
#
#   jnlp-keypasta.sh [-d|--debug] [file.jnlp]
#
#   -d, --debug   the agent logs (decisions only, never typed keys or passwords) to
#                 ~/.local/state/iKVM-KeyPasta/agent.log, shown here as it grows (Ctrl+C ends
#                 the display, not the viewer). The log of the run before: agent.log.old.
#
# The iKVM viewer (.jnlp with tw.com.aten.ikvm): with the Java agent, for this start only (no
# JAVA_TOOL_OPTIONS for all Java programs, which none survives if the jar goes missing), and with
# Java 8 (JAVAVERSION below: the viewer's .jnlp asks for options Java 17 and newer refuse; set in
# the copy, so no OpenWebStart setting forces it on other programs). The .jnlp is moved out of
# Downloads (the browser then saves the next one under the same name) to
# ~/.cache/iKVM-KeyPasta/launch-<date>-<time>-<BMC>-<random>.jnlp, readable by you only (it holds
# the console session's login data), and kept there for a week after it was last opened (older
# ones are deleted at each start). Other .jnlp files: OpenWebStart, unchanged.

# Java version for the iKVM viewer (OpenWebStart's syntax: 1.8* = any 1.8). Empty: as the .jnlp says
JAVAVERSION="1.8*"
# OpenWebStart's javaws: $JAVAWS, else javaws in PATH, else its usual install folders
JAVAWS="${JAVAWS:-}"

HERE="$(dirname "$(readlink -f "$0")")"     # also when started through a link
AGENT="$HERE/iKVM-KeyPasta-agent.jar"

fail() {
    echo "$1" >&2
    command -v notify-send >/dev/null && notify-send -i ikvm-keypasta "iKVM Viewer" "$1"
    exit 1
}

DEBUG=false
JNLP=""
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=true ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) fail "Unknown option $arg (-d or --debug: log shown here)" ;;
        *) JNLP="$arg" ;;
    esac
done
if [ -z "$JNLP" ]; then
    DOWNLOADS="$(xdg-user-dir DOWNLOAD 2>/dev/null)"
    DOWNLOADS="${DOWNLOADS:-$HOME/Downloads}"
    # the newest: browsers save another launch.jnlp as "launch (1).jnlp" and so on
    JNLP="$DOWNLOADS/launch.jnlp"
    for f in "$DOWNLOADS"/launch*.jnlp; do
        [ -f "$f" ] && { [ ! -f "$JNLP" ] || [ "$f" -nt "$JNLP" ]; } && JNLP="$f"
    done
fi
[ -f "$JNLP" ] || fail "No .jnlp file: $JNLP not found."

if [ -z "$JAVAWS" ]; then
    for c in "$(command -v javaws)" "$HOME/openwebstart/javaws" /opt/openwebstart/javaws; do
        [ -n "$c" ] && [ -x "$c" ] && { JAVAWS="$c"; break; }
    done
fi
[ -n "$JAVAWS" ] || fail "OpenWebStart (javaws) not found: install it, or set JAVAWS at the top of $0."

# Not the iKVM viewer: OpenWebStart as usual
if ! grep -qi "tw\.com\.aten\.ikvm" "$JNLP"; then
    exec "$JAVAWS" "$JNLP"
fi

# The .jnlp out of Downloads, named after date, time and the BMC (from its codebase)
COPYDIR="${XDG_CACHE_HOME:-$HOME/.cache}/iKVM-KeyPasta"
(umask 077 && mkdir -p "$COPYDIR") || fail "Can't create $COPYDIR."
BMC="$(grep -o -i -m1 'codebase="[a-z]*://[^/"]*' "$JNLP" | sed -e 's|.*://||' -e 's|:[0-9]*$||' -e 's|[^A-Za-z0-9.-]|_|g')"
COPY="$COPYDIR/launch-$(date +%Y%m%d-%H%M%S)-${BMC:-unknown}-$RANDOM.jnlp"
mv "$JNLP" "$COPY" || fail "Couldn't move $JNLP."
chmod 600 "$COPY"
# copies not opened for a week: deleted; this one counts as opened now
touch "$COPY"
find "$COPYDIR" -maxdepth 1 -type f -name 'launch-*.jnlp' -mtime +6 -delete 2>/dev/null || true
# the Java version the .jnlp asks for (<j2se version="..."> or <java version="...">)
if [ -n "$JAVAVERSION" ]; then
    sed -i -E "s/(<(j2se|java)[^>]*[[:space:]]version[[:space:]]*=[[:space:]]*)([\"'])[^\"']*([\"'])/\\1\\3$JAVAVERSION\\4/" "$COPY"
fi

LOG=""
if $DEBUG; then
    LOG="${XDG_STATE_HOME:-$HOME/.local/state}/iKVM-KeyPasta/agent.log"
    case "$LOG" in *[\ ,]*) LOG="${TMPDIR:-/tmp}/iKVM-KeyPasta-$(id -u)/agent.log" ;; esac
    mkdir -p "$(dirname "$LOG")" || fail "Can't create $(dirname "$LOG")."
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
    : > "$LOG"
fi

# A -javaagent path that doesn't exist stops every Java program, and JAVA_TOOL_OPTIONS can't quote
# spaces: without the jar, or with a space in its path, the viewer starts without the agent.
if [ -f "$AGENT" ] && [ "$AGENT" = "${AGENT// /}" ]; then
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-javaagent:$AGENT${LOG:+=log=$LOG}"
else
    echo "iKVM-KeyPasta agent not used: $AGENT missing or its path has a space." >&2
    LOG=""
fi

if [ -z "$LOG" ]; then
    exec "$JAVAWS" "$COPY"
fi

# Debug: OpenWebStart may hand the viewer to a JVM of its own and return: the log is followed
# until Ctrl+C, which ends only the display.
echo ".jnlp: $COPY"
echo "Agent log: $LOG (Ctrl+C ends the display, not the viewer)"
"$JAVAWS" "$COPY" &
exec tail -n +1 -F "$LOG" 2>/dev/null
