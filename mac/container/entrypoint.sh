#!/bin/bash
# Starts a headless X server, a VNC bridge to the browser, then IPMIView (or a .jnlp) with the
# Java agent. See Dockerfile / run.sh.
set -e

: "${IPMIVIEW:=/ipmiview}"
: "${AGENT:=/agent/iKVM-KeyPasta-agent.jar}"
: "${IGNORE_EXPIRED_CERT:=false}"   # accept the BMC's expired iKVM cert (roll the BMC clock back too)
: "${LAYOUT:=us}"                   # X keyboard layout, e.g. ch, ch(fr), de, gb
: "${GEOMETRY:=1920x1080x24}"
: "${VNC_PORT:=6080}"
: "${AGENT_ARGS:=}"                 # extra agent options (see Config.java)
: "${MODE:=ipmiview}"               # ipmiview | jnlp
: "${JNLP:=}"
: "${VIEWER_TABS:=false}"            # each iKVM viewer on a desktop of its own, a browser tab each
WORK=/ipmiview-work                  # where IPMIView runs (see below, "IPMIView keeps its settings"); next to /ipmiview, not in /root

log() { echo "[keypasta] $*"; }

# The desktops' VNC security. VNC_PASSWORD (from the app, through run.sh's environment, never on a
# command line): a real password, for VNC apps (keypasta-vncauth just relays) and the browser view
# (noVNC asks for it); VNC keeps its first 8 characters. Without: no password, and VNC apps may
# give any (keypasta-vncauth). Gone from the environment afterwards: IPMIView and the viewers
# don't inherit it.
if [ -n "${VNC_PASSWORD:-}" ]; then
    printf '%s\n' "$VNC_PASSWORD" | tigervncpasswd -f > /root/.keypasta-vncpasswd
    chmod 600 /root/.keypasta-vncpasswd
    XVNC_SEC="-SecurityTypes VncAuth -PasswordFile /root/.keypasta-vncpasswd"
    VNCAUTH_MODE="--relay"
    log "VNC: password required (VNC apps and the browser view)"
else
    XVNC_SEC="-SecurityTypes None"
    VNCAUTH_MODE=""
    log "VNC: no password; VNC apps may give any"
fi
unset VNC_PASSWORD

export DISPLAY=:0
# A restarted container (the desktop menu's "Reboot container") still has its /tmp: X server locks
# left there would keep the desktops from starting.
rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
# always present, so the viewer's file pickers show them (the app's folders are mounted there):
# vMedia for virtual media images, screencap for screenshots and recordings
mkdir -p /root/vMedia /root/screencap
# IcedTea-Web (the .jnlp start) keeps its settings and the certificates you chose to trust
# ("Always trust content from this publisher") in ~/.config/icedtea-web. That goes with the
# container, so keep it in the Mac's ~/Library/Application Support/IPMIView/icedtea-web
# (/settings, see run.sh). Not OpenWebStart's ~/.config/icedtea-web on the Mac: its settings hold
# Mac paths and JVM choices.
# The agent's settings (KeyPasta Preferences) are its own file, the native start's: run.sh mounts
# the Mac's folder (KEYPASTA_SETTINGS_DIR).
if [ -d /settings ]; then
    mkdir -p /settings/icedtea-web "$HOME/.config"
    rm -rf "$HOME/.config/icedtea-web"
    ln -s /settings/icedtea-web "$HOME/.config/icedtea-web"
fi

# TigerVNC Xvnc is the X server and the VNC server in one, and supports live desktop resize
# (SetDesktopSize). With noVNC resize=remote the desktop follows the browser window instead of a
# fixed screen being scaled. Size and depth come from GEOMETRY (WxHxD).
GEOM_WH="${GEOMETRY%x*}"; GEOM_D="${GEOMETRY##*x}"
# The desktop name is the browser tab title (noVNC, see Dockerfile)
DESKTOP_NAME="IPMIView"
# a .jnlp: "iKVM <BMC>", the BMC its first argument (the address), so its tab tells which
if [ "$MODE" = jnlp ]; then
    JNLP_BMC="$(grep -o '<argument>[A-Za-z0-9.:-]*</argument>' "$JNLP" 2>/dev/null | head -n 1 | sed 's#</*argument>##g')"
    DESKTOP_NAME="iKVM ${JNLP_BMC:-Viewer}"
fi
# RawKeyboard: each key by its place (noVNC sends it, as a QEMU extended key event), as on a real
# keyboard; the layout (LAYOUT, the Mac's) makes the characters. Without it Xvnc went by the
# character: a key of the Mac's layout that the container's lacks (ö, é, §) got a made-up key code,
# nothing on the remote. SendPrimary=0: a selection isn't sent to the browser (only copying is).
# On the container's loopback only (15900, -localhost): the browser view (websockify) connects there,
# and VNC apps through keypasta-vncauth on 5900 (run.sh publishes it, on the Mac's 127.0.0.1 unless
# the app's "This Mac only" is off), which also takes any password when there is none ($XVNC_SEC).
# shellcheck disable=SC2086
Xvnc :0 -geometry "$GEOM_WH" -depth "$GEOM_D" -rfbport 15900 -localhost $XVNC_SEC \
     -RawKeyboard=1 -SendPrimary=0 \
     -AlwaysShared -AcceptSetDesktopSize=1 -desktop "$DESKTOP_NAME" >/tmp/xvnc.log 2>&1 &
for i in $(seq 1 100); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
xdpyinfo >/dev/null 2>&1 || { log "X/VNC server did not start"; cat /tmp/xvnc.log; exit 1; }
setxkbmap "$LAYOUT" 2>/dev/null || log "couldn't set keyboard layout '$LAYOUT' (using default)"
# Grayscale anti-aliased fonts (VNC + Java Swing look awful without this).
printf "Xft.antialias: 1\nXft.hinting: 1\nXft.hintstyle: hintslight\nXft.rgba: none\n" | xrdb -merge 2>/dev/null || true
# Java/Swing reads font AA from XSETTINGS, not Xft resources. Publish FORCED GRAYSCALE AA
# (RGBA "none" = grayscale, not subpixel) so it is correct on any display, including over VNC.
cat > "$HOME/.xsettingsd" <<'EOF'
Xft/Antialias 1
Xft/Hinting 1
Xft/HintStyle "hintslight"
Xft/RGBA "none"
EOF
xsettingsd -c "$HOME/.xsettingsd" >/tmp/xsettingsd.log 2>&1 &

# IPMIView's main window fills the desktop, without decorations, and follows its resize (window
# class "IPMIView" as the agent names it, else from its main class IPMIView20.IPMIView20). Its dialogs (type != normal) and the iKVM
# viewers (main class tw.com.aten.ikvm.KVMMain) stay normal windows with title bars.
mkdir -p "$HOME/.config/openbox"
# The iKVM viewer's main window filling its desktop without a frame (a viewer's own tab, a .jnlp's
# container): its window class (iKVM-Viewer as the agent names it, else from its main class) and
# its title when it opens ("Java Viewer"; "Java iKVM Viewer ..." once connected). Not its other
# windows (virtual keyboard, preferences, macros: same class, other titles): maximized without a
# frame, they couldn't be moved or closed any more. IcedTea-Web's dialogs: type dialog.
viewer_rules() {
    for c in iKVM-Viewer tw-com-aten-ikvm-KVMMain; do
        sed -i "s#</applications>#  <application class=\"$c\" title=\"Java*Viewer*\" type=\"normal\"><maximized>yes</maximized><decor>no</decor></application>\n</applications>#" "$1"
    done
}
if [ -f /etc/xdg/openbox/rc.xml ]; then
    cp /etc/xdg/openbox/rc.xml "$HOME/.config/openbox/rc.xml"
    sed -i 's#<number>4</number>#<number>1</number>#' "$HOME/.config/openbox/rc.xml"   # one desktop, not four
    # no key bindings at all: every key goes to the remote (Alt+Tab, Alt+F4 closed the console here,
    # desktops, screenshots, ...); the desktop menu (right-click) and the mouse do the rest
    perl -0pi -e 's#\s*<keybind\b.*?</keybind>##gs' "$HOME/.config/openbox/rc.xml"
    if [ "$MODE" = jnlp ]; then
        viewer_rules "$HOME/.config/openbox/rc.xml"     # a .jnlp's viewer: as in a viewer's own tab
    else
        # IPMIView's main window only (its title: "IPMIView 2.25.0 ...", "IPMI View ..."), not its others (SOL,
        # Trap Receiver, its soft keyboard: same class, other titles)
        for c in IPMIView IPMIView20-IPMIView20; do
            sed -i "s#</applications>#  <application class=\"$c\" title=\"IPMI*View*\" type=\"normal\"><maximized>yes</maximized><decor>no</decor></application>\n</applications>#" "$HOME/.config/openbox/rc.xml"
        done
    fi
fi
# The desktop's menu (right-click). A .jnlp's container: no IPMIView, and it ends with its viewer
# (run.sh starts it to be removed then): "End this console" instead of a restart.
if [ "$MODE" = jnlp ]; then
    MENU_IPMIVIEW=""
    MENU_END='<item label="End this console"><action name="Execute"><command>/usr/local/bin/reboot-container</command></action></item>'
else
    MENU_IPMIVIEW='<item label="Open IPMIView"><action name="Execute"><command>/usr/local/bin/open-ipmiview</command></action></item>'
    MENU_END='<item label="Reboot container"><action name="Execute"><command>/usr/local/bin/reboot-container</command></action></item>'
fi
cat > "$HOME/.config/openbox/menu.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="iKVM">
    ${MENU_IPMIVIEW}
    <item label="Open IcedTea-Web settings">
      <action name="Execute"><command>/usr/local/bin/open-itweb-settings</command></action>
    </item>
    <separator/>
    ${MENU_END}
  </menu>
</openbox_menu>
EOF
cat > /usr/local/bin/reboot-container <<'EOF'
#!/bin/sh
# Reboot the whole container: signal PID 1 so it exits; Docker's restart policy brings it back fresh.
kill -USR1 1
EOF
chmod +x /usr/local/bin/reboot-container
openbox >/tmp/openbox.log 2>&1 &
# tint2 as a plain window switcher: task buttons only — no pager, clock, systray or launchers.
# Its background first: with it defined after panel_background_id (as before), 26.04's tint2 read
# another one ("panel_background_id rounded is too big") and the taskbar was gone.
mkdir -p "$HOME/.config/tint2"
cat > "$HOME/.config/tint2/tint2rc" <<'EOF'
rounded = 0
border_width = 0
background_color = #2e3440 100
border_color = #2e3440 0

panel_items = T
panel_size = 100% 34
panel_position = bottom center horizontal
panel_background_id = 1
taskbar_mode = single_desktop
task_text = 1
task_icon = 1
task_maximum_size = 260 32
task_padding = 8 2 6
mouse_left = toggle_iconify
mouse_middle = none
mouse_right = none
mouse_scroll_up = prev_task
mouse_scroll_down = next_task
EOF
# IPMIView's desktop only, and only when its viewers get no tab of their own (VIEWER_TABS off:
# they open as windows next to IPMIView, the taskbar switches between them). Every iKVM viewer
# looks the same, a .jnlp's or IPMIView's in its own tab, and has none.
if [ "$MODE" != jnlp ] && [ "$VIEWER_TABS" != true ]; then
    tint2 >/tmp/tint2.log 2>&1 &
fi
xsetroot -solid "#3b4252" 2>/dev/null || true
# The address stays plain (http://localhost:PORT/): connecting at once and the desktop following
# the window are noVNC's settings (mandatory.json, defaults.json: Dockerfile). The paste hotkeys
# for keypasta.js: keypasta-websockify answers keypasta.json from the agent's settings file.
keypasta-websockify --web=/usr/share/novnc 0.0.0.0:"$VNC_PORT" localhost:15900 >/tmp/novnc.log 2>&1 &
# shellcheck disable=SC2086
keypasta-vncauth $VNCAUTH_MODE 5900 15900 >/tmp/vncauth.log 2>&1 &

log "View it at  http://localhost:${VNC_PORT}/"

# the agent, for IPMIView and every viewer it starts (they inherit the variable)
JAVA_AA="-Dswing.aatext=true -Dawt.useSystemAAFontSettings=on"
if [ -f "$AGENT" ]; then
    # AGENT_ARGS: optional agent options, e.g. "mouseRate=30"
    export JAVA_TOOL_OPTIONS="$JAVA_AA -javaagent:${AGENT}${AGENT_ARGS:+=$AGENT_ARGS}"
else
    export JAVA_TOOL_OPTIONS="$JAVA_AA"
    log "agent jar not found at ${AGENT}: starting without it"
fi

# Script behind the desktop menu's "Open IPMIView" (bakes in the resolved agent env + classpath).
cat > /usr/local/bin/open-ipmiview <<EOF
#!/bin/bash
export DISPLAY=:0
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS}"
cd "${WORK}" || { echo "no IPMIView at ${IPMIVIEW}"; exit 1; }
exec java -Xmx512m -Djava.library.path="${IPMIVIEW}" -cp "iKVM.jar:IPMIView20.jar:TrapView.jar:JViewerX9.jar:lax.jar" IPMIView20.IPMIView20
EOF
chmod +x /usr/local/bin/open-ipmiview
# Script behind "Open IcedTea-Web settings": Java Web Start's settings and trusted certificates
# (open-source Java has no other Java control panel). Without the agent: nothing to fix there.
cat > /usr/local/bin/open-itweb-settings <<EOF
#!/bin/sh
export DISPLAY=:0
export JAVA_TOOL_OPTIONS="${JAVA_AA}"
exec itweb-settings
EOF
chmod +x /usr/local/bin/open-itweb-settings

# .jnlp (Java Web Start) path: hand it to IcedTea-Web, agent already in JAVA_TOOL_OPTIONS
if [ "$MODE" = jnlp ]; then
    [ -n "$JNLP" ] && [ -f "$JNLP" ] || { log "JNLP file not found: ${JNLP}"; exit 1; }
    log "launching ${JNLP} via javaws"
    trap 'exit 0' USR1   # desktop menu "End this console"
    # KEYPASTA_VIEWER_TAB=1: the agent keeps the viewer's window maximized (it resizes it itself)
    # The BMC serves its jars Pack200-compressed only, which this IcedTea-Web can't unpack:
    # keypasta-jnlp-jars fetches and unpacks them (Java 11's unpack200) beforehand, and IcedTea-Web
    # loads them from a copy of the .jnlp pointing to them.
    keypasta-jnlp-jars "$JNLP" /tmp/jnlp-jars /tmp/launch.jnlp \
        || { log "couldn't fetch the console's files from the BMC"; exit 1; }
    # -verbose (run.sh --debug): what it downloads and why that fails (the app shows the
    # container's output when it ends)
    VERBOSE=""
    [ "${KEYPASTA_DEBUG:-false}" = true ] && VERBOSE=-verbose
    KEYPASTA_VIEWER_TAB=1 javaws $VERBOSE -nosecurity -Xnofork /tmp/launch.jnlp &
    log "console up; right-click the desktop for the menu, or Stop from the app."
    # the viewer ends (or its start is cancelled): so does the container (the app shows its output
    # and removes it)
    rc=0
    wait $! || rc=$?
    log "viewer ended ($rc): the container ends"
    exit 0
fi

# IPMIView path
[ -f "$IPMIVIEW/IPMIView20.jar" ] || { log "IPMIView20.jar not found in ${IPMIVIEW}"; exit 1; }
cd "$IPMIVIEW"

# Expired-cert relax: wrap the bundled stunnel64 so it forces verify = 0 in the conf it is given.
# Non-destructive: the real binary is kept as stunnel64.real and restored when the toggle is off.
STUNNEL_DIR="BMCSecurity/linux"
if [ -f "$STUNNEL_DIR/stunnel64" ] || [ -f "$STUNNEL_DIR/stunnel64.real" ]; then
    if [ "$IGNORE_EXPIRED_CERT" = true ]; then
        [ -f "$STUNNEL_DIR/stunnel64.real" ] || cp -p "$STUNNEL_DIR/stunnel64" "$STUNNEL_DIR/stunnel64.real"
        cat > "$STUNNEL_DIR/stunnel64" <<'WRAP'
#!/bin/sh
# iKVM-KeyPasta: force verify = 0 so an expired BMC cert is accepted (see entrypoint.sh)
for f in "$@"; do
    case "$f" in *.conf) [ -f "$f" ] && sed -i -E 's/^[[:space:]]*verify[[:space:]]*=.*/verify = 0/' "$f" ;; esac
done
exec "$(dirname "$0")/stunnel64.real" "$@"
WRAP
        chmod 755 "$STUNNEL_DIR/stunnel64"
        log "expired-cert check: RELAXED (verify = 0). Roll the BMC clock back too."
    elif [ -f "$STUNNEL_DIR/stunnel64.real" ]; then
        cp -p "$STUNNEL_DIR/stunnel64.real" "$STUNNEL_DIR/stunnel64"
        chmod 755 "$STUNNEL_DIR/stunnel64"
    fi
fi

# Bind the tunnel's local end to loopback (otherwise IPMIView picks the first non-loopback address).
if ! grep -q '^proxy_ip *=' stunnel.properties 2>/dev/null; then
    [ -s stunnel.properties ] && [ -n "$(tail -c 1 stunnel.properties)" ] && echo >> stunnel.properties
    echo "proxy_ip=127.0.0.1" >> stunnel.properties || log "couldn't write stunnel.properties"
fi

# IPMIView keeps its settings in the folder it runs in: IPMIView.properties (the BMC list) and
# account.properties (saved IDs and passwords) are the Mac's, in
# ~/Library/Application Support/IPMIView (mounted at /settings by run.sh), where the native start
# (ipmiview-keypasta.sh) keeps them too: both share them. It runs in $WORK, which links to everything in IPMIView's folder (it finds its files
# relative to the folder it runs in) and to those two in /settings. Settings found in IPMIView's
# folder move there once, as the native start does. IPMIView won't start without the two files:
# empty ones if absent.
SHARED="IPMIView.properties account.properties"
mkdir -p /settings
for f in $SHARED; do
    if [ -f "$f" ] && [ ! -L "$f" ] && [ ! -e "/settings/$f" ]; then
        mv "$f" "/settings/$f" && log "moved $f to the Mac's IPMIView settings folder"
    fi
    [ -e "/settings/$f" ] || : > "/settings/$f"
done
rm -rf "$WORK"
mkdir -p "$WORK"
for e in "$IPMIVIEW"/* "$IPMIVIEW"/.[!.]*; do
    [ -e "$e" ] || continue
    case " $SHARED " in *" ${e##*/} "*) continue ;; esac
    ln -s "$e" "$WORK/${e##*/}"
done
for f in $SHARED; do ln -s "/settings/$f" "$WORK/$f"; done

# Each viewer in a browser tab of its own (VIEWER_TABS, the app's "Open iKVM Viewer windows in
# separate browser tabs"). IPMIView starts its viewers as ./jre/bin/java -jar iKVM*.jar in the folder
# it runs in: there jre/bin/java is viewer-tab (below), the rest of jre links to the real one. For a
# viewer it starts a desktop of its own (display :1-:99, named "iKVM <BMC>": the tab's title), with
# openbox keeping the viewer's window maximized without a frame, websockify on port 6100+n and VNC
# on 5700+n (keypasta-vncauth; Xvnc itself on 15700+n, loopback only) (run.sh publishes them as they are; the app opens a tab for each that comes up; not
# 6080+n/5900+n: 6000-6099 are X11's TCP ports), runs the viewer there
# (KEYPASTA_VIEWER_TAB=1: the agent keeps its window maximized) and removes the desktop when the
# viewer ends. Anything else (the precheck) goes to the real java unchanged. The real java: the
# bundled one, or, for an IPMIView without one (it would run "java" then), the image's: IPMIView
# runs ./jre/bin/java whenever there is a jre folder, so the folder is made either way.
# What it does goes to the container's log (docker logs ikvm-console).
if [ "$VIEWER_TABS" = true ]; then
    REAL_JAVA="$IPMIVIEW/jre/bin/java"
    [ -x "$REAL_JAVA" ] || REAL_JAVA="$(command -v java)"
    rm -rf "$WORK/jre"
    mkdir -p "$WORK/jre/bin"
    if [ -d "$IPMIVIEW/jre/bin" ]; then
        for e in "$IPMIVIEW"/jre/*; do [ "${e##*/}" = bin ] || ln -s "$e" "$WORK/jre/${e##*/}"; done
        for e in "$IPMIVIEW"/jre/bin/*; do [ "${e##*/}" = java ] || ln -s "$e" "$WORK/jre/bin/${e##*/}"; done
    fi
    cp "$HOME/.config/openbox/rc.xml" "$HOME/.config/openbox/viewer-rc.xml"
    viewer_rules "$HOME/.config/openbox/viewer-rc.xml"
    cat > "$WORK/jre/bin/java" <<'VIEWERTAB'
#!/bin/bash
# iKVM-KeyPasta (container): a viewer IPMIView starts goes to a desktop and browser tab of its own
# (see entrypoint.sh, VIEWER_TABS). Anything else: the real java.
REAL="@JAVA@"
log() { echo "[keypasta] $*" > /proc/1/fd/1 2>/dev/null; }    # the container's log
viewer=false; prev=""; bmc=""; after=false
for a in "$@"; do
    if $after && [ -z "$bmc" ]; then bmc="$a"; fi
    case "$a" in --BMCIP?*) bmc="${a#--BMCIP}" ;; esac    # with stunnel the first is 127.0.0.1
    if [ "$prev" = -jar ]; then
        case "${a##*/}" in iKVM_precheck*) ;; iKVM*.jar) viewer=true; after=true ;; esac
    fi
    [ "$a" = tw.com.aten.ikvm.KVMMain ] && { viewer=true; after=true; }
    prev="$a"
done
$viewer || exec "$REAL" "$@"
n=""
for i in $(seq 1 99); do
    [ -e "/tmp/.X11-unix/X$i" ] || [ -e "/tmp/.X$i-lock" ] || { n=$i; break; }
done
[ -n "$n" ] || { log "viewer for ${bmc:-?}: 99 tabs already, on the main desktop"; exec "$REAL" "$@"; }
Xvnc ":$n" -geometry 1280x800 -depth 24 -rfbport $((15700 + n)) -localhost @XVNC_SEC@ -RawKeyboard=1 -SendPrimary=0 \
     -AlwaysShared -AcceptSetDesktopSize=1 -desktop "iKVM ${bmc:-Viewer}" >"/tmp/xvnc$n.log" 2>&1 &
XVNC=$!
for _ in $(seq 1 100); do DISPLAY=":$n" xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
DISPLAY=":$n" xdpyinfo >/dev/null 2>&1 || {
    log "viewer for ${bmc:-?}: its desktop :$n didn't start ($(tail -n 2 "/tmp/xvnc$n.log" | tr '\n' ' ')), on the main desktop"
    kill "$XVNC" 2>/dev/null; exec "$REAL" "$@"; }
export DISPLAY=":$n"
setxkbmap "@LAYOUT@" 2>/dev/null
printf "Xft.antialias: 1\nXft.hinting: 1\nXft.hintstyle: hintslight\nXft.rgba: none\n" | xrdb -merge 2>/dev/null
xsettingsd -c "@HOME@/.xsettingsd" >/dev/null 2>&1 &
XS=$!
# its own desktop menu (right-click): "End this console" ends this viewer; else as a .jnlp's
# container: the viewer filling its desktop, no window list (only IPMIView's desktop has one)
cat > "/tmp/viewer-end$n" <<EOF
#!/bin/sh
pkill -TERM -P $$ -x java; sleep 3; pkill -KILL -P $$ -x java
EOF
chmod +x "/tmp/viewer-end$n"
cat > "/tmp/viewer-menu$n.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="iKVM">
    <item label="End this console"><action name="Execute"><command>/tmp/viewer-end$n</command></action></item>
  </menu>
</openbox_menu>
EOF
sed -e "s#<file>menu.xml</file>#<file>/tmp/viewer-menu$n.xml</file>#" "@HOME@/.config/openbox/viewer-rc.xml" > "/tmp/viewer-rc$n.xml"
openbox --config-file "/tmp/viewer-rc$n.xml" >"/tmp/openbox$n.log" 2>&1 &
OB=$!
keypasta-websockify --web=/usr/share/novnc "0.0.0.0:$((6100 + n))" "localhost:$((15700 + n))" >"/tmp/novnc$n.log" 2>&1 &
WS=$!
keypasta-vncauth @VNCAUTH_MODE@ $((5700 + n)) $((15700 + n)) >"/tmp/vncauth$n.log" 2>&1 &     # VNC apps
VA=$!
log "viewer for ${bmc:-?} in a tab of its own: desktop :$n, port $((6100 + n)) (VNC $((5700 + n)))"
# its BMC for the app's list of running consoles (docker exec ... grep -r . /tmp/viewer-names)
mkdir -p /tmp/viewer-names
echo "${bmc:-Viewer $n}" > "/tmp/viewer-names/$n"
KEYPASTA_VIEWER_TAB=1 "$REAL" "$@"
rc=$?
log "viewer for ${bmc:-?} ended ($rc): desktop :$n removed"
kill "$VA" "$WS" "$OB" "$XS" "$XVNC" 2>/dev/null
rm -f "/tmp/viewer-end$n" "/tmp/viewer-menu$n.xml" "/tmp/viewer-rc$n.xml" "/tmp/viewer-names/$n"
exit "$rc"
VIEWERTAB
    sed -i -e "s#@JAVA@#$REAL_JAVA#g" -e "s#@LAYOUT@#$LAYOUT#g" -e "s#@HOME@#$HOME#g" \
        -e "s#@XVNC_SEC@#$XVNC_SEC#g" -e "s#@VNCAUTH_MODE@#$VNCAUTH_MODE#g" "$WORK/jre/bin/java"
    chmod 755 "$WORK/jre/bin/java"
    log "iKVM viewers: each in a browser tab of its own (ports 6101-6199, VNC 5701-5799, java: $REAL_JAVA)"
fi

log "starting IPMIView"
trap 'exit 0' USR1   # desktop menu "Reboot container" -> PID 1 exits -> Docker restarts fresh
open-ipmiview &
while :; do sleep 86400 & wait $! || true; done
