@echo off

:: iKVM-KeyPasta: starts IPMIView as admin, with the Java agent (Start menu shortcut "IPMIView
:: with KeyPasta" from install.cmd). Started as normal user, it starts itself again as admin
:: (UAC prompt). Declined: IPMIView as normal user, still with the agent.
::   - Admin from the start: the iKVM viewer needs it anyway. Started as normal user, it gets the
::     rights through a UAC prompt, which starts it again without this script's environment.
::   - JAVA_TOOL_OPTIONS is set here only, for IPMIView and the viewers it starts: no variable for
::     all Java programs (which none of them survives if the jar goes missing).
::
:: Keep this file next to iKVM-KeyPasta-agent.jar, in a folder only admins can write to
:: (%ProgramFiles%\iKVM-KeyPasta\): it runs as admin.

setlocal

:: IPMIView's program
set "IPMIVIEW=%ProgramFiles%\SUPERMICRO\IPMIView\IPMIView20.exe"
set "AGENT=%~dp0iKVM-KeyPasta-agent.jar"
set "SELF=%~f0"

rem Not admin: start again as admin (UAC prompt). Through cmd /c ""script" args", see
rem iKVM-jnlp-launcher.cmd: started directly, cmd would strip the quotes of the script's path.
fltmc >nul 2>&1
if not errorlevel 1 goto :run
if /i "%~1"=="/elevated" goto :noadmin
powershell -NoProfile -Command "$q = [char]34; Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList ('/c ' + $q + $q + $env:SELF + $q + ' /elevated' + $q)" >nul 2>&1
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
start "" /d "%IPMIDIR%." "%IPMIVIEW%"
exit /b 0
