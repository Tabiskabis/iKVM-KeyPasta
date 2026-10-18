#!/bin/bash
# iKVM-KeyPasta, macOS: runs a java command under the name the Dock and Cmd-Tab show. They name a
# program without an app bundle by its executable's file name, "java" for every Java program (Java's
# -Xdock:name reaches only the menu bar since OS X 10.9: OpenJDK JDK-8029440). So the command runs
# through a copy of java-launcher named after the program, which starts Java inside its own process:
#   IPMIView20.IPMIView20                                   "IPMIView"
#   the iKVM viewer: tw.com.aten.ikvm.KVMMain, -jar iKVM.jar
#   (IPMIView's way), or a .jnlp of it                      "iKVM Viewer"
#   anything else                                           plain java
# Two fixed copies in ~/Library/Application Support/iKVM-KeyPasta/Launchers, replaced only when the
# launcher itself changes: the firewall (e.g. LuLu) sees two programs, asked about once.
# Used as "java" (a link named java first in PATH: IPMIView starts the viewers as java), by
# ipmiview-keypasta.sh for IPMIView itself and by the app for .jnlp files.
# Environment: KEYPASTA_JAVA_HOME (the Java to run), KEYPASTA_LAUNCHER (java-launcher, else plain
# java).

JH="${KEYPASTA_JAVA_HOME:-}"
[ -n "$JH" ] && [ -x "$JH/bin/java" ] || { echo "java-name.sh: KEYPASTA_JAVA_HOME not set" >&2; exit 1; }
plain() { exec "$JH/bin/java" "$@"; }
[ -n "${KEYPASTA_LAUNCHER:-}" ] && [ -x "$KEYPASTA_LAUNCHER" ] || plain "$@"

# the main class or jar
args=("$@")
main=""
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        -cp|-classpath|--class-path|-p|--module-path|--add-modules|--add-opens|--add-exports) i=$((i + 2)) ;;
        -jar) main="${args[$((i + 1))]}"; break ;;
        -*) i=$((i + 1)) ;;
        *) main="${args[$i]}"; break ;;
    esac
done

name=""
case "$main" in
    IPMIView20.IPMIView20)
        name="IPMIView" ;;
    tw.com.aten.ikvm.KVMMain|iKVM*.jar|*/iKVM*.jar)
        name="iKVM Viewer" ;;
    net.sourceforge.jnlp.runtime.Boot)
        jnlp="${args[${#args[@]} - 1]}"
        [ -f "$jnlp" ] && grep -q 'tw\.com\.aten\.ikvm' "$jnlp" && name="iKVM Viewer" ;;
esac
[ -n "$name" ] || plain "$@"

DIR="$HOME/Library/Application Support/iKVM-KeyPasta/Launchers"
exe="$DIR/$name"
if ! cmp -s "$KEYPASTA_LAUNCHER" "$exe"; then
    # (under another name first, then renamed: two viewers may start at once)
    mkdir -p "$DIR" && cp "$KEYPASTA_LAUNCHER" "$exe.$$" && mv -f "$exe.$$" "$exe" || plain "$@"
fi
# -Xdock:name: the name Java gives LaunchServices (menu bar, Force Quit, Activity Monitor), else the
# main class's ("IPMIView20", "KVMMain", "Boot"); the Dock keeps the executable's
exec "$exe" "-Xdock:name=$name" "$@"
