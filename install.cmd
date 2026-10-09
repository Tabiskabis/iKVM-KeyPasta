@echo off

:: iKVM-KeyPasta installer for Windows. Run it from the folder with the files, as yourself.
::   1. As admin (UAC prompt): copies the files to %ProgramFiles%\iKVM-KeyPasta\, a folder only
::      admins can write to (the jar is loaded by the viewer running as admin, the script runs
::      with UI Access: copies you can write to would let any program running as you take that
::      over). Permissions as inherited there, no "downloaded from the internet" mark.
::   2. As you: offers iKVM-jnlp-launcher.cmd for .jnlp files (/register: choosing it is up to
::      you, in Open with), adds "IPMIView with KeyPasta" to the Start menu (IPMIView as admin
::      with the Java agent, see iKVM-IPMIView-launcher.cmd) and starts the AutoHotkey script
::      (exe, or else .ahk), now and at logon with a shortcut in your Startup folder.
::      Without the exe and AutoHotkey 2.0.0 or newer: asks whether to install AutoHotkey with
::      winget (for all users: UI Access works only from %ProgramFiles%).
::   3. If OpenWebStart (for .jnlp files) is missing: asks whether to install it with winget.
:: No environment variables. Run it again to update. uninstall.cmd undoes all of it.

setlocal

set "DEST=%ProgramFiles%\iKVM-KeyPasta"
set "SRC=%~dp0"
set "FILES=iKVM-KeyPasta-agent.jar iKVM-jnlp-launcher.cmd iKVM-IPMIView-launcher.cmd iKVM-KeyPasta.ahk iKVM-KeyPasta.exe PPCH_outlined_dark.ico PPCH_outlined_light.ico PPCH_outlined_dark-suspended.ico PPCH_outlined_light-suspended.ico"
set "SELF=%~f0"

if /i "%~1"=="/elevated" goto :elevated

fltmc >nul 2>&1
if errorlevel 1 goto :elevate
:: admin already: everything here, for this account
call :copy
if errorlevel 1 goto :failed
goto :user

:elevate
:: the files as admin, waiting for it; then this user's part here
:: Through cmd /c ""script" args": started directly, Windows runs a .cmd as cmd /C "script" args,
:: and cmd then strips the first and the last quote of that line whenever there are more than
:: two quotes or a ( ) & etc. in the path: the script isn't found (window flashes and closes).
powershell -NoProfile -Command "$q = [char]34; try { $p = Start-Process -Verb RunAs -Wait -PassThru -FilePath $env:ComSpec -ArgumentList ('/c ' + $q + $q + $env:SELF + $q + ' /elevated' + $q); exit $p.ExitCode } catch { exit 99 }"
if errorlevel 99 (
    >&2 echo Not installed: the UAC prompt was declined.
    pause
    exit /b 1
)
if errorlevel 1 goto :failed
goto :user

:elevated
call :copy
if errorlevel 1 (
    pause
    exit /b 1
)
exit /b 0

:failed
>&2 echo Not all files could be installed, nothing else changed.
pause
exit /b 1

:: ---- as admin: the files ----
:copy
:: the running exe can't be overwritten: a new instance with /exit closes it (see uninstall.cmd)
if exist "%DEST%\iKVM-KeyPasta.exe" start "" /wait "%DEST%\iKVM-KeyPasta.exe" /exit
echo Installing to "%DEST%":
if not exist "%DEST%" mkdir "%DEST%"
set "FAILED="
for %%F in (%FILES%) do (
    if exist "%SRC%%%F" (
        copy /y "%SRC%%%F" "%DEST%\%%F" >nul 2>&1
        rem compared: a file in use, like the running exe, can't be overwritten
        fc /b "%SRC%%%F" "%DEST%\%%F" >nul 2>&1
        if errorlevel 1 (
            >&2 echo   %%F: FAILED, still running?
            set "FAILED=1"
        ) else (
            echo   %%F
        )
    )
)
:: permissions only as inherited from %ProgramFiles% (users read and run, admins write), and no
:: "downloaded from the internet" mark, which would make Windows ask before running the scripts
icacls "%DEST%" /reset /t /c /q >nul
powershell -NoProfile -Command "Get-ChildItem -LiteralPath $env:DEST | Unblock-File" >nul 2>&1
if defined FAILED exit /b 1
exit /b 0

:: ---- as the user: .jnlp files, autostart ----
:user
echo.
if exist "%DEST%\iKVM-jnlp-launcher.cmd" (
    call "%DEST%\iKVM-jnlp-launcher.cmd" /register /quiet
    if errorlevel 1 (
        >&2 echo The .jnlp launcher couldn't be offered for .jnlp files.
    ) else (
        echo To open .jnlp files with the launcher: right-click one, Open with, Choose another app,
        echo   "iKVM-KeyPasta launcher", Always.
    )
)

:: Start menu: IPMIView as admin with the agent. The shortcut runs cmd.exe /c ""script"" (see
:: :elevate); the script asks for admin rights itself.
if not exist "%DEST%\iKVM-IPMIView-launcher.cmd" goto :autostart
if not exist "%ProgramFiles%\SUPERMICRO\IPMIView\IPMIView20.exe" goto :autostart
set "LNKARGS=/c ""%DEST%\iKVM-IPMIView-launcher.cmd"""
powershell -NoProfile -Command "$p = Join-Path ([Environment]::GetFolderPath('Programs')) 'IPMIView with KeyPasta.lnk'; $s = (New-Object -ComObject WScript.Shell).CreateShortcut($p); $s.TargetPath = $env:ComSpec; $s.Arguments = $env:LNKARGS; $s.WorkingDirectory = $env:DEST; $s.IconLocation = $env:DEST + '\PPCH_outlined_dark.ico'; $s.Description = 'IPMIView with iKVM-KeyPasta'; $s.Save()" >nul 2>&1
if errorlevel 1 >&2 echo The Start menu shortcut for IPMIView couldn't be created.

:autostart
set "AUTOSTART="
if exist "%DEST%\iKVM-KeyPasta.ahk" set "AUTOSTART=%DEST%\iKVM-KeyPasta.ahk"
if exist "%DEST%\iKVM-KeyPasta.exe" set "AUTOSTART=%DEST%\iKVM-KeyPasta.exe"
if not defined AUTOSTART goto :done
powershell -NoProfile -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'iKVM-KeyPasta.lnk')); $s.TargetPath = $env:AUTOSTART; $s.WorkingDirectory = $env:DEST; $s.IconLocation = $env:DEST + '\PPCH_outlined_dark.ico'; $s.Save()" >nul 2>&1
if errorlevel 1 >&2 echo The autostart shortcut couldn't be created.
:: the .ahk needs AutoHotkey 2.0.0 or newer; for UI Access installed for all users
if /i not "%AUTOSTART:~-4%"==".ahk" goto :run
call :ahkversion
if %AHKMAJOR% GEQ 2 goto :run
echo.
echo AutoHotkey v2 isn't installed: needed to run iKVM-KeyPasta.ahk.
where winget >nul 2>&1
if errorlevel 1 goto :noahk
set "ANSWER="
set /p "ANSWER=Install it now (winget install AutoHotkey.AutoHotkey, for all users)? [Y/N] "
if /i not "%ANSWER%"=="Y" goto :noahk
winget install --exact --id AutoHotkey.AutoHotkey --scope machine
call :ahkversion
if %AHKMAJOR% GEQ 2 goto :run
:noahk
>&2 echo The script won't start until AutoHotkey v2 is installed: https://www.autohotkey.com/
goto :done

:run
:: and now (it asks for its rights itself, UI Access or a UAC prompt)
start "" /d "%DEST%" "%AUTOSTART%"

:done
:: OpenWebStart for .jnlp files, where the launcher expects it
if exist "%ProgramFiles%\OpenWebStart\javaws.exe" goto :end
echo.
echo OpenWebStart isn't installed: needed to open the iKVM viewer's .jnlp files.
where winget >nul 2>&1
if errorlevel 1 (
    echo Get it from https://openwebstart.com/
    goto :end
)
set "ANSWER="
set /p "ANSWER=Install it now (winget install Karakun.OpenWebStart)? [Y/N] "
if /i not "%ANSWER%"=="Y" goto :end
winget install --exact --id Karakun.OpenWebStart
if errorlevel 1 >&2 echo OpenWebStart couldn't be installed. Get it from https://openwebstart.com/

:end
echo.
echo Done. See REAMDE.md for installation of the .user.js in your browser for the best HTML5 iKVM experience.
echo.
echo Press any key to close this message . . .
pause >NUL
exit /b 0

:: AHKMAJOR: major version of the installed AutoHotkey (0: none), from its uninstall entry
:: (DisplayVersion, like 2.0.19; for all users, 32-bit programs' view, or yours)
:ahkversion
set "AHKMAJOR=0"
set "UNINSTALL=SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AutoHotkey"
call :ahkkey "HKLM\%UNINSTALL%"
if %AHKMAJOR% LSS 2 call :ahkkey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\AutoHotkey"
if %AHKMAJOR% LSS 2 call :ahkkey "HKCU\%UNINSTALL%"
exit /b 0

:ahkkey
set "AHKVERSION="
rem the line "    DisplayVersion    REG_SZ    2.0.19"
for /f "tokens=1-3" %%A in ('reg query "%~1" /v DisplayVersion 2^>nul') do (
    if /i "%%A"=="DisplayVersion" set "AHKVERSION=%%C"
)
if not defined AHKVERSION exit /b 0
for /f "delims=." %%M in ("%AHKVERSION%") do set /a "AHKMAJOR=%%M" 2>nul
exit /b 0
