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
#                      of 6090-6099 unless --port is given), which ends with its viewer.
#     --agent-args A   agent options (see Config.java), e.g. paste=ctrl+shift+V.
#     --relax          accept the BMC's expired iKVM cert (roll the BMC clock back too).
#     --viewer-tabs    each iKVM viewer IPMIView starts on a desktop of its own, in a browser tab
#                      of its own: ports 6081-6089 (the app opens them as they come up).
#     --layout L       X keyboard layout (ch, ch(fr), de, gb, us). Default: us.
#     --port N         browser port. Default: 6080 (IPMIView), 6090-6099 (.jnlp).
#     --detach         start in the background (no interactive terminal); don't open the browser.
#     --rebuild        rebuild the image.
set -euo pipefail
cd "$(dirname "$0")"
# A double-clicked app gets a bare PATH; add the usual CLI locations so docker is found whether it
# comes from Docker Desktop, OrbStack (~/.orbstack/bin) or Colima.
export PATH="$HOME/.orbstack/bin:/Applications/OrbStack.app/Contents/MacOS/xbin:/opt/homebrew/bin:/usr/local/bin:/opt/podman/bin:/usr/bin:/bin:$PATH"

IMAGE="ikvm-keypasta-console"
NAME="ikvm-console"
IPMIVIEW="" ; AGENT="" ; AGENT_ARGS="" ; VMEDIA_DIR="" ; SCREENCAP_DIR="" ; JNLP="" ; RELAX=false ; TABS=false
LAYOUT="us" ; PORT="" ; REBUILD=false ; DETACH=false

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
        --rebuild)  REBUILD=true; shift;;
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

# Rebuild when asked, when the image is missing, or when our Dockerfile/entrypoint changed since the
# last build (tracked with a .built marker) — so an updated app never runs a stale image.
need_build=false
$REBUILD && need_build=true
docker image inspect "$IMAGE" >/dev/null 2>&1 || need_build=true
{ [ Dockerfile -nt .built ] || [ entrypoint.sh -nt .built ] || [ keypasta.js -nt .built ] || [ keypasta-websockify -nt .built ] || [ bmc-check -nt .built ]; } && need_build=true
if $need_build; then
    echo "Building $IMAGE (amd64)… first build downloads the JRE; rebuilds reuse the cache offline."
    # Legacy builder (DOCKER_BUILDKIT=0) reuses the cached base image without re-resolving its tag from
    # docker.io on every rebuild — BuildKit does, and that fails on flaky/blocked/IPv6-broken networks.
    if DOCKER_BUILDKIT=0 docker build --platform linux/amd64 -t "$IMAGE" .; then
        touch .built
    else
        echo "Image build failed (see above) — not starting a stale container." >&2
        exit 1
    fi
fi

# A .jnlp: a container of its own, next to IPMIView's and other .jnlp ones, named after its port
# (the first of 6090-6099 no container of ours has). IPMIView's: one, on 6080.
if [ -n "$JNLP" ]; then
    if [ -z "$PORT" ]; then
        taken=" $( (docker ps -a --format '{{.Names}}' 2>/dev/null || true) | tr '\n' ' ') "
        for p in $(seq 6090 6099); do
            case "$taken" in *" ikvm-jnlp-$p "*) ;; *) PORT=$p; break ;; esac
        done
        [ -n "$PORT" ] || { echo "Ten .jnlp consoles are open already: stop one first." >&2; exit 1; }
    fi
    NAME="ikvm-jnlp-$PORT"
fi
[ -n "$PORT" ] || PORT=6080

# clear any previous instance so --name is free and the port is released
docker rm -f "$NAME" >/dev/null 2>&1 || true

# Browser view only (noVNC on $PORT). We never publish 5900 on the host: x11vnc listens on 5900
# *inside* the container for websockify, and exposing it would clash with whatever uses 5900 on the Mac.
ARGS=( run --platform linux/amd64 --name "$NAME" -p "${PORT}:6080" )
ARGS+=( -e "VNC_PORT=6080" -e "LAYOUT=${LAYOUT}" -e "IGNORE_EXPIRED_CERT=${RELAX}" )
[ -n "$AGENT_ARGS" ] && ARGS+=( -e "AGENT_ARGS=${AGENT_ARGS}" )
$TABS && [ -z "$JNLP" ] && ARGS+=( -e "VIEWER_TABS=true" -p "6081-6089:6081-6089" )
[ -n "$IPMIVIEW" ] && ARGS+=( -v "${IPMIVIEW}:/ipmiview" )
# IPMIView's settings, shared with the native start (ipmiview-keypasta.sh keeps them there too)
SETTINGS="$HOME/.config/ipmiview"
mkdir -p "$SETTINGS" && ARGS+=( -v "${SETTINGS}:/settings" )
# Files for the container go to a folder in the home folder first: Colima and Podman share only
# the home folder (and a few others) with their Linux VM. The app's agent copy is in the temp folder
# (/var/folders), the .jnlp copy was in /tmp: there they came out as empty folders (Colima), the
# agent wasn't loaded. Each container its own copy, replaced whole (mv): a running one keeps its own.
if [ "$(uname)" = Darwin ]; then SHARE="$HOME/Library/Application Support/iKVM-KeyPasta/container"
else SHARE="${XDG_CACHE_HOME:-$HOME/.cache}/iKVM-KeyPasta/container"; fi
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

URL="http://localhost:${PORT}/novnc/vnc.html?autoconnect=1&resize=remote"
if $DETACH; then
    if [ -n "$JNLP" ]; then
        ARGS+=( --rm -d "$IMAGE" )                    # gone when its viewer ends
    else
        ARGS+=( --restart unless-stopped -d "$IMAGE" )   # so the desktop "Reboot container" restarts it
    fi
    docker "${ARGS[@]}"
    echo "Container '${NAME}' started. Console: ${URL}"
    echo "console-port: ${PORT}"                     # for the app
else
    ARGS+=( --rm -it "$IMAGE" )
    echo "Console: ${URL}"
    ( sleep 3; command -v open >/dev/null && open "$URL" || true ) &
    exec "$CLI" "${ARGS[@]}"
fi
