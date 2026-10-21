@echo off
rem Builds ..\iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer)
rem -Xlint:-options: newer JDKs warn that --release 8 is deprecated; Java 8 is what the viewers need.
cd /d "%~dp0"
if exist build rmdir /s /q build
if exist build-stub rmdir /s /q build-stub
if exist build-hook rmdir /s /q build-hook
rem stub\: stand-ins for macOS's and IPMIView's own classes, only to compile against (not in the jar)
javac --release 8 -Xlint:-options -encoding UTF-8 -d build-stub stub\com\apple\laf\*.java stub\com\supermicro\ipmi\stunnel\*.java || exit /b 1
javac --release 8 -Xlint:-options -encoding UTF-8 -cp build-stub -d build src\keypasta\*.java || exit /b 1
rem hook\: a class the agent defines in IPMIView's class loader (see MacStunnel), in the jar as data
javac --release 8 -Xlint:-options -encoding UTF-8 -cp "build-stub;build" -d build-hook hook\com\supermicro\ipmi\stunnel\*.java || exit /b 1
copy /y build-hook\com\supermicro\ipmi\stunnel\KeyPastaStunnel.class build\keypasta\KeyPastaStunnel.bin >nul || exit /b 1
jar cfm ..\iKVM-KeyPasta-agent.jar manifest.txt -C build . -C res . || exit /b 1
rmdir /s /q build
rmdir /s /q build-stub
rmdir /s /q build-hook
echo Built ..\iKVM-KeyPasta-agent.jar
