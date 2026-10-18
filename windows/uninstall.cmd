@echo off

:: iKVM-KeyPasta uninstaller for Windows, undoes install.cmd. Run it as yourself.
::   1. As you: removes the .jnlp launcher's registration (/unregister), the Start menu shortcut
::      for IPMIView and the autostart shortcut. Checks JAVA_TOOL_OPTIONS: pointing to the removed jar, no Java program would
::      start anymore.
::   2. As admin (UAC prompt): closes the running AutoHotkey script, deletes the installed files
::      from %ProgramFiles%\iKVM-KeyPasta\ (the folder too, unless something else is in it).
:: Kept: the .jnlp copies in %TEMP%\iKVM-KeyPasta\ (see iKVM-jnlp-launcher.cmd).

setlocal

set "DEST=%ProgramFiles%\iKVM-KeyPasta"
set "FILES=iKVM-KeyPasta-agent.jar iKVM-jnlp-launcher.cmd iKVM-IPMIView-launcher.cmd iKVM-KeyPasta.ahk iKVM-KeyPasta.exe PPCH_outlined_dark.ico PPCH_outlined_light.ico PPCH_outlined_dark-suspended.ico PPCH_outlined_light-suspended.ico"
set "SELF=%~f0"
set "PROGID=iKVM-KeyPasta.jnlp"

if /i "%~1"=="/elevated" goto :elevated

call :user
if errorlevel 1 exit /b 1

fltmc >nul 2>&1
if errorlevel 1 goto :elevate
:: admin already
call :remove
goto :done

:elevate
:: Through cmd /c ""script" args": started directly, Windows runs a .cmd as cmd /C "script" args,
:: and cmd then strips the first and the last quote of that line whenever there are more than
:: two quotes or a ( ) & etc. in the path: the script isn't found (window flashes and closes).
powershell -NoProfile -Command "$q = [char]34; try { $p = Start-Process -Verb RunAs -Wait -PassThru -FilePath $env:ComSpec -ArgumentList ('/c ' + $q + $q + $env:SELF + $q + ' /elevated' + $q); exit $p.ExitCode } catch { exit 99 }"
if errorlevel 99 (
    >&2 echo The files weren't removed: the UAC prompt was declined.
    pause
    exit /b 1
)
goto :done

:elevated
call :remove
if errorlevel 1 (
    pause
    exit /b 1
)
exit /b 0

:done
echo.
echo Done. If .jnlp files were opened with the launcher, choose OpenWebStart again for them:
echo   right-click a .jnlp file, Open with, Choose another app, Always.
pause
exit /b 0

:: ---- as the user ----
:user
:: JAVA_TOOL_OPTIONS with the agent: 1 = yours, 2 = for all users, 3 = both
powershell -NoProfile -Command "$r = 0; if ([Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', 'User') -like '*iKVM-KeyPasta-agent.jar*') { $r += 1 }; if ([Environment]::GetEnvironmentVariable('JAVA_TOOL_OPTIONS', 'Machine') -like '*iKVM-KeyPasta-agent.jar*') { $r += 2 }; exit $r"
set "JTO=%errorlevel%"
if "%JTO%"=="2" goto :machinevar
if "%JTO%"=="3" goto :machinevar
if not "%JTO%"=="1" goto :unregister
echo Your environment variable JAVA_TOOL_OPTIONS loads the agent. Without the jar, no Java
echo program would start anymore.
set "ANSWER="
set /p "ANSWER=Remove the variable? [Y/N] "
if /i not "%ANSWER%"=="Y" (
    >&2 echo Not uninstalled.
    pause
    exit /b 1
)
powershell -NoProfile -Command "[Environment]::SetEnvironmentVariable('JAVA_TOOL_OPTIONS', $null, 'User')"
echo   JAVA_TOOL_OPTIONS removed.
goto :unregister

:machinevar
>&2 echo JAVA_TOOL_OPTIONS for all users loads the agent. Without the jar, no Java program would
>&2 echo start anymore: remove it first ^(System Properties, Environment Variables^).
pause
exit /b 1

:unregister
reg delete "HKCU\Software\Classes\%PROGID%" /f >nul 2>&1
reg delete "HKCU\Software\Classes\.jnlp\OpenWithProgids" /v "%PROGID%" /f >nul 2>&1
powershell -NoProfile -Command "Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'iKVM-KeyPasta.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'IPMIView with KeyPasta.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'IPMIView (iKVM-KeyPasta).lnk') -ErrorAction SilentlyContinue"
echo   .jnlp launcher registration, IPMIView Start menu and autostart shortcuts removed.
exit /b 0

:: ---- as admin ----
:remove
:: the running script closes itself: a new instance with /exit closes it (any folder, .ahk or exe)
if exist "%DEST%\iKVM-KeyPasta.exe" (
    start "" /wait "%DEST%\iKVM-KeyPasta.exe" /exit
) else if exist "%DEST%\iKVM-KeyPasta.ahk" (
    start "" /wait "%DEST%\iKVM-KeyPasta.ahk" /exit
    timeout /t 3 /nobreak >nul
)
echo Removing "%DEST%":
set "FAILED="
for %%F in (%FILES%) do (
    if exist "%DEST%\%%F" (
        del /f /q "%DEST%\%%F" >nul 2>&1
        if exist "%DEST%\%%F" (
            >&2 echo   %%F: FAILED, still running?
            set "FAILED=1"
        ) else (
            echo   %%F
        )
    )
)
rd "%DEST%" 2>nul
if exist "%DEST%" echo   Folder kept: other files in it.
if defined FAILED exit /b 1
exit /b 0
