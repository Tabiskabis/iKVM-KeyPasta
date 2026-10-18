@echo off
rem Builds ..\iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer)
cd /d "%~dp0"
if exist build rmdir /s /q build
if exist build-stub rmdir /s /q build-stub
rem stub\: stand-ins for macOS's own classes, only to compile against (not in the jar)
javac --release 8 -encoding UTF-8 -d build-stub stub\com\apple\laf\*.java || exit /b 1
javac --release 8 -encoding UTF-8 -cp build-stub -d build src\keypasta\*.java || exit /b 1
jar cfm ..\iKVM-KeyPasta-agent.jar manifest.txt -C build . -C res . || exit /b 1
rmdir /s /q build
rmdir /s /q build-stub
echo Built ..\iKVM-KeyPasta-agent.jar
