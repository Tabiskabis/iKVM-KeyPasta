@echo off

:: iKVM-KeyPasta: starts IPMIView as admin, with the Java agent (Start menu shortcut "IPMIView
:: with KeyPasta" from install.cmd). Started as normal user, it starts itself again as admin
:: (UAC prompt). Declined: IPMIView as normal user, still with the agent. With /noadmin it doesn't
:: ask: IPMIView as normal user right away (a viewer that asks for admin rights itself loses the
:: agent then; %APPDATA% stays yours, see below).
::   - Admin from the start: the iKVM viewer needs it anyway. Started as normal user, it gets the
::     rights through a UAC prompt, which starts it again without this script's environment.
::   - JAVA_TOOL_OPTIONS is set here only, for IPMIView and the viewers it starts: no variable for
::     all Java programs (which none of them survives if the jar goes missing).
::
:: Keep this file next to iKVM-KeyPasta-agent.jar, in a folder only admins can write to
:: (%ProgramFiles%\iKVM-KeyPasta\): it runs as admin. Not there: the jar one folder up (the repo:
:: this file in windows\, the built jar above). Both are as safe as this file itself: who may write
:: the folder above may also replace this one. No other place (no variable): that would let any
:: program of yours choose what runs as admin.

setlocal

:: IPMIView's program
set "IPMIVIEW=%ProgramFiles%\SUPERMICRO\IPMIView\IPMIView20.exe"
set "AGENT=%~dp0iKVM-KeyPasta-agent.jar"
if not exist "%AGENT%" if exist "%~dp0..\iKVM-KeyPasta-agent.jar" for %%F in ("%~dp0..\iKVM-KeyPasta-agent.jar") do set "AGENT=%%~fF"
set "SELF=%~f0"

:: IPMIView's settings (IPMIView.properties: the BMC list; account.properties: the saved logins;
:: proxy, language, sort order, ...) are in %APPDATA%\IPMIView if that folder exists (create it,
:: and move or copy your settings files there yourself), else in IPMIView's program folder, as
:: without this script. IPMIView takes a settings folder as its second argument (the first must be
:: none of its flags: d p s t x i c e q forceUpdate, so "-"). IPMIView20.exe always runs in its
:: own folder (IPMIView20.lax: lax.user.dir=.), and only admins can write there. The files IPMIView
:: itself still opens in its own folder (sort order, language, ...) the agent sends to the settings
:: folder too, so all of them are there. Always your %APPDATA%, also when the UAC prompt asked for
:: another account's password: this script finds it before it asks and hands it to its elevated
:: self (after /elevated), which an admin may read and write.
set "USERSETTINGS=%APPDATA%\IPMIView"
if /i "%~1"=="/elevated" if not "%~2"=="" set "USERSETTINGS=%~2"

if /i "%~1"=="/noadmin" goto :run
rem Not admin: start again as admin (UAC prompt). Through cmd /c ""script" args", see
rem iKVM-jnlp-launcher.cmd: started directly, cmd would strip the quotes of the script's path.
fltmc >nul 2>&1
if not errorlevel 1 goto :run
if /i "%~1"=="/elevated" goto :noadmin
powershell -NoProfile -Command "$q = [char]34; Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList ('/c ' + $q + $q + $env:SELF + $q + ' /elevated ' + $q + $env:USERSETTINGS + $q + $q)" >nul 2>&1
if not errorlevel 1 exit /b
:noadmin
rem the viewer then asks for admin rights itself, and gets them without the agent
>&2 echo No admin rights: IPMIView starts as normal user, with the agent. A viewer that asks
>&2 echo for admin rights itself loses it then.
timeout /t 5 >nul

:run
if exist "%IPMIVIEW%" goto :found
>&2 echo IPMIView not found: adjust IPMIVIEW at the top of this file ^(%~f0^)
pause
exit /b 1

:found
for %%F in ("%IPMIVIEW%") do set "IPMIDIR=%%~dpF"
rem (no ( ) block here: a ")" in the path, like "Program Files (x86)", would end it)
if not exist "%AGENT%" goto :noagent
set "JAVA_TOOL_OPTIONS=-javaagent:"%AGENT%""
goto :start
:noagent
>&2 echo "%AGENT%" not found: starting without the agent.
timeout /t 5 >nul

:start
rem (folder with "." after its "\": no \" for the quote)
if exist "%USERSETTINGS%\" goto :usersettings
start "" /d "%IPMIDIR%." "%IPMIVIEW%"
exit /b 0

:usersettings
rem the folder with "/" at its end: IPMIView puts the file name right after it, and "\" before
rem the closing quote would escape it
start "" /d "%IPMIDIR%." "%IPMIVIEW%" - "%USERSETTINGS%/"
exit /b 0
