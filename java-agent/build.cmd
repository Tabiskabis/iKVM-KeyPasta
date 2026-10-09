@echo off
rem Builds ..\iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer)
cd /d "%~dp0"
if exist build rmdir /s /q build
javac --release 8 -encoding UTF-8 -d build src\keypasta\*.java || exit /b 1
jar cfm ..\iKVM-KeyPasta-agent.jar manifest.txt -C build . || exit /b 1
rmdir /s /q build
echo Built ..\iKVM-KeyPasta-agent.jar
