#!/bin/sh
# Builds ../iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer).
# -Xlint:-options: newer JDKs warn that --release 8 is deprecated; Java 8 is what the viewers need.
set -e
cd "$(dirname "$0")"
rm -rf build build-stub build-hook
# stub/: stand-ins for macOS's and IPMIView's own classes, only to compile against (not in the jar)
javac --release 8 -Xlint:-options -encoding UTF-8 -d build-stub stub/com/apple/laf/*.java stub/com/supermicro/ipmi/stunnel/*.java
javac --release 8 -Xlint:-options -encoding UTF-8 -cp build-stub -d build src/keypasta/*.java
# hook/: a class the agent defines in IPMIView's class loader (see MacStunnel), in the jar as data
javac --release 8 -Xlint:-options -encoding UTF-8 -cp build-stub:build -d build-hook hook/com/supermicro/ipmi/stunnel/*.java
cp build-hook/com/supermicro/ipmi/stunnel/KeyPastaStunnel.class build/keypasta/KeyPastaStunnel.bin
jar cfm ../iKVM-KeyPasta-agent.jar manifest.txt -C build . -C res .
rm -rf build build-stub build-hook
echo "Built ../iKVM-KeyPasta-agent.jar"
