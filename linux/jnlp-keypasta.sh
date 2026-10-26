#!/bin/bash
# iKVM-KeyPasta, Linux: opens .jnlp files (Java Web Start) with OpenWebStart or IcedTea-Web. The
# program for .jnlp files (iKVM-Viewer.desktop, see install.sh), or started without a file: then
# it takes launch.jnlp from your Downloads folder (BMC web interface, "Launch Console").
#
#   jnlp-keypasta.sh [-d|--debug] [file.jnlp]
#
#   -d, --debug   the agent logs (decisions only, never typed keys or passwords) to
#                 ~/.local/state/iKVM-KeyPasta/agent.log, shown here as it grows (Ctrl+C ends
#                 the display, not the viewer). The log of the run before: agent.log.old.
#                 IcedTea-Web also says what it downloads and why that fails (-verbose).
#
# The iKVM viewer (.jnlp with tw.com.aten.ikvm): with the Java agent, for this start only (no
# JAVA_TOOL_OPTIONS for all Java programs, which none survives if the jar goes missing). The .jnlp
# is copied to ~/.cache/iKVM-KeyPasta/launch-<date>-<time>-<BMC>-<random>.jnlp, readable by you
# only (it holds the console session's login data), and kept there for a week after it was last
# opened (older ones are deleted at each start). The one in Downloads is removed only once a viewer
# window has opened from it (the agent creates the file KEYPASTA_VIEWER_OPENED names when the
# viewer's window shows, which it builds after connecting and logging in), within VIEWERWAIT
# seconds, and if it's still the same file (the browser then saves the next one under the same
# name). Any other outcome (no window, no agent) leaves it there for another try. Other .jnlp
# files: javaws, unchanged.
#
# javaws: $JAVAWS, else OpenWebStart's in its usual install folders, else javaws in PATH (often
# IcedTea-Web's, Debian/Ubuntu package icedtea-netx). Which one it is: by its real path
# (OpenWebStart's has "openwebstart" in it).
#   OpenWebStart: Java 8 asked for in the copy (JAVAVERSION: the viewer's .jnlp asks for options
#     Java 17 and newer refuse; set in the copy, so no OpenWebStart setting forces it on other
#     programs); it downloads the jars and the Java itself.
#   IcedTea-Web: run as in the Mac app's container. Its settings are a profile of its own
#     (~/.config/iKVM-KeyPasta/icedtea-web: OpenWebStart, a fork of it, keeps its own in
#     ~/.config/icedtea-web, and a Java chosen there that IcedTea-Web can't start made it panic),
#     with ITWJAVA as its Java: Java 11 (IcedTea-Web needs 9 or newer, its security manager is
#     gone in 24, and the viewer's .jnlp is tested on 11 only). The jars are fetched from the BMC
#     beforehand (keypasta-jnlp-jars): BMCs serve them Pack200-compressed only, which IcedTea-Web
#     no longer unpacks; Java 11's unpack200 does. The viewer runs in IcedTea-Web's own JVM
#     (-Xnofork), the agent given there (-J-javaagent).

# Java version for the iKVM viewer with OpenWebStart (its syntax: 1.8* = any 1.8). Empty: as the
# .jnlp says
JAVAVERSION="1.8*"
# javaws (OpenWebStart's or IcedTea-Web's): $JAVAWS, else see above
JAVAWS="${JAVAWS:-}"
# Seconds to wait for a viewer window to open from the .jnlp before leaving it in Downloads
# (includes answering IcedTea-Web's or OpenWebStart's questions, OpenWebStart downloading a Java)
VIEWERWAIT=300
# Java for IcedTea-Web and the viewer (a JRE or JDK folder): $ITWJAVA, else the newest Java 11
# in /usr/lib/jvm (also /usr/lib64/jvm, /opt/java, ~/.jdks), else the newest of 9 to 23 there
ITWJAVA="${ITWJAVA:-}"

HERE="$(dirname "$(readlink -f "$0")")"     # also when started through a link
AGENT="$HERE/iKVM-KeyPasta-agent.jar"

fail() {
    echo "$1" >&2
    command -v notify-send >/dev/null && notify-send -i ikvm-keypasta "iKVM Viewer" "$1"
    exit 1
}

# The major version of the Java in folder $1 (8 for 1.8), from its release file, else java -version
java_major() {
    local v
    v="$(sed -n 's/^JAVA_VERSION="\([^"]*\)".*/\1/p' "$1/release" 2>/dev/null)"
    [ -n "$v" ] || v="$(env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS "$1/bin/java" -version 2>&1 \
        | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
    case "$v" in 1.*) v="${v#1.}" ;; esac
    v="${v%%[!0-9]*}"
    echo "${v:-0}"
}

# The Java folders found, each once (links resolved): "<major><TAB><folder>" per line
javas() {
    local d r
    for d in /usr/lib/jvm/* /usr/lib64/jvm/* /opt/java/* "$HOME/.jdks"/*; do
        [ -x "$d/bin/java" ] || continue
        r="$(readlink -f "$d")"
        printf '%s\t%s\n' "$(java_major "$r")" "$r"
    done | sort -u
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
    # xdg-user-dir answers $HOME when no Downloads folder is set
    case "$DOWNLOADS" in ""|"$HOME"|"$HOME/") DOWNLOADS="$HOME/Downloads" ;; esac
    # the newest: browsers save another launch.jnlp as "launch (1).jnlp" and so on
    JNLP="$DOWNLOADS/launch.jnlp"
    for f in "$DOWNLOADS"/launch*.jnlp; do
        [ -f "$f" ] && { [ ! -f "$JNLP" ] || [ "$f" -nt "$JNLP" ]; } && JNLP="$f"
    done
fi
[ -f "$JNLP" ] || fail "No .jnlp file: $JNLP not found."

if [ -z "$JAVAWS" ]; then
    for c in "$HOME/openwebstart/javaws" /opt/openwebstart/javaws "$(command -v javaws)"; do
        [ -n "$c" ] && [ -x "$c" ] && { JAVAWS="$c"; break; }
    done
fi
[ -n "$JAVAWS" ] || fail "No javaws found: install OpenWebStart or IcedTea-Web (e.g. sudo apt install icedtea-netx openjdk-11-jre), or set JAVAWS at the top of $0."
case "$(readlink -f "$(command -v "$JAVAWS")")" in
    *[Oo]pen[Ww]eb[Ss]tart*) KIND=ows ;;
    *) KIND=itw ;;
esac

# Not the iKVM viewer: javaws as usual
if ! grep -qi "tw\.com\.aten\.ikvm" "$JNLP"; then
    exec "$JAVAWS" "$JNLP"
fi

# The viewer's encrypted console runs the stunnel it brings, which needs libnsl.so.1 (an old glibc
# library: Fedora and others have it as a package of its own). Without it: "connect failed sd:N".
# Started anyway (a console without encryption doesn't need it).
if ! { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q 'libnsl\.so\.1 .*x86-64'; then
    echo "libnsl.so.1 is missing: the viewer's encrypted console won't connect (Fedora: sudo dnf install libnsl)." >&2
    command -v notify-send >/dev/null && notify-send -i ikvm-keypasta "iKVM Viewer" "libnsl.so.1 is missing: the encrypted console won't connect (Fedora: sudo dnf install libnsl)."
fi

# The .jnlp copied out of Downloads, named after date, time and the BMC (from its codebase)
COPYDIR="${XDG_CACHE_HOME:-$HOME/.cache}/iKVM-KeyPasta"
(umask 077 && mkdir -p "$COPYDIR") || fail "Can't create $COPYDIR."
BMC="$(grep -o -i -m1 'codebase="[a-z]*://[^/"]*' "$JNLP" | sed -e 's|.*://||' -e 's|:[0-9]*$||' -e 's|[^A-Za-z0-9.-]|_|g')"
COPY="$COPYDIR/launch-$(date +%Y%m%d-%H%M%S)-${BMC:-unknown}-$RANDOM.jnlp"
(umask 077 && cp "$JNLP" "$COPY") || fail "Couldn't copy $JNLP to $COPY."
SUM="$(cksum < "$COPY")"     # the original's, before the copy is changed below
# copies not opened for a week (and IcedTea-Web's jars for them): deleted; this one counts as
# opened now
touch "$COPY"
find "$COPYDIR" -mindepth 1 -maxdepth 1 -name 'launch-*' -mtime +6 -exec rm -rf {} + 2>/dev/null || true

LOG=""
if $DEBUG; then
    LOG="${XDG_STATE_HOME:-$HOME/.local/state}/iKVM-KeyPasta/agent.log"
    case "$LOG" in *[\ ,]*) LOG="${TMPDIR:-/tmp}/iKVM-KeyPasta-$(id -u)/agent.log" ;; esac
    mkdir -p "$(dirname "$LOG")" || fail "Can't create $(dirname "$LOG")."
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
    : > "$LOG"
fi

if [ "$KIND" = ows ]; then
    # the Java version the .jnlp asks for (<j2se version="..."> or <java version="...">)
    if [ -n "$JAVAVERSION" ]; then
        sed -i -E "s/(<(j2se|java)[^>]*[[:space:]]version[[:space:]]*=[[:space:]]*)([\"'])[^\"']*([\"'])/\\1\\3$JAVAVERSION\\4/" "$COPY"
    fi
    # A -javaagent path that doesn't exist stops every Java program, and JAVA_TOOL_OPTIONS can't
    # quote spaces: without the jar, or with a space in its path, the viewer starts without the agent.
    if [ -f "$AGENT" ] && [ "$AGENT" = "${AGENT// /}" ]; then
        export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-javaagent:$AGENT${LOG:+=log=$LOG}"
    else
        echo "iKVM-KeyPasta agent not used: $AGENT missing or its path has a space." >&2
        LOG=""
    fi
    START=("$JAVAWS" "$COPY")
else
    # IcedTea-Web's Java
    if [ -z "$ITWJAVA" ]; then
        ALL="$(javas)"
        ITWJAVA="$(awk -F '\t' '$1 == 11' <<<"$ALL" | tail -n 1 | cut -f 2-)"
        [ -n "$ITWJAVA" ] || ITWJAVA="$(awk -F '\t' '$1 >= 9 && $1 <= 23' <<<"$ALL" | sort -n | tail -n 1 | cut -f 2-)"
        [ -n "$ITWJAVA" ] || fail "IcedTea-Web needs Java 11 for the iKVM viewer (9 to 23 might do): install it (e.g. sudo apt install openjdk-11-jre), or set ITWJAVA at the top of $0."
        [ "$(java_major "$ITWJAVA")" = 11 ] || echo "No Java 11 found, trying Java $(java_major "$ITWJAVA") ($ITWJAVA)." >&2
    fi
    [ -x "$ITWJAVA/bin/java" ] || fail "ITWJAVA: $ITWJAVA/bin/java missing."
    # unpack200 for the jars: this Java's, else any Java 13 or older's
    UNPACK200="$ITWJAVA/bin/unpack200"
    if [ ! -x "$UNPACK200" ]; then
        for d in $(javas | awk -F '\t' '$1 >= 5 && $1 <= 13' | cut -f 2-); do
            [ -x "$d/bin/unpack200" ] && { UNPACK200="$d/bin/unpack200"; break; }
        done
    fi
    export UNPACK200
    # The jars from the BMC into a folder next to the copy, and a copy of that loading them there
    FETCH="$HERE/keypasta-jnlp-jars"
    [ -f "$FETCH" ] || FETCH="$HERE/../mac/container/keypasta-jnlp-jars"     # in the repository
    [ -f "$FETCH" ] || fail "keypasta-jnlp-jars missing next to $0: install again (install.sh)."
    command -v python3 >/dev/null || fail "IcedTea-Web needs python3 here (to fetch the console's files from the BMC)."
    JARS="${COPY%.jnlp}-jars"
    LOCAL="${COPY%.jnlp}-local.jnlp"
    (umask 077 && JAVA_HOME="$ITWJAVA" python3 "$FETCH" "$COPY" "$JARS" "$LOCAL") \
        || fail "Couldn't fetch the console's files from the BMC (see above). The .jnlp is valid a minute or two only: download a new one if it's older."
    # Its own profile: settings and trusted publishers in ~/.config/iKVM-KeyPasta/icedtea-web,
    # its Java set there (deployment.jre.dir: the Rust javaws takes it before JAVA_HOME), the shell
    # javaws takes JAVA_HOME. The agent keeps its own settings folder (KEYPASTA_SETTINGS_DIR).
    export KEYPASTA_SETTINGS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/iKVM-KeyPasta"
    PROFILE="$KEYPASTA_SETTINGS_DIR/icedtea-web"
    mkdir -p "$PROFILE/icedtea-web" || fail "Can't create $PROFILE."
    PROPS="$PROFILE/icedtea-web/deployment.properties"
    touch "$PROPS"
    sed -i '/^deployment\.jre\.dir[[:space:]]*=/d' "$PROPS"
    echo "deployment.jre.dir=$ITWJAVA" >> "$PROPS"
    export XDG_CONFIG_HOME="$PROFILE" JAVA_HOME="$ITWJAVA"
    # The agent on javaws' command line (-J: to its JVM, quoted, so a space in the path is fine);
    # the commas in the agent's options still can't be in it (LOG above)
    AGENTARG=()
    if [ -f "$AGENT" ]; then
        AGENTARG=("-J-javaagent:$AGENT${LOG:+=log=$LOG}")
    else
        echo "iKVM-KeyPasta agent not used: $AGENT missing." >&2
        LOG=""
    fi
    # JAVA_TOOL_OPTIONS of your own: onto the command line too (the shell javaws reads the Java
    # version from the first line java -version prints, "Picked up JAVA_TOOL_OPTIONS" with it)
    if [ -n "${JAVA_TOOL_OPTIONS:-}" ]; then
        read -r -a OWN <<<"$JAVA_TOOL_OPTIONS"
        AGENTARG=("${OWN[@]/#/-J}" "${AGENTARG[@]}")
        unset JAVA_TOOL_OPTIONS
    fi
    VERBOSE=()
    $DEBUG && VERBOSE=(-verbose)
    START=("$JAVAWS" "${AGENTARG[@]}" "${VERBOSE[@]}" -nosecurity -Xnofork "$LOCAL")
fi

# The .jnlp in Downloads: removed once the agent has created OPENED (the viewer's window is
# showing), if it's still the same file; kept if javaws (IcedTea-Web's, which runs the viewer
# itself) ended first, or after VIEWERWAIT seconds. OpenWebStart's javaws may hand the viewer to
# a JVM of its own and return, so only the time counts there.
OPENED="${COPY%.jnlp}.opened"
rm -f "$OPENED"
export KEYPASTA_VIEWER_OPENED="$OPENED"
watch_viewer() {
    local javaws="$1" i=0
    while [ $i -lt $((VIEWERWAIT * 5)) ]; do
        if [ -e "$OPENED" ]; then
            rm -f "$OPENED"
            if [ "$(cksum < "$JNLP" 2>/dev/null)" = "$SUM" ] && rm -f "$JNLP"; then
                $DEBUG && echo "Viewer window opened: $JNLP removed."
            fi
            return
        fi
        [ "$KIND" = itw ] && ! kill -0 "$javaws" 2>/dev/null && break
        sleep 0.2
        i=$((i + 1))
    done
    [ -f "$JNLP" ] && fail "No viewer window opened from $JNLP: kept there for another try."
}

if $DEBUG; then
    echo ".jnlp: $COPY ($KIND: $JAVAWS${ITWJAVA:+, Java $ITWJAVA})"
    [ -n "$LOG" ] && echo "Agent log: $LOG (Ctrl+C ends the display, not the viewer)"
fi
"${START[@]}" &
watch_viewer $! &
# Debug: the log followed until Ctrl+C, which ends only the display (programs started in the
# background here ignore it); else: until javaws and the watch have ended
if [ -n "$LOG" ]; then
    exec tail -n +1 -F "$LOG" 2>/dev/null
fi
wait
