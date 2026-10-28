@echo off
rem Builds ..\iKVM-KeyPasta-agent.jar (needs a JDK 9 or newer; the jar runs on Java 8 and newer)
rem -Xlint:-options: newer JDKs warn that --release 8 is deprecated; Java 8 is what the viewers need.
rem javac and jar from PATH, else from JAVA_HOME, an installed JDK (the last found: a vendor's
rem newest) or IPMIView's own Java, a full JDK 11; each only with lib\modules (JDK 9 or newer).
setlocal
where javac >nul 2>&1 && goto :build
set "JDK="
if defined JAVA_HOME if exist "%JAVA_HOME%\bin\javac.exe" if exist "%JAVA_HOME%\lib\modules" set "JDK=%JAVA_HOME%"
if not defined JDK for /d %%D in ("%ProgramFiles%\Eclipse Adoptium\jdk-*" "%ProgramFiles%\Microsoft\jdk-*" "%ProgramFiles%\Zulu\zulu-*" "%ProgramFiles%\Java\jdk*" "%ProgramFiles%\OpenJDK\jdk-*") do if exist "%%~D\bin\javac.exe" if exist "%%~D\lib\modules" set "JDK=%%~D"
if not defined JDK if exist "%ProgramFiles%\SUPERMICRO\IPMIView\jre\bin\javac.exe" if exist "%ProgramFiles%\SUPERMICRO\IPMIView\jre\lib\modules" set "JDK=%ProgramFiles%\SUPERMICRO\IPMIView\jre"
if not defined JDK >&2 echo No JDK 9 or newer found: install one, e.g. winget install EclipseAdoptium.Temurin.21.JDK
if not defined JDK exit /b 1
echo Using "%JDK%\bin\javac.exe"
set "PATH=%JDK%\bin;%PATH%"
:build
cd /d "%~dp0"
call :clean
rem stub\: stand-ins for macOS's and IPMIView's own classes, only to compile against (not in the jar)
javac --release 8 -Xlint:-options -encoding UTF-8 -d build-stub stub\com\apple\laf\*.java stub\com\supermicro\ipmi\stunnel\*.java || goto :failed
javac --release 8 -Xlint:-options -encoding UTF-8 -cp build-stub -d build src\keypasta\*.java || goto :failed
rem hook\: a class the agent defines in IPMIView's class loader (see MacStunnel), in the jar as data
javac --release 8 -Xlint:-options -encoding UTF-8 -cp "build-stub;build" -d build-hook hook\com\supermicro\ipmi\stunnel\*.java || goto :failed
copy /y build-hook\com\supermicro\ipmi\stunnel\KeyPastaStunnel.class build\keypasta\KeyPastaStunnel.bin >nul || goto :failed
jar cfm ..\iKVM-KeyPasta-agent.jar manifest.txt -C build . -C res . || goto :failed
call :clean
echo Built ..\iKVM-KeyPasta-agent.jar
exit /b 0

rem the build folders go whether it worked or not
:failed
call :clean
exit /b 1

:clean
if exist build rmdir /s /q build
if exist build-stub rmdir /s /q build-stub
if exist build-hook rmdir /s /q build-hook
exit /b 0
