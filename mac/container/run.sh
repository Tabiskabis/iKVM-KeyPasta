#!/bin/bash
# Build (first run) and start the IPMIView console container, then open it in the browser.
# Works with Docker Desktop, OrbStack, Colima (with the docker command: brew install colima docker)
# or Podman (its own podman command, which takes docker's commands).
#
#   ./run.sh [options]
#     --ipmiview DIR   IPMIView folder (has IPMIView20.jar). Default: auto-detected.
#     --agent JAR      iKVM-KeyPasta agent jar.             Default: auto-detected.
#     --vmedia-dir DIR any folder with ISO/IMG files for virtual media; read-only at /root/vMedia.
#                      Default: none.
#     --screencap-dir DIR  folder for the viewer's screenshots and recordings; read-write at
#                      /root/screencap. Default: none (they stay in the container).
#     --jnlp FILE      open a .jnlp (Java Web Start) instead of IPMIView: in a container of its own,
#                      next to IPMIView's and other .jnlp ones (ikvm-jnlp-PORT, the first free port
#                      of 6201-6299 unless --port is given), which ends with its viewer.
#     --agent-args A   agent options (see Config.java), e.g. mouseRate=30.
#     --relax          accept the BMC's expired iKVM cert (roll the BMC clock back too).
#     --viewer-tabs    each iKVM viewer IPMIView starts on a desktop of its own, in a browser tab
#                      of its own: ports 6101-6199 (the app opens them as they come up).
#     --layout L       X keyboard layout (ch, ch(fr), de, gb, us). Default: us.
#     --port N         browser port; VNC on N - 400. Default: 6100 (IPMIView), 6201-6299 (.jnlp).
#     --lan            publish the ports on all of this computer's addresses (default: 127.0.0.1
#                      only). Needs a password: VNC_PASSWORD in the environment (not an option, so
#                      it's on no command line); with it, also on 127.0.0.1, VNC apps and the browser
#                      view ask for it.
#     --detach         start in the background (no interactive terminal); don't open the browser.
#     --rebuild        rebuild the image.
#     --debug          a .jnlp's IcedTea-Web says what it downloads and why that fails (-verbose).
set -euo pipefail
cd "$(dirname "$0")"
# A double-clicked app gets a bare PATH; add the usual CLI locations so docker is found whether it
# comes from Docker Desktop, OrbStack (~/.orbstack/bin) or Colima.
export PATH="$HOME/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/opt/podman/bin:/usr/bin:/bin:$PATH"

IMAGE="ikvm-keypasta-console"
NAME="ikvm-console"
IPMIVIEW="" ; AGENT="" ; AGENT_ARGS="" ; VMEDIA_DIR="" ; SCREENCAP_DIR="" ; JNLP="" ; RELAX=false ; TABS=false ; DEBUG=false
LAYOUT="us" ; PORT="" ; REBUILD=false ; DETACH=false ; BIND=127.0.0.1

while [ $# -gt 0 ]; do
    case "$1" in
        --ipmiview) IPMIVIEW="$2"; shift 2;;
        --agent)    AGENT="$2"; shift 2;;
        --agent-args) AGENT_ARGS="$2"; shift 2;;
        --vmedia-dir)    VMEDIA_DIR="$2"; shift 2;;
        --screencap-dir) SCREENCAP_DIR="$2"; shift 2;;
        --jnlp)     JNLP="$2"; shift 2;;
        --relax)    RELAX=true; shift;;
        --viewer-tabs) TABS=true; shift;;
        --layout)   LAYOUT="$2"; shift 2;;
        --port)     PORT="$2"; shift 2;;
        --detach)   DETACH=true; shift;;
        --lan)      BIND=0.0.0.0; shift;;
        --rebuild)  REBUILD=true; shift;;
        --debug)    DEBUG=true; shift;;
        *) echo "unknown option: $1" >&2; exit 1;;
    esac
done

# The container command: docker (Docker Desktop, OrbStack, Colima), else podman. Every "docker"
# below is that one.
if command -v docker >/dev/null 2>&1; then CLI=docker
elif command -v podman >/dev/null 2>&1; then CLI=podman
else
    echo "No container engine found. Install OrbStack, Docker Desktop, Podman, or Colima (brew install colima docker)." >&2
    exit 1
fi
docker() { command "$CLI" "$@"; }

# Make sure a container engine is actually running — start it if needed, so the user never has to.
# A GUI-launched app also doesn't inherit DOCKER_HOST, and OrbStack/Colima keep their socket outside
# the default /var/run/docker.sock, so we point at whichever socket exists.
engine_sock() {
    for s in "$HOME/.orbstack/run/docker.sock" "$HOME/.docker/run/docker.sock" \
             "$HOME/.colima/default/docker.sock" "$HOME/.rd/docker.sock" /var/run/docker.sock; do
        [ -S "$s" ] && { echo "$s"; return 0; }
    done
    return 0   # no socket yet is normal (engine still starting); never trip `set -e`
}
point_at_socket() { [ "$CLI" = docker ] || return 0; local s; s=$(engine_sock); [ -n "$s" ] && export DOCKER_HOST="unix://$s"; return 0; }
reachable() { docker info >/dev/null 2>&1; }

point_at_socket
if ! reachable; then
    if [ "$CLI" = podman ]; then
        # Podman on a Mac runs in its own Linux VM, "podman machine": made on first use (downloads it)
        if [ -z "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ]; then
            echo "Setting up Podman's Linux VM (podman machine init, a download, once)…"
            podman machine init || { echo "podman machine init failed." >&2; exit 1; }
        fi
        echo "Starting Podman…"; podman machine start >/dev/null 2>&1 &
    elif [ -d /Applications/OrbStack.app ]; then echo "Starting OrbStack…";        open -ga OrbStack
    elif [ -d /Applications/Docker.app ];   then echo "Starting Docker Desktop…";  open -ga Docker
    elif command -v colima >/dev/null 2>&1; then echo "Starting Colima…";          colima start >/dev/null 2>&1 &
    else echo "No container engine installed. Install OrbStack or Docker Desktop." >&2; exit 1; fi
    echo "Waiting for the container engine to come up (first start can take a minute)…"
    for _ in $(seq 1 120); do point_at_socket; reachable && break; sleep 1; done
    reachable || { echo "The container engine ($CLI) didn't come up. Start it once by hand (OrbStack, Docker Desktop, colima start, podman machine start) and retry." >&2; exit 1; }
    echo "Engine ready."
fi

# IPMIView is only needed for IPMIView mode; a .jnlp runs the BMC's own viewer, no IPMIView required.
if [ -z "$JNLP" ]; then
    if [ -z "$IPMIVIEW" ]; then
        for d in "$HOME"/.local/bin/IPMIView* /Applications/IPMIView* "$HOME"/IPMIView* /opt/IPMIView*; do
            [ -f "$d/IPMIView20.jar" ] && { IPMIVIEW="$d"; break; }
        done
    fi
    [ -n "$IPMIVIEW" ] && [ -f "$IPMIVIEW/IPMIView20.jar" ] || {
        echo "No IPMIView found. Either install IPMIView, or open your BMC's .jnlp instead (--jnlp FILE)." >&2; exit 1; }
fi

# Rebuild when asked, when the image is missing, or when the files of this folder (Dockerfile,
# entrypoint.sh, the scripts copied in) aren't the ones the image was built from: their checksum,
# kept in the image as a label. Not by file dates (a .built marker before): every build of the app
# copies this folder anew, so every app build rebuilt the image, changed or not.
if command -v shasum >/dev/null; then SUM="shasum -a 256"; else SUM=sha256sum; fi
HASH="$(find . -maxdepth 1 -type f ! -name '.*' | LC_ALL=C sort | while read -r f; do echo "$f"; cat "$f"; done | $SUM | cut -c1-16)"
need_build=false
$REBUILD && need_build=true
BUILT="$(docker image inspect -f '{{ index .Config.Labels "ikvm-keypasta.files" }}' "$IMAGE" 2>/dev/null || true)"
[ "$BUILT" = "$HASH" ] || need_build=true
if $need_build; then
    echo "Building $IMAGE (amd64)… first build downloads the JRE; rebuilds reuse the cache offline."
    # Legacy builder (DOCKER_BUILDKIT=0) reuses the cached base image without re-resolving its tag from
    # docker.io on every rebuild — BuildKit does, and that fails on flaky/blocked/IPv6-broken networks.
    if ! DOCKER_BUILDKIT=0 docker build --platform linux/amd64 --label "ikvm-keypasta.files=$HASH" -t "$IMAGE" .; then
        echo "Image build failed (see above) — not starting a stale container." >&2
        exit 1
    fi
fi
# Earlier builds of the image, unnamed since (a rebuild names the new one), are never used again:
# removed on every start, ours only (the Dockerfile's label), in the background.
( docker image prune -f --filter "label=ikvm-keypasta=console" >/dev/null 2>&1 & )

# .jnlp containers that ended stay (no --rm: the app reads their output, then removes them); those
# left over (the app wasn't running) go now, their names free again.
for n in $( (docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null || true) ); do
    case "$n" in ikvm-jnlp-*) docker rm "$n" >/dev/null 2>&1 || true ;; esac
done
# A .jnlp: a container of its own, next to IPMIView's and other .jnlp ones, named after its port
# (the first of 6201-6299 no container of ours has). IPMIView's: one, on 6100.
if [ -n "$JNLP" ]; then
    if [ -z "$PORT" ]; then
        taken=" $( (docker ps -a --format '{{.Names}}' 2>/dev/null || true) | tr '\n' ' ') "
        for p in $(seq 6201 6299); do
            case "$taken" in *" ikvm-jnlp-$p "*) ;; *) PORT=$p; break ;; esac
        done
        [ -n "$PORT" ] || { echo "99 .jnlp consoles are open already: stop one first." >&2; exit 1; }
    fi
    NAME="ikvm-jnlp-$PORT"
fi
[ -n "$PORT" ] || PORT=6100

# clear any previous instance so --name is free and the port is released
docker rm -f "$NAME" >/dev/null 2>&1 || true

# The browser view (noVNC) on $PORT, and the same desktop for a VNC app (TigerVNC Viewer) on
# $PORT - 400. Numbered, the last two digits the same for both:
#   IPMIView 0: 6100/5700, its viewers 1-99: 6101-6199/5701-5799, .jnlp 1-99: 6201-6299/5801-5899
# (59xx left alone: 5900 is macOS's own Screen Sharing, 5901 on other VNC servers'). On this
# computer only (127.0.0.1) unless --lan: without a password, anyone on the network could use
# IPMIView, with its saved BMC logins; so --lan needs one.
if [ "$BIND" != 127.0.0.1 ] && [ -z "${VNC_PASSWORD:-}" ]; then
    echo "Reachable from the network only with a password (VNC_PASSWORD): not started." >&2
    exit 1
fi
VNC=$((PORT - 400))
ARGS=( run --platform linux/amd64 --name "$NAME" -p "${BIND}:${PORT}:6080" -p "${BIND}:${VNC}:5900" )
[ -n "${VNC_PASSWORD:-}" ] && ARGS+=( -e VNC_PASSWORD )      # the value from this environment
ARGS+=( -e "VNC_PORT=6080" -e "LAYOUT=${LAYOUT}" -e "IGNORE_EXPIRED_CERT=${RELAX}" -e "KEYPASTA_DEBUG=${DEBUG}" )
[ -n "$AGENT_ARGS" ] && ARGS+=( -e "AGENT_ARGS=${AGENT_ARGS}" )
$TABS && [ -z "$JNLP" ] && ARGS+=( -e "VIEWER_TABS=true" -p "${BIND}:6101-6199:6101-6199" -p "${BIND}:5701-5799:5701-5799" )
[ -n "$IPMIVIEW" ] && ARGS+=( -v "${IPMIVIEW}:/ipmiview" )
# IPMIView's settings, shared with the native start (ipmiview-keypasta.sh keeps them there too)
if [ "$(uname)" = Darwin ]; then SETTINGS="$HOME/Library/Application Support/IPMIView"
else SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/ipmiview"; fi
mkdir -p "$SETTINGS" && ARGS+=( -v "${SETTINGS}:/settings" )
# Files for the container go to a folder in the home folder first: Colima and Podman share only
# the home folder (and a few others) with their Linux VM. The app's agent copy is in the temp folder
# (/var/folders), the .jnlp copy was in /tmp: there they came out as empty folders (Colima), the
# agent wasn't loaded. Each container its own copy, replaced whole (mv): a running one keeps its own.
if [ "$(uname)" = Darwin ]; then SHARE="$HOME/Library/Application Support/iKVM-KeyPasta/container"
else SHARE="${XDG_CACHE_HOME:-$HOME/.cache}/iKVM-KeyPasta/container"; fi
# The agent's settings (agent.properties: KeyPasta Preferences, the paste hotkeys): the native
# start's own folder, so both use the same file; keypasta-websockify reads the hotkeys from it too
if [ "$(uname)" = Darwin ]; then AGENT_SETTINGS="$HOME/Library/Application Support/iKVM-KeyPasta"
else AGENT_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/iKVM-KeyPasta"; fi
mkdir -p "$AGENT_SETTINGS"
ARGS+=( -v "${AGENT_SETTINGS}:/keypasta-settings" -e "KEYPASTA_SETTINGS_DIR=/keypasta-settings" )
mkdir -p "$SHARE/agent-$NAME"
if [ -n "$AGENT" ] && [ -f "$AGENT" ]; then
    cp "$AGENT" "$SHARE/agent-$NAME/.new.jar" && mv -f "$SHARE/agent-$NAME/.new.jar" "$SHARE/agent-$NAME/iKVM-KeyPasta-agent.jar"
    ARGS+=( -v "$SHARE/agent-$NAME:/agent:ro" )
else
    echo "note: no agent jar; running without it"
fi
# Colima and Podman: other folders than the home folder aren't there in the container
if [ "$CLI" = podman ] || case "${DOCKER_HOST:-}" in *colima*) true;; *) false;; esac; then
    IPM="$IPMIVIEW"; [ -n "$JNLP" ] && IPM=""            # a .jnlp's container doesn't need it
    for d in "$IPM" "$VMEDIA_DIR" "$SCREENCAP_DIR"; do
        case "$d" in ""|"$HOME"/*) ;; *) echo "note: $d is outside your home folder: $CLI's Linux VM may not share it (then it's empty in the container)";; esac
    done
fi
[ -n "$VMEDIA_DIR" ] && [ -d "$VMEDIA_DIR" ] && ARGS+=( -v "${VMEDIA_DIR}:/root/vMedia:ro" )
[ -n "$SCREENCAP_DIR" ] && [ -d "$SCREENCAP_DIR" ] && ARGS+=( -v "${SCREENCAP_DIR}:/root/screencap" )
if [ -n "$JNLP" ]; then
    [ -f "$JNLP" ] || { echo "jnlp not found: $JNLP" >&2; exit 1; }
    cp "$JNLP" "$SHARE/${NAME}.jnlp"
    ARGS+=( -v "$SHARE/${NAME}.jnlp:/launch.jnlp:ro" -e "MODE=jnlp" -e "JNLP=/launch.jnlp" )
fi

URL="http://localhost:${PORT}/"
if $DETACH; then
    if [ -n "$JNLP" ]; then
        ARGS+=( -d "$IMAGE" )                         # ends with its viewer; the app removes it
    else
        ARGS+=( --restart unless-stopped -d "$IMAGE" )   # so the desktop "Reboot container" restarts it
    fi
    docker "${ARGS[@]}"
    echo "Container '${NAME}' started. Console: ${URL} (VNC: localhost:${VNC})"
    echo "console-port: ${PORT}"                     # for the app
else
    ARGS+=( --rm -it "$IMAGE" )
    echo "Console: ${URL} (VNC: localhost:${VNC})"
    ( sleep 3; command -v open >/dev/null && open "$URL" || true ) &
    exec "$CLI" "${ARGS[@]}"
fi
