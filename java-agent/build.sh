#!/bin/sh
# Builds ../iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer)
set -e
cd "$(dirname "$0")"
rm -rf build build-stub
# stub/: stand-ins for macOS's own classes, only to compile against (not in the jar)
javac --release 8 -encoding UTF-8 -d build-stub stub/com/apple/laf/*.java
javac --release 8 -encoding UTF-8 -cp build-stub -d build src/keypasta/*.java
jar cfm ../iKVM-KeyPasta-agent.jar manifest.txt -C build . -C res .
rm -rf build build-stub
echo "Built ../iKVM-KeyPasta-agent.jar"
