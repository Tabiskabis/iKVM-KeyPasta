@echo off

:: iKVM-KeyPasta: opens .jnlp files (Java Web Start) with OpenWebStart. Can be set as the program
:: for .jnlp files (see /register below), or started without a file: then it takes
:: %USERPROFILE%\Downloads\launch.jnlp (BMC web interface, "Launch Console").
::
:: The iKVM viewer (.jnlp with tw.com.aten.ikvm): started as admin, with the Java agent for this
:: start only. Other .jnlp files: passed to OpenWebStart unchanged, as the user.
::   - Admin from the start: the viewer needs it anyway. Started as normal user, it gets the
::     rights through a UAC prompt, which starts it again without this script's environment.
::   - JAVA_TOOL_OPTIONS is set here only, for OpenWebStart and the viewer: no variable for all
::     Java programs (which none of them survives if the jar goes missing).
::   - Java 8 for it (JAVAVERSION): the viewer's .jnlp asks for options Java 17 and newer refuse.
::     Set in the copy below, so no OpenWebStart setting forces it on other programs.
::   - The .jnlp is copied to the user's %TEMP%\iKVM-KeyPasta\ (also when the UAC prompt is
::     answered with another admin account), named launch-<date>-<time>-<BMC>-<random>.jnlp, and
::     kept there for a week after it was last opened (older ones are deleted at each start).
::     Opened again, it works only as long as the BMC accepts the console session's login data
::     in it. The original is deleted only once a viewer window has opened from it (the agent
::     creates the file KEYPASTA_VIEWER_OPENED names when the viewer's window shows, which it
::     builds after connecting and logging in) within VIEWERWAIT seconds, and only if it's
::     unchanged: out of Downloads, the browser saves the next one under the same name. Any other
::     outcome (no window, no agent) leaves it there for another try.
::
::   iKVM-jnlp-launcher.cmd /register     offer it for .jnlp files (as yourself, not as admin;
::                                         /register /quiet: without messages, for install.cmd),
::                                         then choose it once: a .jnlp file, Open with,
::                                         Choose another app, "iKVM-KeyPasta launcher", Always
::   iKVM-jnlp-launcher.cmd /unregister   remove that again
::
:: Keep this file next to iKVM-KeyPasta-agent.jar, in a folder only admins can write to
:: (%ProgramFiles%\iKVM-KeyPasta\): it runs as admin. Not there: the jar one folder up (the repo:
:: this file in windows\, the built jar above). Both are as safe as this file itself: who may write
:: the folder above may also replace this one. No other place (no variable): that would let any
:: program of yours choose what runs as admin.

setlocal

set "JNLP=%USERPROFILE%\Downloads\launch.jnlp"
set "OWS=%ProgramFiles%\OpenWebStart"
:: Java version for the iKVM viewer (OpenWebStart's syntax: 1.8* = any 1.8). Empty: as the .jnlp says
set "JAVAVERSION=1.8*"
:: Seconds to wait for a viewer window to open from the .jnlp before leaving it where it is
:: (includes answering OpenWebStart's questions and it downloading a Java)
set "VIEWERWAIT=300"
set "AGENT=%~dp0iKVM-KeyPasta-agent.jar"
if not exist "%AGENT%" if exist "%~dp0..\iKVM-KeyPasta-agent.jar" for %%F in ("%~dp0..\iKVM-KeyPasta-agent.jar") do set "AGENT=%%~fF"
set "USERTEMP=%TEMP%"
set "SELF=%~f0"
set "PROGID=iKVM-KeyPasta.jnlp"
set "ICON=%~dp0PPCH_outlined_dark.ico"

rem without a file: the newest launch*.jnlp in Downloads (browsers save another one as
rem "launch (1).jnlp" and so on)
if "%~1"=="" for /f "delims=" %%F in ('dir /b /a-d /o-d /t:w "%USERPROFILE%\Downloads\launch*.jnlp" 2^>nul') do (
    set "JNLP=%USERPROFILE%\Downloads\%%F"
    goto :newest
)
:newest
if /i "%~1"=="/register" goto :register
if /i "%~1"=="/unregister" goto :unregister
rem the restart as admin gets the user's .jnlp and %TEMP% passed on
if /i "%~1"=="/elevated" (
    set "JNLP=%~2"
    set "USERTEMP=%~3"
) else if not "%~1"=="" (
    set "JNLP=%~f1"
)

if not exist "%JNLP%" (
    >&2 echo iKVM launcher not found. Expected "%JNLP%"
    pause
    exit /b 1
)
if not exist "%OWS%\javaws.exe" (
    >&2 echo OpenWebStart not found in "%OWS%": adjust OWS at the top of this file ^(%~f0^)
    pause
    exit /b 1
)

rem Not the iKVM viewer: OpenWebStart as usual
findstr /i /c:"tw.com.aten.ikvm" "%JNLP%" >nul 2>&1
if errorlevel 1 (
    start "" "%OWS%\javaws.exe" "%JNLP%"
    exit /b
)

rem Not admin: start again as admin (UAC prompt)
fltmc >nul 2>&1
if not errorlevel 1 goto :admin
if /i "%~1"=="/elevated" (
    >&2 echo Admin rights are needed to start the iKVM viewer.
    pause
    exit /b 1
)
rem Through cmd /c ""script" args": started directly, Windows runs a .cmd as cmd /C "script" args,
rem and cmd then strips the first and the last quote of that line whenever there are more than
rem two quotes or a ( ) & etc. in the path: the script isn't found (window flashes and closes).
powershell -NoProfile -Command "$q = [char]34; Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList ('/c ' + $q + $q + $env:SELF + $q + ' /elevated ' + $q + $env:JNLP + $q + ' ' + $q + $env:USERTEMP + $q + $q)" >nul 2>&1
if errorlevel 1 (
    >&2 echo Not started: the UAC prompt was declined.
    pause
)
exit /b

:admin
rem The viewer may start itself again through javaws: OpenWebStart's folder into PATH, for
rem this start only, unless it's there already (with or without a "\" at the end).
rem (Searched by removing it from a copy: call set expands that twice, the second time with
rem OWS already in. Not case-sensitive. No echo of PATH: a "&" in it would break that.)
set "PATHCHECK=;%PATH%;"
call set "PATHREST=%%PATHCHECK:;%OWS%;=%%"
call set "PATHREST=%%PATHREST:;%OWS%\;=%%"
if "%PATHCHECK%"=="%PATHREST%" set "PATH=%OWS%;%PATH%"
set "PATHCHECK="
set "PATHREST="
rem (no ( ) block here: a ")" in the path, like "Program Files (x86)", would end it)
if not exist "%AGENT%" goto :noagent
set "JAVA_TOOL_OPTIONS=-javaagent:"%AGENT%""
goto :start
:noagent
>&2 echo "%AGENT%" not found: starting without the agent.
timeout /t 5 >nul

:start
rem The .jnlp to the user's %TEMP%, named after date, time and the BMC (address the browser
rem used, from its codebase, characters not allowed in file names as _)
set "COPYDIR=%USERTEMP%\iKVM-KeyPasta"
if not exist "%COPYDIR%" mkdir "%COPYDIR%"
set "NAME="
for /f "usebackq delims=" %%N in (`powershell -NoProfile -Command "$h = 'unknown'; if ((Get-Content -LiteralPath $env:JNLP -Raw) -match 'codebase=.[a-z]+://([^/''\x22]+)') { $h = $Matches[1] -replace ':\d+$', '' -replace '[^A-Za-z0-9.-]', '_' }; 'launch-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $h + '-' + ('{0:D6}' -f (Get-Random -Maximum 1000000))"`) do set "NAME=%%N"
if not defined NAME set "NAME=launch-%RANDOM%%RANDOM%"
set "COPY=%COPYDIR%\%NAME%.jnlp"
copy /y "%JNLP%" "%COPY%" >nul
if not exist "%COPY%" (
    >&2 echo Couldn't copy "%JNLP%".
    pause
    exit /b 1
)
rem Copies not opened for a week: deleted. This one counts as opened now (its date set to now).
powershell -NoProfile -Command "$old = (Get-Date).AddDays(-7); Get-ChildItem -LiteralPath $env:COPYDIR -Filter 'launch-*.jnlp' | Where-Object { $_.LastWriteTime -lt $old } | Remove-Item -Force -ErrorAction SilentlyContinue; (Get-Item -LiteralPath $env:COPY).LastWriteTime = Get-Date" >nul 2>&1
rem the Java version the .jnlp asks for (<j2se version="..."> or <java version="...">)
if defined JAVAVERSION powershell -NoProfile -Command "$f = $env:COPY; $t = [IO.File]::ReadAllText($f); [IO.File]::WriteAllText($f, ($t -replace '(<(?:j2se|java)\b[^>]*?\bversion\s*=\s*)([\x22''])[^\x22'']*\2', ('${1}${2}' + $env:JAVAVERSION + '${2}')))" >nul 2>&1
rem The agent creates KEYPASTA_VIEWER_OPENED's file once the viewer's window shows (the viewer
rem inherits this environment through OpenWebStart).
set "KEYPASTA_VIEWER_OPENED=%COPYDIR%\%NAME%.opened"
rem OpenWebStart started by a hidden PowerShell, which then waits for that file and deletes the
rem original .jnlp, if it's still the one copied (its hash taken before, as the copy was changed
rem above). This window closes meanwhile.
start "" powershell -NoProfile -WindowStyle Hidden -Command "$o = $env:KEYPASTA_VIEWER_OPENED; Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue; $h = (Get-FileHash -LiteralPath $env:JNLP).Hash; Start-Process -FilePath ($env:OWS + '\javaws.exe') -ArgumentList ([char]34 + $env:COPY + [char]34); $end = (Get-Date).AddSeconds([int]$env:VIEWERWAIT); while ((Get-Date) -lt $end) { if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue; if ((Get-FileHash -LiteralPath $env:JNLP -ErrorAction SilentlyContinue).Hash -eq $h) { Remove-Item -LiteralPath $env:JNLP -Force }; break }; Start-Sleep -Milliseconds 500 }"
exit /b

rem Offered for .jnlp files of this user: a ProgID with this script as open command, listed in
rem the file type's "Open with" choices. Windows doesn't let programs make themselves the
rem default: that's the user's choice in "Open with" (or Settings, Default apps). Once chosen,
rem .jnlp files show the project's icon (PPCH_outlined_dark.ico next to this file).
:register
set "KEY=HKCU\Software\Classes\%PROGID%"
set "FAILED="
reg add "%KEY%" /ve /d "Java Web Start file (iKVM-KeyPasta)" /f >nul
if errorlevel 1 call :regfailed "%KEY%"
reg add "%KEY%\shell\open" /v FriendlyAppName /d "iKVM-KeyPasta launcher" /f >nul
if errorlevel 1 call :regfailed "%KEY%\shell\open"
rem The command: "cmd.exe" /c ""this script" "file"" (%1: the file, filled in by Windows).
rem Written by PowerShell from a variable, not by reg: security software (Bitdefender) blocks
rem a reg command line with "cmd.exe /c" in it as malicious.
set "OPENCMD="%ComSpec%" /c ""%SELF%" "%%1"""
powershell -NoProfile -Command "$ErrorActionPreference = 'Stop'; $k = 'HKCU:\Software\Classes\' + $env:PROGID + '\shell\open\command'; New-Item -Path $k -Force | Out-Null; Set-ItemProperty -LiteralPath $k -Name '(default)' -Value $env:OPENCMD"
if errorlevel 1 call :regfailed "%KEY%\shell\open\command"
if exist "%ICON%" reg add "%KEY%\DefaultIcon" /ve /d "%ICON%" /f >nul
rem listed in "Open with" for .jnlp files
reg add "HKCU\Software\Classes\.jnlp\OpenWithProgids" /v "%PROGID%" /d "" /f >nul
if errorlevel 1 call :regfailed "HKCU\Software\Classes\.jnlp\OpenWithProgids"
if defined FAILED (
    >&2 echo Registering failed.
    if /i not "%~2"=="/quiet" pause
    exit /b 1
)
if /i "%~2"=="/quiet" exit /b 0
echo Registered. Now right-click a .jnlp file: Open with, Choose another app,
echo "iKVM-KeyPasta launcher", "Always".
pause
exit /b 0

:: which key failed (reg itself only says "Access is denied.")
:regfailed
set "FAILED=1"
>&2 echo   ^(writing %~1^)
exit /b 0

:unregister
reg delete "HKCU\Software\Classes\%PROGID%" /f >nul 2>&1
reg delete "HKCU\Software\Classes\.jnlp\OpenWithProgids" /v "%PROGID%" /f >nul 2>&1
if /i "%~2"=="/quiet" exit /b 0
echo Removed. Choose OpenWebStart again for .jnlp files: Open with, Choose another app, "Always".
pause
exit /b 0
