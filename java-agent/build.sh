#!/bin/sh
# Builds ../iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer)
set -e
cd "$(dirname "$0")"
rm -rf build
javac --release 8 -encoding UTF-8 -d build src/keypasta/*.java
jar cfm ../iKVM-KeyPasta-agent.jar manifest.txt -C build .
rm -rf build
echo "Built ../iKVM-KeyPasta-agent.jar"
