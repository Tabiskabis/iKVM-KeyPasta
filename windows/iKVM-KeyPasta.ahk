; iKVM-KeyPasta: keyboard fix and clipboard paste for the Supermicro/ATEN iKVM viewers
; (Java app and HTML5 browser viewer). See README.md.
; https://github.com/Tabiskabis/iKVM-KeyPasta

#Requires AutoHotkey v2.0
#Warn                       ; Enable warnings to assist with detecting common errors
#SingleInstance Off         ; replaced by CloseOtherInstances (works across privilege levels)
Persistent                  ; Do not exit script when actions are finished
SetWorkingDir A_ScriptDir   ; Ensure a consistent starting directory
A_MaxHotkeysPerInterval := 200   ; default 70 per 2 s (press and release both count): in iKVM windows every
                            ; key is a hotkey, and from about 18 keys/s AutoHotkey stops with a warning box
A_StringCaseSense := "On"   ; Default is case insensitive match and replace -> NOPE (note: StrReplace/InStr need their own CaseSense param in v2)

; Debug mode: set to true to record key history, executed lines and a log of the messages to the
; iKVM Java app (see TellJava), with tray menu entries for viewing them.
; NEVER leave this on: the key history contains passwords.
DebugMode := false
KeyHistory DebugMode ? 500 : 0
ListLines DebugMode
LogLines := []              ; iKVM Java log (see Log)
LogGui := 0
TrayIconShown := ""         ; icon currently shown (see SetTrayIcon)
ExitOnly := false           ; /exit: only close the running instance (install.cmd, uninstall.cmd), see CloseOtherInstances
for Arg in A_Args
    if (Arg = "/exit")
        ExitOnly := true
if (ExitOnly) {             ; no tray icon, no hotkeys while it waits for the other one to close
    A_IconHidden := true
    Suspend true
} else
    SetTrayIcon(false)      ; right away, before the restarts for more rights (see RestartPrivileged)

; EXE informational properties
;@Ahk2Exe-SetProductName AutoHotkey
;@Ahk2Exe-SetLegalTrademarks AHK executable: autohotkey.com
;@Ahk2Exe-SetCopyright AHK script by Tabiskabis: CC BY 3.0
;@Ahk2Exe-SetDescription iKVM-KeyPasta: Supermicro/ATEN iKVM keyboard fix and clipboard paste
;@Ahk2Exe-SetFileVersion 2.0.0.0

; If code signing is not feasible, uncomment this to automatically request elevation when launched
;;@Ahk2Exe-UpdateManifest 1


; Individual Configuration (* is the suggested default)
; RemoteLayoutSetting, PasteInOtherApps, PasteNonAscii and RemoteWindows are the defaults at
; startup, they can be changed at runtime in the tray menu.

PasteHotkey := "!+v"        ; * Alt+Shift+V: paste hotkey, AutoHotkey style: modifiers (^ Ctrl, ! Alt,
                            ;   + Shift, # Win), then the key: by its letter like Ctrl+V, so on
                            ;   whichever key the local layout has it

RemoteLayoutSetting := "auto" ; layout of the remote, for pasting: "de-CH" Swiss German, "fr-CH" Swiss
                            ;   French, "de-DE" German, "us" United States, "other": always safe paste
                            ;   (alt codes, any layout). * "auto": the first of these four in the
                            ;   input language list (Windows settings), else Swiss German; a paste
                            ;   with line breaks or AltGr characters then asks first. A layout chosen
                            ;   in the tray menu for an iKVM Java window is kept for its BMC (the
                            ;   [host] in its title; remoteLayout@<host> in the agent's settings
                            ;   file, %AppData%\iKVM-KeyPasta\agent.properties, shared with the
                            ;   Java agent's KeyPasta Preferences)

PasteInOtherApps := true    ;  true: * activate shortcut for pasting clipboard to other programs, too
                            ; false:   use the hotkey for iKVM Java/HTML windows only

PasteNonAscii := "ask"      ;  true:   always send characters that need alt codes
                            ; false:   omit non-ASCII characters that need alt codes
                            ; "ask": * prompt user what to do

RemoteWindows := false      ;  true:   Remote is Windows: € and the other Windows-1252 characters 128-159
                            ;          (curly quotes, dashes, ...) are sent with their ANSI code (Alt+0128)
                            ; false: * Remote is Linux console: they are sent as Unicode code point (Alt+8364)
                            ; Everything else is sent the same way in both modes (see AltCodeDigits).

JavaKeyDelay := 2           ; ms between keystrokes sent to the iKVM Java app: raise if characters get lost
                            ; when pasting large text, lower for speed (-1: none at all)
JavaKeyPressDuration := -1  ; ms each key is held down. -1 (none) is best: iKVM sends a key as one message
                            ; at its release, and as separate press and release (auto-repeat on the
                            ; remote, lock keys lost) if held longer than its "Repeat Key timeout"

HtmlKeyDelay := 10          ; ms per keystroke when pasting into iKVM/HTML5. The browser takes keys far
                            ; faster than the BMC types them, the rest piles up in the BMC: the viewer
                            ; freezes, and the paste can't be stopped anymore. Raise if that happens.

ConfirmCtrlAltDel := true   ;  true: * ask before Ctrl+Alt+End sends Ctrl+Alt+Del to the remote (a Linux
                            ;          console reboots right away); the dialog can turn it off for 4 hours
                            ; false:   send it right away


; Privileges: Windows refuses keystrokes and messages to windows of programs running as admin
; (the iKVM Java app may run that way), unless this script has UI Access or runs as admin itself.
; The first time a message to it is refused, the script restarts itself with more rights, see
; RestartPrivileged. A restart passes on how far it got (/elevate-stage=...) and the tray menu
; settings (/set:Name=Value).
ElevationStage := ""
CtrlAltDelQuietUntil := ""  ; Ctrl+Alt+Del question turned off until then (YYYYMMDDHH24MISS), see ^<!End
ElevationFailed := false    ; got refused, but more rights weren't possible: don't try again
LoadedByScript := Map()     ; layouts this script loaded (KLID -> handle), unloaded on exit, see QuietLayout
; Read by #HotIf conditions, which can run before the auto-execute section reaches their code
; (e.g. while CloseOtherInstances waits): set here, before anything that can wait
CtrlSent := false           ; left Ctrl sent down, see *LCtrl
CtrlPending := false        ; left Ctrl is being held back right now, see *LCtrl
JavaPasting := false        ; pasting into iKVM Java, see PasteIntoKvm
JavaPasteSc := 0            ; the paste hotkey's key while it's held, see JavaKey
RemoteLayoutChosen := RemoteLayoutSetting != "auto"    ; said by the user: a paste doesn't ask about it
for Arg in A_Args {
    if (RegExMatch(Arg, "i)^/elevate-stage=(\w+)$", &Match))
        ElevationStage := Match[1]
    if (!RegExMatch(Arg, "^/set:(\w+)=(.*)$", &Match))
        continue
    switch Match[1] {
        case "RemoteLayoutSetting": RemoteLayoutSetting := Match[2]
        case "RemoteLayoutChosen":  RemoteLayoutChosen := Integer(Match[2])
        case "PasteInOtherApps":    PasteInOtherApps := Integer(Match[2])
        case "PasteNonAscii":       PasteNonAscii := (Match[2] = "ask") ? "ask" : Integer(Match[2])
        case "RemoteWindows":       RemoteWindows := Integer(Match[2])
        case "CtrlAltDelQuietUntil": CtrlAltDelQuietUntil := Match[2]
    }
}

; Remote layouts for fast paste: setting -> KLID and name (tray menu order)
RemoteLayouts := Map("de-CH", {Klid: "00000807", Name: "Swiss German"}, "fr-CH", {Klid: "0000100C", Name: "Swiss French"}
    , "de-DE", {Klid: "00000407", Name: "German"}, "us", {Klid: "00000409", Name: "United States"})
RemoteLayoutOrder := ["de-CH", "fr-CH", "de-DE", "us"]
; The Java agent's settings file (agent.properties): a BMC's remote layout is remoteLayout@<host>
; there, the agent's own key, so the tray menu and the viewer's KeyPasta Preferences set the same one
AgentSettingsFile := (EnvGet("KEYPASTA_SETTINGS_DIR") != "" ? EnvGet("KEYPASTA_SETTINGS_DIR")
    : A_AppData "\iKVM-KeyPasta") "\agent.properties"
CurrentBmc := ""            ; BMC of the last active iKVM window ("" HTML5 or none), see NoteActiveBmc
if (RemoteLayoutSetting != "other" and !RemoteLayouts.Has(RemoteLayoutSetting)) {
    ; "auto" (or unknown): the first one in the input language list, else Swiss German
    RemoteLayoutSetting := "de-CH"
    for DetectCode in RemoteLayoutOrder
        if (IsConfiguredLayout(RemoteLayouts[DetectCode].Klid)) {
            RemoteLayoutSetting := DetectCode
            break
        }
}

; The paste hotkey's parts (see IsPasteKey, WaitForHotkeyRelease) and its readable name
HotkeyModifiers := [{Symbol: "^", Keys: ["Ctrl"], Name: "Ctrl"}, {Symbol: "!", Keys: ["Alt"], Name: "Alt"}
    , {Symbol: "+", Keys: ["Shift"], Name: "Shift"}, {Symbol: "#", Keys: ["LWin", "RWin"], Name: "Win"}]
RegExMatch(PasteHotkey, "^([\^!+#]*)(.+)$", &PasteMatch)
PasteMods := PasteMatch[1]
PasteKey := PasteMatch[2]
PasteKeyVk := GetKeyVK(PasteKey)
PasteHotkeyText := ""
for PasteModifier in HotkeyModifiers
    if (InStr(PasteMods, PasteModifier.Symbol))
        PasteHotkeyText .= PasteModifier.Name "+"
PasteHotkeyText .= StrLen(PasteKey) = 1 ? StrUpper(PasteKey) : PasteKey

; Like #SingleInstance Force: close an instance of this script that's already running, as .ahk
; or compiled .exe, from any folder (two of them would both remap the keys). Windows refuses
; that if it runs with more rights (UI Access or admin, see RestartPrivileged): then restart
; with more rights, too. If that's not possible, leave it running and exit (/exit: with exit code 1).
; Returns false if one is still running (it didn't close, not even by ProcessClose).
CloseOtherInstances() {
    Closed := true
    MyName := StrLower(RegExReplace(A_ScriptName, "\.[^.]*$"))
    DetectHiddenWindows true
    for Hwnd in WinGetList("ahk_class AutoHotkey") {
        try {
            if (WinGetPID("ahk_id " Hwnd) = ProcessExist())
                continue
            ; the main window's title is the script's (or exe's) full path, for scripts followed
            ; by " - AutoHotkey v2..."
            if (!RegExMatch(WinGetTitle("ahk_id " Hwnd), "i)^(?:.*\\)?([^\\]+)\.(?:ahk|exe)(?: - AutoHotkey.*)?$", &Name)
                or StrLower(Name[1]) != MyName)
                continue
        } catch
            continue
        try PostMessage 0x111, 65307, , , "ahk_id " Hwnd    ; WM_COMMAND, ID_FILE_EXIT
        catch OSError as Err {
            if (Err.Number != 5)    ; ERROR_ACCESS_DENIED
                continue
            RestartPrivileged(false)    ; returns only if that's not possible
            if (ExitOnly)
                ExitApp 1
            MsgBox "iKVM-KeyPasta is already running with more rights (UI Access or admin)."
                . " Exit it from its tray menu to restart it.", "iKVM-KeyPasta", 0x40
            ExitApp
        }
        ; its exit (OnExit: layouts, Java's key table) takes a moment; hung: closed by force
        if (!WinWaitClose("ahk_id " Hwnd, , 10)) {
            try ProcessClose(WinGetPID("ahk_id " Hwnd))
            if (!WinWaitClose("ahk_id " Hwnd, , 2))
                Closed := false
        }
    }
    DetectHiddenWindows false
    return Closed
}

HasUIAccess() {
    Token := 0
    if (!DllCall("advapi32\OpenProcessToken", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "UInt", 0x0008, "Ptr*", &Token))  ; TOKEN_QUERY
        return false
    UIAccess := 0
    Size := 0
    Ok := DllCall("advapi32\GetTokenInformation", "Ptr", Token, "Int", 26, "UInt*", &UIAccess, "UInt", 4, "UInt*", &Size)  ; TokenUIAccess
    DllCall("CloseHandle", "Ptr", Token)
    return Ok and UIAccess
}

; Restart with more rights, in this order:
;   1. UI Access (AutoHotkey*_UIA.exe, part of the AutoHotkey installation, .ahk only)
;   2. admin (UAC prompt)
; Returns only if neither is possible (or declined); the script then carries on without,
; shown in the tray menu (click it to try again) and, if Notify, in a notification.
; Tried at most once per stage (the restart passes the stage on).
RestartPrivileged(Notify := true) {
    global ElevationFailed
    if (ElevationFailed)
        return
    ElevationFailed := true
    if (A_IsAdmin or HasUIAccess())     ; got refused anyway, more isn't possible
        return
    Settings := " /set:RemoteLayoutSetting=" RemoteLayoutSetting
        . " /set:RemoteLayoutChosen=" RemoteLayoutChosen
        . " /set:PasteInOtherApps=" PasteInOtherApps
        . " /set:PasteNonAscii=" PasteNonAscii
        . " /set:RemoteWindows=" RemoteWindows
        . " /set:CtrlAltDelQuietUntil=" CtrlAltDelQuietUntil
        . (ExitOnly ? " /exit" : "")
    if (ElevationStage = "" and !A_IsCompiled) {
        UiaPath := RegExReplace(A_AhkPath, "i)(?<!_UIA)\.exe$", "_UIA.exe")
        if (UiaPath != A_AhkPath and FileExist(UiaPath)) {
            try {
                Run '"' UiaPath '" /restart "' A_ScriptFullPath '" /elevate-stage=uia' Settings
                ExitApp
            }
        }
    }
    if (ElevationStage != "admin") {
        try {
            if (A_IsCompiled)
                Run '*RunAs "' A_ScriptFullPath '" /restart /elevate-stage=admin' Settings
            else
                Run '*RunAs "' RegExReplace(A_AhkPath, "i)_UIA(\.exe)$", "$1") '" /restart "' A_ScriptFullPath '" /elevate-stage=admin' Settings
            ExitApp
        }
    }
    BuildTrayMenu()
    if (Notify)
        TrayTip "No admin rights: iKVM Java windows (running as admin) are out of reach."
            . " To try again, click the first entry in the tray menu.", "iKVM-KeyPasta", 0x2
}

RetryPrivileged(*) {
    global ElevationFailed := false
    RestartPrivileged()
}

OthersClosed := CloseOtherInstances()
if (ExitOnly)
    ExitApp OthersClosed ? 0 : 1


; Windows-1252 characters 128-159 (Unicode code point -> ANSI code), see AltCodeDigits
Cp1252Extra := Map(
    0x20AC, 128, 0x201A, 130, 0x0192, 131, 0x201E, 132, 0x2026, 133, 0x2020, 134, 0x2021, 135,
    0x02C6, 136, 0x2030, 137, 0x0160, 138, 0x2039, 139, 0x0152, 140, 0x017D, 142,
    0x2018, 145, 0x2019, 146, 0x201C, 147, 0x201D, 148, 0x2022, 149, 0x2013, 150, 0x2014, 151,
    0x02DC, 152, 0x2122, 153, 0x0161, 154, 0x203A, 155, 0x0153, 156, 0x017E, 158, 0x0178, 159
)

; iKVM Java windows told to use the US key table (see TellJava): window -> true
ToldJava := Map()
RightsChecked := Map()      ; iKVM Java windows with the agent checked for reachability, see HandleActiveWindow
JavaWatch := 0              ; active iKVM Java window and its layout, see WatchJavaLayout

; SendEvent with a fixed key delay for the Java app (see SendKeys)
SetKeyDelay JavaKeyDelay, JavaKeyPressDuration


; Tray menu & icons

; Images under creative commons License CC BY 3.0 CH by Pirate Party Switzerland
; https://www.piratenpartei.ch/logos-und-fotos/
;@Ahk2Exe-SetMainIcon PPCH_outlined_dark.ico
;@Ahk2Exe-AddResource PPCH_outlined_light.ico, 300
;@Ahk2Exe-AddResource PPCH_outlined_light-suspended.ico, 301
;@Ahk2Exe-AddResource PPCH_outlined_dark-suspended.ico, 302
; In the exe the icons are addressed by resource ID (negative IconNumber), not by
; index: 159 = main icon (dark), 300 = light, 301/302 = light/dark suspended. Indexes
; shift depending on how many icon groups the base exe contains and how named resources
; are sorted.

BuildTrayMenu()
; Windows broadcasts WM_SETTINGCHANGE "ImmersiveColorSet" when switching between dark and light mode
OnMessage(0x1A, SettingChanged)

; Get notified whenever the active window changes. A WinEvent hook, as the shell hook only reports
; windows with a taskbar button.
ForegroundCallback := CallbackCreate(ForegroundChanged, , 7)
DllCall("SetWinEventHook", "UInt", 0x0003, "UInt", 0x0003, "Ptr", 0, "Ptr", ForegroundCallback
    , "UInt", 0, "UInt", 0, "UInt", 0)  ; EVENT_SYSTEM_FOREGROUND, all processes, WINEVENT_OUTOFCONTEXT
; ... and when the active window changes its title: iKVM Java sets its title after activation.
; Hooked for the active window's process only (see WatchTitle), as title changes happen a lot.
TitleCallback := CallbackCreate(TitleChanged, , 7)
TitleHook := 0
TitleHookPid := 0
WindowActivated(WinExist("A"))
OnExit(ScriptExit)


; Window detection. Titles are matched from the start (browsers append their own name at the end).

ActiveTitle() {
    try
        return WinGetTitle("A")
    catch
        return ""
}

; iKVM Java app, e.g. "Java iKVM Viewer  [192.0.2.29_SSL]  " (IPMIView, note the double space)
; or "Java iKVM Viewer v1.69.44 [198.51.100.120]" (.jnlp from the BMC's web interface)
IsJavaKvm() {
    return RegExMatch(ActiveTitle(), "^Java iKVM Viewer( v\S+)? +\[")
}

; ... without the Java agent (iKVM-KeyPasta-agent.jar). With it, the title ends with " ⌨":
; the agent fixes the keys and pastes inside Java, here only Alt+Tab and Ctrl+Alt+End remain
IsJavaPlain() {
    return IsJavaKvm() and !InStr(ActiveTitle(), " ⌨")
}

; iKVM/HTML5 browser viewer, e.g. "Resolution:1024x768 FPS :20 — Mozilla Firefox"
; (before its JavaScript has set this, the page title is "Console Redirection - iKVM/HTML5")
IsHtmlKvm() {
    return RegExMatch(ActiveTitle(), "^Resolution:\d+.*FPS :\d+")
}

; iKVM/HTML5 viewer with the userscript iKVM-KeyPasta.user.js active (it appends " ⌨" to
; the page title): it sends every key by its position itself, nothing to remap here
IsHtmlPositional() {
    return IsHtmlKvm() and InStr(ActiveTitle(), " ⌨")
}

ForegroundChanged(HWinEventHook, Event, Hwnd, *) {
    SetTimer(() => WindowActivated(Hwnd), -1)  ; return right away, do the work afterwards
}

; Watch title changes (EVENT_OBJECT_NAMECHANGE) in the active window's process
WatchTitle(Hwnd) {
    global TitleHook, TitleHookPid
    try Pid := WinGetPID("ahk_id " Hwnd)
    catch
        return
    if (Pid = TitleHookPid)
        return
    if (TitleHook)
        DllCall("UnhookWinEvent", "Ptr", TitleHook)
    TitleHook := DllCall("SetWinEventHook", "UInt", 0x800C, "UInt", 0x800C, "Ptr", 0, "Ptr", TitleCallback
        , "UInt", Pid, "UInt", 0, "UInt", 0, "Ptr")  ; that process only, WINEVENT_OUTOFCONTEXT
    TitleHookPid := TitleHook ? Pid : 0
}

TitleChanged(HWinEventHook, Event, Hwnd, IdObject, IdChild, *) {
    ; the window itself (OBJID_WINDOW, CHILDID_SELF), not some control in it, and only the active one
    if (IdObject = 0 and IdChild = 0 and Hwnd = WinExist("A"))
        SetTimer(() => HandleActiveWindow(Hwnd), -1)
}

WindowActivated(Hwnd) {
    WatchTitle(Hwnd)
    NoteActiveBmc()
    HandleActiveWindow(Hwnd)
}

; The BMC of an iKVM Java window: the [host] in its title; "" if none
BmcOfTitle(Title) {
    return RegExMatch(Title, "^Java iKVM Viewer[^\[]*\[([^\]]+)\]", &BmcMatch) ? Trim(BmcMatch[1]) : ""
}

; The tray menu's remote layout is the one of the last active iKVM window's BMC
NoteActiveBmc() {
    global CurrentBmc
    if (IsJavaKvm())
        Bmc := BmcOfTitle(ActiveTitle())
    else if (IsHtmlKvm())
        Bmc := ""                   ; its title has no host: the default layout
    else
        return
    if (Bmc != CurrentBmc) {
        CurrentBmc := Bmc
        BuildTrayMenu()
    }
}

; Remote layout for a BMC: {Setting, Chosen}. Its own if chosen in the tray menu for it, else the
; default (RemoteLayoutSetting).
LayoutFor(Bmc) {
    if (Bmc != "") {
        Saved := ReadAgentSettings().Get("remoteLayout@" Bmc, "")
        if (Saved == "other" or RemoteLayouts.Has(Saved))
            return {Setting: Saved, Chosen: true}
    }
    return {Setting: RemoteLayoutSetting, Chosen: RemoteLayoutChosen}
}


; Keyboard layouts

WindowThread(Hwnd) {
    return DllCall("GetWindowThreadProcessId", "Ptr", Hwnd, "Ptr", 0, "UInt")
}

; Keyboard layout handle (HKL) of a window's thread.
; Low word: language, high word: keyboard layout (e.g. 0x0807 = Swiss German keyboard),
; or 0xFnnn for layout variants and custom layouts (nnn = "Layout Id" in the registry)
WindowLayout(Hwnd) {
    return DllCall("GetKeyboardLayout", "UInt", WindowThread(Hwnd), "Ptr")
}

; Layouts in the input language list
LoadedLayouts() {
    Count := DllCall("GetKeyboardLayoutList", "Int", 0, "Ptr", 0)
    Buf := Buffer(Count * A_PtrSize)
    Count := DllCall("GetKeyboardLayoutList", "Int", Count, "Ptr", Buf)
    Layouts := []
    Loop Count
        Layouts.Push(NumGet(Buf, (A_Index - 1) * A_PtrSize, "Ptr"))
    return Layouts
}

; Handle of a standard layout (KLID like "00000409"), any language. Loaded into this session if
; it isn't loaded (without activating it anywhere, not shown in the language bar), and unloaded
; again on exit (see ScriptExit). 0 if it can't be loaded.
QuietLayout(Klid) {
    High := Integer("0x" SubStr(Klid, 5))
    for Hkl in LoadedLayouts()
        if (((Hkl >> 16) & 0xFFFF) = High)
            return Hkl
    Hkl := DllCall("LoadKeyboardLayout", "Str", Klid, "UInt", 0x80, "Ptr")  ; KLF_NOTELLSHELL
    ; On failure Windows returns some other (default) layout instead
    if (((Hkl >> 16) & 0xFFFF) != High)
        return 0
    LoadedByScript[Klid] := Hkl
    Log("  loaded layout " Klid " as " HexLayout(Hkl))
    return Hkl
}

; Layout the remote uses, for pasting: a setting of LayoutFor, not "other"
RemoteLayout(Setting) {
    return QuietLayout(RemoteLayouts[Setting].Klid)
}

; Swiss German or Swiss French (also as a variant)
IsSwissLayout(Hkl) {
    High := (Hkl >> 16) & 0xFFFF
    return High = 0x0807 or High = 0x100C
}

; Is the layout (KLID) in the user's input language list (HKCU\Keyboard Layout\Preload,
; entries there may refer to HKCU\Keyboard Layout\Substitutes)
IsConfiguredLayout(Klid) {
    try {
        Loop Reg, "HKCU\Keyboard Layout\Preload" {
            Entry := RegRead()
            try Entry := RegRead("HKCU\Keyboard Layout\Substitutes", Entry)
            if (StrLower(Entry) == StrLower(Klid))  ; (case-insensitive: Klids may differ in case)
                return true
        }
    }
    return false
}

; On exit: real tables back to the iKVM Java windows, then unload the layouts this script loaded
; (kept if they're in the input language list meanwhile)
ScriptExit(*) {
    global ElevationFailed := true  ; no restart for more rights while exiting
    UntellAllJava()
    for Klid, Hkl in LoadedByScript
        if (!IsConfiguredLayout(Klid))
            DllCall("UnloadKeyboardLayout", "Ptr", Hkl)
}


; iKVM Java app: the US key table
; The Java app turns Windows key codes into key positions with a table it builds from the
; keyboard layout named in the last WM_INPUTLANGCHANGE message it got. With a Swiss layout,
; several positions can't be reached at all. Telling it the layout changed to US makes it build
; the US table, while Windows stays on the Swiss layout: every US key code then arrives at its
; US position, and the hotkeys below send the US key code of each physical key's position.

; Tell an iKVM Java window the layout changed to US (Us = true), or to its real layout again.
; Sent to the control with the keyboard focus and the window itself. Refused for programs
; running as admin: then restart with more rights (see RestartPrivileged).
TellJava(Hwnd, Us := true) {
    Hkl := Us ? QuietLayout("00000409") : WindowLayout(Hwnd)
    if (!Hkl)
        return Log("  US layout couldn't be loaded")
    Focus := FocusedWindow(Hwnd)
    for Target in (Focus != Hwnd) ? [Focus, Hwnd] : [Hwnd] {
        try PostMessage 0x51, 0, Hkl, , "ahk_id " Target        ; WM_INPUTLANGCHANGE
        catch OSError as Err {
            Log("  tell " HexLayout(Hkl) " to " Target ": refused, error " Err.Number)
            if (Err.Number = 5)     ; ERROR_ACCESS_DENIED
                RestartPrivileged()
            return
        }
    }
    if (Us)
        ToldJava[Hwnd] := true
    else if (ToldJava.Has(Hwnd))
        ToldJava.Delete(Hwnd)
    Log("  told " (Us ? "US " : "real layout ") HexLayout(Hkl))
}

; Suspend and exit: give all iKVM Java windows their real table back
UntellAllJava() {
    for Hwnd in ToldJava.Clone() {
        if (WinExist("ahk_id " Hwnd))
            TellJava(Hwnd, false)
        else
            ToldJava.Delete(Hwnd)
    }
}

; The control with the keyboard focus in a window's thread (GetGUIThreadInfo), or the window itself
FocusedWindow(Hwnd) {
    Info := Buffer(8 + 6 * A_PtrSize + 16, 0)       ; GUITHREADINFO
    NumPut("UInt", Info.Size, Info)
    if (DllCall("GetGUIThreadInfo", "UInt", WindowThread(Hwnd), "Ptr", Info)) {
        Focus := NumGet(Info, 8 + A_PtrSize, "Ptr")     ; hwndFocus
        if (Focus)
            return Focus
    }
    return Hwnd
}

; Act on the active window (activated, or its title changed): tell iKVM Java windows to use
; the US table, and keep watching their layout while they're active
HandleActiveWindow(Hwnd) {
    global JavaWatch
    if (A_IsSuspended or !Hwnd or Hwnd != WinExist("A") or !IsJavaKvm())
        return
    NoteActiveBmc()                 ; (the .jnlp viewer sets its title with the host only once connected)
    if (!IsJavaPlain()) {           ; Java agent: its real table back, if told earlier
        SetTimer(WatchJavaLayout, 0)
        if (ToldJava.Has(Hwnd)) {
            TellJava(Hwnd, false)
        } else if (!RightsChecked.Has(Hwnd)) {
            ; Alt+Tab and Ctrl+Alt+End still need messages to reach it (the viewer runs as admin):
            ; find out with a harmless one, its real layout, which it has anyway
            RightsChecked[Hwnd] := true
            TellJava(Hwnd, false)
        }
        return
    }
    Log("iKVM Java " WindowInfo(Hwnd))
    TellJava(Hwnd)
    JavaWatch := {Hwnd: Hwnd, Layout: WindowLayout(Hwnd)}
    SetTimer(WatchJavaLayout, 500)
}

; A layout change by hand makes Windows send the real WM_INPUTLANGCHANGE: tell it again
WatchJavaLayout() {
    if (A_IsSuspended or !JavaWatch or WinExist("A") != JavaWatch.Hwnd) {
        SetTimer(WatchJavaLayout, 0)
        return
    }
    Now := WindowLayout(JavaWatch.Hwnd)
    if (Now = JavaWatch.Layout)
        return
    Log("  layout changed to " HexLayout(Now))
    JavaWatch.Layout := Now
    TellJava(JavaWatch.Hwnd)
}


; Debug mode: log of the messages to the iKVM Java app (window changes and decisions, no keys)
Log(Text) {
    if (!DebugMode or (LogLines.Length and LogLines[-1] = Text))
        return
    LogLines.Push(Text)
    if (LogLines.Length > 500)
        LogLines.RemoveAt(1)
    if (LogGui)
        try LogGui["Log"].Value := LogText()
}

LogText() {
    Text := ""
    for Line in LogLines
        Text .= Line "`r`n"
    return Text
}

ShowLog(*) {
    global LogGui
    if (!LogGui) {
        LogGui := Gui("+Resize", "iKVM-KeyPasta: iKVM Java log")
        LogGui.SetFont(, "Consolas")
        LogGui.Add("Edit", "vLog ReadOnly -Wrap HScroll w900 h500")
        LogGui.OnEvent("Size", (G, MinMax, W, H) => G["Log"].Move(, , W - 20, H - 20))
        LogGui.OnEvent("Close", CloseLog)
    }
    LogGui["Log"].Value := LogText()
    LogGui.Show()
}

CloseLog(*) {
    global LogGui
    LogGui.Destroy()
    LogGui := 0
}

HexLayout(Hkl) {
    return Format("{:08X}", Hkl & 0xFFFFFFFF)
}

; Window description for the log
WindowInfo(Hwnd) {
    try {
        Title := WinGetTitle("ahk_id " Hwnd)
        Title := RegExReplace(Title, "\d+", "#")
        return Format('"{}" [{}] thread {} layout {}', SubStr(Title, 1, 60), WinGetClass("ahk_id " Hwnd)
            , WindowThread(Hwnd), HexLayout(WindowLayout(Hwnd)))
    }
    return "window " Hwnd " (gone)"
}


; Sending keys

; Java iKVM: SendEvent with a fixed key delay (SetKeyDelay above), so it can be
; raised if a slow connection loses keys. SendInput would ignore it, and it silently falls back
; to SendEvent (with whatever delay) as soon as any other program has a keyboard hook installed.
; iKVM/HTML5: SendInput
SendKeys(Keys) {
    if IsHtmlKvm()
        SendInput Keys
    else
        SendEvent Keys
}

; The number typed on the numpad for a character, the same for both remote OS where possible:
;   Windows reads Alt+nnn  (no leading 0) as OEM code page (CP850):    Alt+252  = ³
;   Windows reads Alt+0nnn (leading 0)    as ANSI code page (Win-1252): Alt+0252 = ü
;   Linux console reads both as Latin-1/Unicode code point:             Alt+252  = Alt+0252 = ü
; So 160-255 always get the leading 0 (Latin-1 = Windows-1252 there) and work on both.
; Only the 27 Windows-1252 characters in 128-159 (€ ‚ „ … ‘ ’ “ ” – — ™ etc.) differ.
AltCodeDigits(CodePoint) {
    if (CodePoint >= 160 and CodePoint <= 255)
        return "0" CodePoint
    if (RemoteWindows and Cp1252Extra.Has(CodePoint))
        return "0" Cp1252Extra[CodePoint]
    return String(CodePoint)  ; ASCII, or Unicode (Linux console; on Windows only some programs)
}

; Alt+Numpad. iKVM/HTML5: browsers forward the keystrokes to the viewer (the remote composes the
; character) AND compose the same character locally when Alt is released, which the viewer
; forwards as well -> every alt-coded character would arrive twice. Pressing an unassigned key
; (vkE8, the same "mask" key AHK itself uses) before Alt up cancels the local composition.
SendAltCode(CodePoint) {
    Keys := "{LAlt down}"
    Loop Parse AltCodeDigits(CodePoint)
        Keys .= "{Numpad" A_LoopField "}"
    SendKeys(Keys (IsHtmlKvm() ? "{vkE8}" : "") "{LAlt up}")
}


; Pasting the clipboard

; iKVM Java: US key code of each key position (scan code) of the main block, whatever the local
; layout. The key left of Y (ISO key) is a backslash on US, so it's sent as F21 instead, which
; iKVM maps to that position.
UsKeyAtPosition := Map(
    0x02, 0x31, 0x03, 0x32, 0x04, 0x33, 0x05, 0x34, 0x06, 0x35, 0x07, 0x36, 0x08, 0x37,
    0x09, 0x38, 0x0A, 0x39, 0x0B, 0x30, 0x0C, 0xBD, 0x0D, 0xBB,
    0x10, 0x51, 0x11, 0x57, 0x12, 0x45, 0x13, 0x52, 0x14, 0x54, 0x15, 0x59, 0x16, 0x55,
    0x17, 0x49, 0x18, 0x4F, 0x19, 0x50, 0x1A, 0xDB, 0x1B, 0xDD,
    0x1E, 0x41, 0x1F, 0x53, 0x20, 0x44, 0x21, 0x46, 0x22, 0x47, 0x23, 0x48, 0x24, 0x4A,
    0x25, 0x4B, 0x26, 0x4C, 0x27, 0xBA, 0x28, 0xDE, 0x29, 0xC0, 0x2B, 0xDC,
    0x2C, 0x5A, 0x2D, 0x58, 0x2E, 0x43, 0x2F, 0x56, 0x30, 0x42, 0x31, 0x4E, 0x32, 0x4D,
    0x33, 0xBC, 0x34, 0xBE, 0x35, 0xBF, 0x56, 0x84
)

; iKVM/HTML5 without the userscript: US character at each key position (scan code), see
; HtmlFallbackKey
UsCharAtPosition := Map(
    0x02, "1", 0x03, "2", 0x04, "3", 0x05, "4", 0x06, "5", 0x07, "6", 0x08, "7", 0x09, "8",
    0x0A, "9", 0x0B, "0", 0x0C, "-", 0x0D, "=",
    0x10, "q", 0x11, "w", 0x12, "e", 0x13, "r", 0x14, "t", 0x15, "y", 0x16, "u", 0x17, "i",
    0x18, "o", 0x19, "p", 0x1A, "[", 0x1B, "]",
    0x1E, "a", 0x1F, "s", 0x20, "d", 0x21, "f", 0x22, "g", 0x23, "h", 0x24, "j", 0x25, "k",
    0x26, "l", 0x27, ";", 0x28, "'", 0x29, "``", 0x2B, "\",
    0x2C, "z", 0x2D, "x", 0x2E, "c", 0x2F, "v", 0x30, "b", 0x31, "n", 0x32, "m", 0x33, ",",
    0x34, ".", 0x35, "/"
)

; Keys typing a character on the remote: the character's key on the remote's layout (see
; RemoteLayout and CharKeyTable), sent as
;   iKVM Java: the US key code of that position
;   iKVM/HTML5 (without the userscript): the US character of that position (see
;   HtmlFallbackKey), no AltGr
; "" if it can't be typed that way (alt code instead): not on the keyboard, dead keys, and on
; the Swiss layouts ¦ (AltGr+1 on Windows, but | on Linux) and the dead keys' characters.
PositionalKeysForChar(Char, Hkl) {
    if (Char = "`n")
        return "{Enter}"
    if (InStr("´``^~¨¦", Char) and IsSwissLayout(Hkl))
        return ""
    Table := CharKeyTable(Hkl)
    if (!Table.Has(Char))
        return ""
    Key := Table[Char]
    if (IsJavaPlain()) {
        Vk := UsKeyAtPosition.Has(Key.Sc) ? UsKeyAtPosition[Key.Sc]
            : DllCall("MapVirtualKeyExW", "UInt", Key.Sc, "UInt", 1, "Ptr", Hkl, "UInt")   ; Tab, Space
        Keys := "{vk" Format("{:02X}", Vk) "}"
    } else {
        if ((Key.Mods & 2) or Key.Sc = 0x56)
            return ""
        Keys := UsCharAtPosition.Has(Key.Sc) ? "{U+" Format("{:04X}", Ord(UsCharAtPosition[Key.Sc])) "}"
            : "{sc" Format("{:03X}", Key.Sc) "}"        ; Tab, Space
    }
    if (Key.Mods & 2)
        Keys := "{RAlt down}{LCtrl up}" Keys "{RAlt up}"   ; AltGr without its extra Ctrl (see *LCtrl)
    if (Key.Mods & 1)
        Keys := "{Shift down}" Keys "{Shift up}"
    return Keys
}

; Character -> key (scan code, modifiers: 1 Shift, 2 AltGr) on a layout, for every key of the
; main block, Tab and Space. With several keys for a character, the one with the fewest
; modifiers wins (Windows' own VkKeyScan prefers e.g. AltGr+5 over the § key, AltGr+5 is ½ on
; a Linux remote).
CharKeyTable(Hkl) {
    static Tables := Map()
    if (Tables.Has(Hkl))
        return Tables[Hkl]
    Table := Map()
    Table.CaseSense := true
    State := Buffer(256, 0)
    Out := Buffer(16, 0)
    for Mods in [0, 1, 2, 3] {
        NumPut("UChar", (Mods & 1) ? 0x80 : 0, State, 0x10)                  ; VK_SHIFT
        NumPut("UChar", (Mods & 2) ? 0x80 : 0, State, 0x11)                  ; VK_CONTROL
        NumPut("UChar", (Mods & 2) ? 0x80 : 0, State, 0x12)                  ; VK_MENU
        for Range in [[0x02, 0x0D], [0x0F, 0x1B], [0x1E, 0x29], [0x2B, 0x35], [0x39, 0x39], [0x56, 0x56]] {
            loop Range[2] - Range[1] + 1 {
                Sc := Range[1] + A_Index - 1
                Vk := DllCall("MapVirtualKeyExW", "UInt", Sc, "UInt", 1, "Ptr", Hkl, "UInt")
                ; flag 4: don't change the keyboard state (dead keys)
                Count := DllCall("ToUnicodeEx", "UInt", Vk, "UInt", Sc, "Ptr", State, "Ptr", Out
                    , "Int", 8, "UInt", 4, "Ptr", Hkl, "Int")
                if (Count != 1)
                    continue
                Char := Chr(NumGet(Out, 0, "UShort"))
                if (!Table.Has(Char))
                    Table[Char] := {Sc: Sc, Mods: Mods}
            }
        }
    }
    Tables[Hkl] := Table
    return Table
}

; Split text into characters, keeping UTF-16 surrogate pairs (emoji etc.) together,
; so they are sent as one code point instead of two invalid halves
SplitChars(Text) {
    Chars := []
    Loop Parse Text {
        Unit := Ord(A_LoopField)
        if (Unit >= 0xDC00 and Unit <= 0xDFFF and Chars.Length > 0 and StrLen(Chars[-1]) = 1) {
            Previous := Ord(Chars[-1])
            if (Previous >= 0xD800 and Previous <= 0xDBFF) {
                Chars[-1] .= A_LoopField
                continue
            }
        }
        Chars.Push(A_LoopField)
    }
    return Chars
}

; CRLF and lone CR -> LF, which Send turns into a single [enter] keystroke
NormalizeLineBreaks(Text) {
    return StrReplace(StrReplace(Text, "`r`n", "`n"), "`r", "`n")
}

; The paste hotkey only blocks its key: its modifiers went down on the remote already. Released
; with nothing in between, the remote sees them alone (Alt+Shift: Windows switches the input
; language; Alt: menu bars, in the browser too; Win: Start menu). A Ctrl tap while they're
; still held breaks them up, so none of them fires.
BreakModifiers() {
    SendKeys("{Blind}{LCtrl}")
}

; Wait until the paste hotkey is physically released, so the held modifiers don't get
; mixed into the sent keystrokes (e.g. Shift+Numpad = arrow keys), then give the laggy
; iKVM a moment to forward the key-ups to the remote.
WaitForHotkeyRelease() {
    for Modifier in HotkeyModifiers
        if (InStr(PasteMods, Modifier.Symbol))
            for Key in Modifier.Keys
                KeyWait Key
    KeyWait PasteKey
    Sleep 100
}

; Message box with its own button labels. Returns the label clicked, "" if closed (Esc, X).
; OsSelector: adds a Remote OS choice (same setting as in the tray menu, changed right away).
; CheckboxText: adds a checkbox, its state when a button was clicked goes to Checked.
AskUser(Title, Text, Labels, DefaultButton := 1, OsSelector := false, CheckboxText := "", &Checked := false) {
    Result := ""
    Box := 0
    BoxState := false
    Dlg := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", Title)
    Dlg.SetFont("s9", "Segoe UI")
    Dlg.MarginX := 16
    Dlg.MarginY := 14
    Dlg.Add("Text", "w440", Text)
    if (OsSelector) {
        Dlg.Add("Text", "xm y+10", "Remote OS:")
        Dlg.Add("Radio", "x+10 yp Group" (RemoteWindows ? "" : " Checked"), "Linux console")
            .OnEvent("Click", (*) => SetRemoteWindows(false))
        Dlg.Add("Radio", "x+10 yp" (RemoteWindows ? " Checked" : ""), "Windows")
            .OnEvent("Click", (*) => SetRemoteWindows(true))
    }
    if (CheckboxText != "")
        Box := Dlg.Add("Checkbox", "xm y+12", CheckboxText)
    for Index, Label in Labels {
        Btn := Dlg.Add("Button", (Index = 1 ? "xm y+18" : "x+8 yp") (Index = DefaultButton ? " Default" : ""), Label)
        Btn.OnEvent("Click", ((Clicked, *) => (Result := Clicked, BoxState := Box ? Box.Value : false, Dlg.Destroy())).Bind(Label))
    }
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())
    Dlg.OnEvent("Escape", (*) => Dlg.Destroy())
    Hwnd := Dlg.Hwnd
    Dlg.Show()
    WinWaitClose("ahk_id " Hwnd)
    Checked := BoxState
    return Result
}

; Paste the clipboard into an iKVM window: every character on the keyboard as its keys (see
; PositionalKeysForChar), the rest as alt codes. AltCodesOnly: everything as alt codes except
; line breaks, Tab and Space, which is slow, but works with any layout on the remote. Every
; line break (Windows CRLF, Unix LF, old Mac CR) is sent as one [enter] keystroke: the remote
; turns that into its own line break.
SendClipboard(AltCodesOnly := false, SendNonAscii := "") {
    if (SendNonAscii = "")
        SendNonAscii := PasteNonAscii
    OriginalWinID := WinExist("A")
    Layout := LayoutFor(BmcOfTitle(ActiveTitle()))
    if (Layout.Setting = "other")           ; tray menu: always safe paste
        AltCodesOnly := true
    Hkl := AltCodesOnly ? 0 : RemoteLayout(Layout.Setting)

    ControlChars := 0
    CodepageChars := 0
    UnicodeChars := 0

    Chars := SplitChars(NormalizeLineBreaks(A_Clipboard))
    Keys := []
    for Char in Chars {
        CharCode := Ord(Char)
        Keys.Push(!AltCodesOnly ? PositionalKeysForChar(Char, Hkl)
            : Map("`n", "{Enter}", "`t", "{Tab}", " ", "{Space}").Get(Char, ""))
        if (Keys[-1] != "")
            continue
        if (CharCode < 32 or CharCode = 127)
            ControlChars++
        else if ((CharCode >= 128 and CharCode <= 255) or (RemoteWindows and Cp1252Extra.Has(CharCode)))
            CodepageChars++
        else if (CharCode > 255)
            UnicodeChars++
    }

    ; One dialog for everything worth asking about:
    ;  - Fast paste assumes the remote uses RemoteLayoutSetting. With another one the text arrives
    ;    garbled, which is harmless, except for line breaks (Enter: a garbled command would run)
    ;    and AltGr characters (right Alt there: they would trigger shortcuts).
    ;  - Characters that aren't on the keyboard are sent as alt codes: slow, and whether they
    ;    work depends on the remote (only if PasteNonAscii is "ask")
    LineBreaks := 0
    AltGrChars := 0
    if (!AltCodesOnly) {
        for Index, Char in Chars {
            if (Char = "`n")
                LineBreaks++
            else if (InStr(Keys[Index], "{RAlt down}"))
                AltGrChars++
        }
    }
    ;    Not asked once the layout was said (tray menu or RemoteLayoutSetting).
    AskLayout := (LineBreaks or AltGrChars) and !Layout.Chosen
    AskSlow := SendNonAscii = "ask" and (ControlChars + CodepageChars + UnicodeChars) > 0
    if (AskLayout or AskSlow) {
        MsgText := ""
        if (AskLayout)
            MsgText .= "• Includes line breaks or AltGr characters (@ # | { } …): if the remote system doesn't use the "
                . RemoteLayouts[Layout.Setting].Name " layout, garbled commands could run. Safe paste works with"
                . " any layout, but is slower. (Tray menu, Remote layout: say this BMC's, and this isn't asked again.)`n`n"
        if (AskSlow) {
            SlowChars := ControlChars + CodepageChars + UnicodeChars
            MsgText .= "• " SlowChars " character" (SlowChars > 1 ? "s" : "") " not on the keyboard:"
                . " typed slowly as Alt + number."
            ; only some depend on the Remote OS setting (see AltCodeDigits): the Windows-1252
            ; specials 128-159 (€ „ – …) and everything beyond Latin-1 (Linux console only)
            Cp1252Chars := 0
            BeyondChars := 0
            for Index, Char in Chars {
                if (Keys[Index] != "" or Ord(Char) <= 255)
                    continue
                if (Cp1252Extra.Has(Ord(Char)))
                    Cp1252Chars++
                else
                    BeyondChars++
            }
            if (ControlChars)
                MsgText .= " Includes control characters!"
            if (Cp1252Chars + BeyondChars)
                MsgText .= "`n`n• " (Cp1252Chars + BeyondChars) " of them depend on the remote's OS, choose it"
                    . " below" (BeyondChars ? " (" BeyondChars " of them likely don't work on Windows at all)." : ".")
        }
        Buttons := AskLayout ? ["Fast paste", "Safe paste", "Cancel"] : ["Paste", "Cancel"]
        Result := AskUser("iKVM clipboard autotype", RTrim(MsgText, "`n"), Buttons, ControlChars ? Buttons.Length : 1
            , AskSlow and (Cp1252Chars + BeyondChars) > 0)
        ; This dialog window often causes switching of the active window. Change back.
        try {
            WinActivate("ahk_id " OriginalWinID)
            WinWaitActive("ahk_id " OriginalWinID, , 1)
        }
        switch Result {
            case "Paste", "Fast paste":
                SendNonAscii := SendNonAscii = "ask" ? true : SendNonAscii
            case "Safe paste":
                return SendClipboard(true, SendNonAscii = "ask" ? true : SendNonAscii)
            default:            return
        }
    }

    ; Safe paste runs with CapsLock on: AHK would turn it off and on again around every single
    ; Send (= 2 CapsLock keystrokes per character forwarded to the remote). Alt codes don't
    ; care about CapsLock, so leave it on. (Fast paste only runs with CapsLock off.)
    SetStoreCapsLockMode false

    ; Windows sleeps in ~15.6 ms steps by default: 1 ms timer resolution while pasting, so short
    ; key delays are as short as configured
    DllCall("winmm\timeBeginPeriod", "UInt", 1)

    ; Character by character: stops as soon as the iKVM window isn't active anymore (switched
    ; windows while pasting, the rest would land there) or Esc is pressed
    IsHtml := IsHtmlKvm()
    try {
        for Index, Char in Chars {
            CharCode := Ord(Char)
            Native := Keys[Index] != ""
            ; "Always omit" (tray menu): keep native chars and printable ASCII only
            if (not SendNonAscii and not Native and not (CharCode >= 32 and CharCode <= 126))
                continue
            if (!WinActive("ahk_id " OriginalWinID) or GetKeyState("Esc", "P"))
                return
            if (Native)
                SendKeys(Keys[Index])
            else
                SendAltCode(CharCode)
            ; iKVM/HTML5: pace it, about as many keystrokes as sent (alt codes: Alt + digits)
            if (IsHtml)
                Sleep HtmlKeyDelay * (Native ? 1 : StrLen(AltCodeDigits(CharCode)) + 1)
        }
    }
    finally
        DllCall("winmm\timeEndPeriod", "UInt", 1)
}

; Paste hotkey (PasteHotkey, Alt+Shift+V by default). With CapsLock on: safe paste, everything
; as alt codes (slower, any remote layout). Not where the Java agent or the userscript is active
; (title ends with " ⌨"): they paste themselves. In iKVM windows the key handlers take every
; key by position before this hotkey sees it, so they check for it themselves (see IsPasteKey).
PasteIntoKvm(*) {
    global JavaPasting, JavaPasteSc
    BreakModifiers()
    WaitForHotkeyRelease()
    JavaPasteSc := 0        ; released by now (also if that happened outside the iKVM window)
    JavaPasting := IsJavaPlain()
    try SendClipboard(GetKeyState("CapsLock", "T"))
    finally JavaPasting := false
}

; for all other programs, fall back to sending text-only clipboard with no smartassery
; ({Raw} would turn CRLF into two [enter] keystrokes)
PasteIntoOtherApp(*) {
    WaitForHotkeyRelease()
    SendInput "{Raw}" NormalizeLineBreaks(A_Clipboard)
}

HotIf((*) => IsJavaPlain() or (IsHtmlKvm() and !IsHtmlPositional()))
Hotkey(PasteHotkey, PasteIntoKvm)
HotIf((*) => PasteInOtherApps and not IsJavaKvm() and not IsHtmlKvm())
Hotkey(PasteHotkey, PasteIntoOtherApp)
HotIf()

; A paste key in the main block also has the scan code hotkeys of the iKVM key handlers (Java,
; HTML5 without the userscript), and AutoHotkey always takes a key's scan code hotkey over its
; letter hotkey, even where that one's #HotIf is false: the letter hotkey above then never fires.
; So it's caught by scan code here too, for other programs; the handlers check for it themselves
; (see IsPasteKey). iKVM windows with the Java agent or the userscript paste themselves: left alone.
PasteKeyHere(HotkeyName) {
    if (IsJavaKvm() or IsHtmlKvm() or !PasteInOtherApps)
        return false
    return IsPasteKey(Integer("0x" SubStr(HotkeyName, -3)))
}

HotIf(PasteKeyHere)
for PasteSc in UsKeyAtPosition
    Hotkey("*SC" Format("{:03X}", PasteSc), PasteIntoOtherApp)
HotIf()

; Ctrl+Alt+End (left Alt): Ctrl+Alt+Del on the remote, as in Remote Desktop, after asking (a
; Linux console reboots right away; ConfirmCtrlAltDel, or off for 4 hours from the dialog).
; Windows keeps the real Ctrl+Alt+Del to itself, and even a sent Delete makes it one while Ctrl
; and Alt are held: so Ctrl and Alt are sent, but the Delete is posted to the viewer window's
; focused control as a message (as Alt+Tab). Left Alt only: AltGr is Ctrl + right Alt, so
; AltGr+End must not count.
#HotIf IsJavaKvm() or IsHtmlKvm()
^<!End:: {
    global CtrlAltDelQuietUntil
    SendPendingCtrl()
    WinID := WinExist("A")
    Java := IsJavaPlain()
    ; everything released first (the remote gets Ctrl and Alt back up), then ask
    KeyWait "End"
    KeyWait "Ctrl"
    KeyWait "Alt"
    if (ConfirmCtrlAltDel and !(CtrlAltDelQuietUntil != "" and A_Now < CtrlAltDelQuietUntil)) {
        Quiet := false
        if (AskUser("iKVM-KeyPasta", "Send Ctrl+Alt+Del to the remote?`n`n"
                . "On a Linux console, this reboots the server right away.", ["Send Ctrl+Alt+Del", "Cancel"], 2
                , , "Don't ask again for 4 hours", &Quiet) != "Send Ctrl+Alt+Del") {
            try WinActivate("ahk_id " WinID)
            return
        }
        if (Quiet)
            CtrlAltDelQuietUntil := DateAdd(A_Now, 4, "Hours")
    }
    try {
        WinActivate("ahk_id " WinID)
        WinWaitActive("ahk_id " WinID, , 1)
    }
    if (!WinActive("ahk_id " WinID))
        return
    Sleep 100
    Target := FocusedWindow(WinID)
    Params := 0x21000001 | (0x53 << 16)     ; repeat count 1, scan code of Delete, extended, Alt held
    ; left Ctrl followed by the F24 release in the Java app (see *LCtrl). The sleeps let the viewer
    ; take Ctrl and Alt first: a posted message would overtake keys still waiting in its queue.
    SendKeys("{LCtrl down}" (Java ? "{vk87 up}" : "") "{LAlt down}")
    Sleep 50
    try {
        PostMessage 0x100, 0x2E, Params, , "ahk_id " Target                 ; WM_KEYDOWN, VK_DELETE
        Sleep 50
        PostMessage 0x101, 0x2E, Params | 0xC0000000, , "ahk_id " Target    ; WM_KEYUP
        Log("  Ctrl+Alt+Del posted to " Target)
    }
    Sleep 50
    SendKeys("{LAlt up}{LCtrl up}")
}
#HotIf

; The key with this scan code, with the modifiers held now, is the paste hotkey: its letter
; on the local layout (like Ctrl+V, wherever the layout has it) and exactly its modifiers
IsPasteKey(Sc) {
    if (DllCall("MapVirtualKeyExW", "UInt", Sc, "UInt", 1, "Ptr", WindowLayout(WinExist("A")), "UInt") != PasteKeyVk)
        return false
    for Modifier in HotkeyModifiers {
        Held := false
        for Key in Modifier.Keys
            Held := Held or GetKeyState(Key)
        if (Held != !!InStr(PasteMods, Modifier.Symbol))
            return false
    }
    return true
}


; AltGr = left Ctrl (added by Windows right before) + right Alt. Every left Ctrl press is held
; back briefly: if right Alt follows, it was AltGr's and is dropped. Otherwise it's sent on,
; right away if another key goes down meanwhile (see SendPendingCtrl). Key repeat repeats both,
; dropped the same way.
;   iKVM Java: the remote gets right Alt only (= its AltGr). In iKVM's "stable" keyboard mode
;   (option "Repeat Key timeout"), a pressed key is held back until the next key goes down or
;   the timeout passes, except left Ctrl: the next key going down drops it. Shortcuts typed at
;   normal speed would lose their Ctrl. But a key RELEASE sends the held back key, left Ctrl
;   included: so left Ctrl is followed by the release of F24 (never pressed: no effect on Linux
;   or Windows remotes).
;   iKVM/HTML5 without the userscript: AltGr isn't passed on at all (see HtmlFallbackKey)
; Off while pasting into iKVM Java: the paste sends AltGr itself and releases that Ctrl.
#HotIf (IsJavaPlain() and !JavaPasting) or (IsHtmlKvm() and !IsHtmlPositional())
*LCtrl:: {
    global CtrlPending
    ; real Ctrl held down, key repeat (unless it was released in another window meanwhile)
    if (CtrlSent and GetKeyState("LCtrl"))
        return
    CtrlPending := true
    Sleep 10
    SendPendingCtrl()
}

; Send the held back left Ctrl now, unless right Alt came (AltGr's Ctrl: dropped). Also called by
; the key handlers (iKVM Java, iKVM/HTML5 without the userscript) when a key goes down, so a
; fast Ctrl+C gets its Ctrl before the C.
SendPendingCtrl() {
    global CtrlPending, CtrlSent
    if (!CtrlPending)
        return
    CtrlPending := false
    if (GetKeyState("RAlt") or GetKeyState("RAlt", "P"))
        return
    CtrlSent := true
    SendEvent "{Blind}{LCtrl DownR}" (IsJavaPlain() ? "{vk87 up}" : "")
}

; also in any other window when released there (switched windows while holding it): no stuck Ctrl
#HotIf CtrlSent or (IsJavaPlain() and !JavaPasting) or (IsHtmlKvm() and !IsHtmlPositional())
*LCtrl up:: {
    global CtrlSent, CtrlPending
    ; tapped quicker than the hold back: never sent, so nothing to release
    if (CtrlPending) {
        CtrlPending := false
        return
    }
    ; not sent by *LCtrl (AltGr's, or pressed in another window): pass the release on if Windows
    ; still has it down, as this hotkey blocks it
    if (!CtrlSent and !GetKeyState("LCtrl"))
        return
    CtrlSent := false
    SendEvent "{Blind}{LCtrl up}"
}


; iKVM Java app: every key of the main block sent by its position (see TellJava and
; UsKeyAtPosition), whatever the local layout, so the remote's layout decides what it types,
; like with a keyboard attached to it: dead keys, shortcuts and all modifiers included.
; Like a remap (a::b), but for all keys from the table, and checking for the paste hotkey.
; The paste hotkey's key (JavaPasteSc) isn't passed on while it's held, its release neither.
JavaKey(Sc, Vk, Down, *) {
    global JavaPasteSc
    if (Down)
        SendPendingCtrl()
    if (Down and IsPasteKey(Sc)) {
        JavaPasteSc := Sc
        return PasteIntoKvm()
    }
    if (!Down and Sc = JavaPasteSc) {
        JavaPasteSc := 0
        return
    }
    SetKeyDelay -1
    SendEvent "{Blind}{vk" Format("{:02X}", Vk) (Down ? " DownR}" : " up}")
}

HotIf((*) => IsJavaPlain())
for JavaKeySc, JavaKeyVk in UsKeyAtPosition {
    Hotkey("*SC" Format("{:03X}", JavaKeySc), JavaKey.Bind(JavaKeySc, JavaKeyVk, true))
    Hotkey("*SC" Format("{:03X}", JavaKeySc) " up", JavaKey.Bind(JavaKeySc, JavaKeyVk, false))
}
HotIf()

#HotIf IsJavaPlain()

; Lock keys only reach the remote as one quick tap: in iKVM's "stable" keyboard mode (option
; "Repeat Key timeout"), a key released within the timeout is sent as one press+release message,
; a key held longer as separate press and release, which the remote ignores for lock keys. So
; every CapsLock press is sent as a short tap (JavaKeyPressDuration), key repeat ignored. Toggles
; locally too. (NumLock sent like that doesn't reach the Java app at all: left alone.)
*CapsLock:: {
    SendEvent "{Blind}{CapsLock}"
    KeyWait "CapsLock"
}

#HotIf IsJavaKvm()

; Alt+Tab (and Alt+Shift+Tab) to the remote instead of the local task switcher. Windows starts
; its switcher for every Alt+Tab, even a sent one, so the Tab is posted to the Java window's
; focused control as a message instead. To switch away locally: Win+Tab or the mouse.
*!Tab:: {
    Target := FocusedWindow(WinExist("A"))
    Params := 0x20000001 | (0x0F << 16)     ; repeat count 1, scan code of Tab, Alt held
    try {
        PostMessage 0x104, 0x09, Params, , "ahk_id " Target                 ; WM_SYSKEYDOWN, VK_TAB
        KeyWait "Tab"
        PostMessage 0x105, 0x09, Params | 0xC0000000, , "ahk_id " Target    ; WM_SYSKEYUP
        Log("  Alt+Tab posted to " Target)
    }
}

#HotIf


; iKVM/HTML5 browser viewer without the userscript (see IsHtmlPositional). The viewer turns the
; typed CHARACTER into the US key position of that character, and sends Shift, Ctrl, left Alt and
; Win, but never AltGr. So each key sends the character US has at its position, with the
; modifiers held: the remote gets the right position, dead keys included. What can't work that way:
;   AltGr: the remote never gets it. The character this key has with AltGr on a Swiss keyboard
;          is sent as an alt code instead (no dead keys, no shortcuts with AltGr).
;   ISO key (left of Y): no character maps to its position, < > \ are sent as alt codes.
;   Shortcuts (Ctrl, left Alt, Win): the viewer takes the key code then, not the character,
;          which works for letters and digits (z/y swapped to their US key codes).
; Numpad keys send their own characters, the decimal key arrives as the main full stop.

; Swiss keyboard with AltGr (sent as alt codes, dead keys as their plain character)
SwissAltGr := Map(
    0x02, "¦", 0x03, "@", 0x04, "#", 0x05, "°", 0x06, "§", 0x07, "¬", 0x08, "|", 0x09, "¢",
    0x0C, "´", 0x0D, "~", 0x12, "€", 0x1A, "[", 0x1B, "]", 0x28, "{", 0x2B, "}", 0x56, "\"
)

HtmlFallbackKey(Sc, *) {
    SendPendingCtrl()
    if (IsPasteKey(Sc))
        return PasteIntoKvm()
    if (GetKeyState("RAlt", "P")) {             ; AltGr (held back from the viewer, see below)
        if (SwissAltGr.Has(Sc))
            SendAltCode(Ord(SwissAltGr[Sc]))
        return
    }
    if (Sc = 0x56) {                            ; ISO key
        SendAltCode(Ord(GetKeyState("Shift") ? ">" : "<"))
        return
    }
    if (GetKeyState("Ctrl") or GetKeyState("LAlt") or GetKeyState("LWin") or GetKeyState("RWin")) {
        ; shortcut: the viewer uses the key code. z/y: the US letter of the position
        SendInput "{Blind}" (Sc = 0x15 ? "{vk59}" : Sc = 0x2C ? "{vk5A}" : "{sc" Format("{:03X}", Sc) "}")
        return
    }
    SendInput "{Blind}{U+" Format("{:04X}", Ord(UsCharAtPosition[Sc])) "}"
}

; Every key of the main block
HotIf((*) => IsHtmlKvm() and !IsHtmlPositional())
for HtmlKeySc in UsCharAtPosition
    Hotkey("*SC" Format("{:03X}", HtmlKeySc), HtmlFallbackKey.Bind(HtmlKeySc))
Hotkey("*SC056", HtmlFallbackKey.Bind(0x56))
; AltGr isn't passed on: the viewer would send left Ctrl and left Alt for it
Hotkey("*RAlt", (*) => 0)
Hotkey("*RAlt up", (*) => GetKeyState("RAlt") ? SendEvent("{Blind}{RAlt up}") : 0)    ; pressed elsewhere
HotIf()


; Tray menu, rebuilt on every change. Each setting shows its current value in its own line,
; the submenu behind it lists the choices with the active one marked:
;   Remote layout: Swiss German       > (•) Swiss German              (per BMC, see LayoutFor)
;                                       ( ) Swiss French
;                                       ( ) German
;                                       ( ) United States
;                                       ( ) Other (always safe paste)
;   Remote OS: Linux console          > (•) Linux console
;                                       ( ) Windows
;   Non-ASCII characters: Ask         > (•) Ask on every paste
;                                       ( ) Always include
;                                       ( ) Always omit
;   Alt+Shift+V pastes in: Any window > (•) Any window              (PasteHotkey)
;                                       ( ) iKVM windows only
;   ---
;   Suspend hotkeys
;   Exit
BuildTrayMenu() {
    OtherLayout := "Other (always safe paste)"
    Layout := LayoutFor(CurrentBmc)
    LayoutLabel := Layout.Setting = "other" ? OtherLayout : RemoteLayouts[Layout.Setting].Name
    LayoutMenu := Menu()
    for LayoutCode in RemoteLayoutOrder
        LayoutMenu.Add(RemoteLayouts[LayoutCode].Name, ((Setting, *) => SetRemoteLayout(Setting)).Bind(LayoutCode), "Radio")
    LayoutMenu.Add(OtherLayout, (*) => SetRemoteLayout("other"), "Radio")
    LayoutMenu.Check(LayoutLabel)

    RemoteLabel := RemoteWindows ? "Windows" : "Linux console"
    RemoteMenu := Menu()
    RemoteMenu.Add("Linux console", (*) => SetRemoteWindows(false), "Radio")
    RemoteMenu.Add("Windows", (*) => SetRemoteWindows(true), "Radio")
    RemoteMenu.Check(RemoteLabel)

    NonAsciiLabel := (PasteNonAscii = "ask") ? "Ask on every paste"
        : PasteNonAscii ? "Always include" : "Always omit"
    NonAsciiMenu := Menu()
    NonAsciiMenu.Add("Ask on every paste", (*) => SetPasteNonAscii("ask"), "Radio")
    NonAsciiMenu.Add("Always include", (*) => SetPasteNonAscii(true), "Radio")
    NonAsciiMenu.Add("Always omit", (*) => SetPasteNonAscii(false), "Radio")
    NonAsciiMenu.Check(NonAsciiLabel)

    PasteWhereLabel := PasteInOtherApps ? "Any window" : "iKVM windows only"
    PasteWhereMenu := Menu()
    PasteWhereMenu.Add("Any window", (*) => SetPasteInOtherApps(true), "Radio")
    PasteWhereMenu.Add("iKVM windows only", (*) => SetPasteInOtherApps(false), "Radio")
    PasteWhereMenu.Check(PasteWhereLabel)

    Tray := A_TrayMenu
    Tray.Delete()
    if (ElevationFailed and !A_IsAdmin and !HasUIAccess()) {
        Tray.Add("No UI Access or admin rights: iKVM Java window unreachable (click to try again)", RetryPrivileged)
        Tray.Add()
    }
    Tray.Add("Remote layout" (CurrentBmc != "" ? " of " CurrentBmc : "") ": " LayoutLabel, LayoutMenu)
    Tray.Add("Remote OS: " RemoteLabel, RemoteMenu)
    Tray.Add("Non-ASCII characters: " NonAsciiLabel, NonAsciiMenu)
    Tray.Add(PasteHotkeyText " pastes in: " PasteWhereLabel, PasteWhereMenu)
    Tray.Add()
    Tray.Add(A_IsSuspended ? "Resume hotkeys" : "Suspend hotkeys", PauseResume)
    Tray.Add("Exit", (*) => ExitApp())
    if (DebugMode) {
        Tray.Add()
        Tray.Add("Debug: Key history", (*) => KeyHistory())
        Tray.Add("Debug: Executed lines", (*) => ListLines())
        Tray.Add("Debug: iKVM Java log", ShowLog)
    }

    ; at most 127 characters, the rest is cut off
    A_IconTip := (A_IsSuspended ? "SUSPENDED`n" : "")
        . PasteHotkeyText ": paste clipboard`n"
        . "With CapsLock on: safe paste`n"
        . "Remote: " (Layout.Setting = "other" ? "any layout" : LayoutLabel) ", " RemoteLabel "`n"
        . "Non-ASCII: " NonAsciiLabel
}

; For the BMC of the last active iKVM Java window (kept in the agent's settings file), else the default
SetRemoteLayout(Value) {
    global RemoteLayoutSetting, RemoteLayoutChosen
    if (CurrentBmc != "") {
        try WriteAgentSetting("remoteLayout@" CurrentBmc, Value)
        catch as Err
            Log("  remote layout for " CurrentBmc " not saved: " Err.Message)
    } else {
        RemoteLayoutSetting := Value
        RemoteLayoutChosen := true
    }
    BuildTrayMenu()
}

;
; The agent's settings file: Java properties as the agent writes them (key=value, escapes with \,
; UTF-8). Read fresh every time, written whole through a temporary file renamed over it, like the
; agent does, so neither loses the other's settings.
;
ReadAgentSettings() {
    Settings := Map()
    try Text := FileRead(AgentSettingsFile, "UTF-8")
    catch
        return Settings
    Pending := ""
    loop parse Text, "`n", "`r" {
        Line := Pending LTrim(A_LoopField, " `t`f")
        Pending := ""
        First := SubStr(Line, 1, 1)
        if (Line = "" or First = "#" or First = "!")
            continue
        if (RegExMatch(Line, "(\\+)$", &Trail) and Mod(StrLen(Trail[1]), 2) = 1) {
            Pending := SubStr(Line, 1, -1)  ; continued on the next line
            continue
        }
        ; the key ends at the first =, : or blank that isn't escaped
        i := 1, n := StrLen(Line)
        while (i <= n) {
            c := SubStr(Line, i, 1)
            if (c == "\") {
                i += 2
                continue
            }
            if (c == "=" or c == ":" or c == " " or c == "`t" or c == "`f")
                break
            i++
        }
        Rest := LTrim(SubStr(Line, i), " `t`f")
        if (SubStr(Rest, 1, 1) == "=" or SubStr(Rest, 1, 1) == ":")
            Rest := LTrim(SubStr(Rest, 2), " `t`f")
        Settings[PropUnescape(SubStr(Line, 1, i - 1))] := PropUnescape(Rest)
    }
    return Settings
}

WriteAgentSetting(Key, Value) {
    SplitPath(AgentSettingsFile, , &Dir)
    DirCreate(Dir)
    Settings := ReadAgentSettings()
    Settings[Key] := Value
    Keys := ""
    for K in Settings
        Keys .= K "`n"
    Text := "# iKVM-KeyPasta agent settings (the viewer's Options > KeyPasta Preferences).`n"
        . "# setting=value: the default; setting@host=value: that host's own.`n"
    loop parse Sort(RTrim(Keys, "`n"), "C"), "`n"
        Text .= PropEscape(A_LoopField, true) "=" PropEscape(Settings[A_LoopField], false) "`n"
    Tmp := AgentSettingsFile ".ahk.tmp"
    try FileDelete(Tmp)
    FileAppend(Text, Tmp, "UTF-8-RAW")
    FileMove(Tmp, AgentSettingsFile, 1)
}

PropUnescape(S) {
    Out := "", i := 1, n := StrLen(S)
    while (i <= n) {
        c := SubStr(S, i, 1)
        if (c != "\" or i = n) {
            Out .= c, i++
            continue
        }
        d := SubStr(S, i + 1, 1)
        if (d == "u" and RegExMatch(SubStr(S, i + 2, 4), "^[0-9A-Fa-f]{4}$")) {
            Out .= Chr(Integer("0x" SubStr(S, i + 2, 4))), i += 6
            continue
        }
        Out .= d == "t" ? "`t" : d == "n" ? "`n" : d == "r" ? "`r" : d == "f" ? "`f" : d
        i += 2
    }
    return Out
}

PropEscape(S, IsKey) {
    Out := ""
    loop parse S {
        c := A_LoopField, o := Ord(c)
        if (InStr("\=:#!", c) or (IsKey and c == " ") or (A_Index = 1 and c == " "))
            Out .= "\" c
        else if (o < 0x20 or o > 0x7E)
            Out .= Format("\u{:04x}", o)
        else
            Out .= c
    }
    return Out
}

SetRemoteWindows(Value) {
    global RemoteWindows := Value
    BuildTrayMenu()
}

SetPasteNonAscii(Value) {
    global PasteNonAscii := Value
    BuildTrayMenu()
}

SetPasteInOtherApps(Value) {
    global PasteInOtherApps := Value
    BuildTrayMenu()
}

PauseResume(*) {
    Suspend -1  ; Toggle
    if (A_IsSuspended)
        UntellAllJava()
    else
        HandleActiveWindow(WinExist("A"))
    SetTrayIcon(A_IsSuspended)
    BuildTrayMenu()
}

; The icons are named after the taskbar mode they're made for (dark/light). Suspended: the
; same icon faded (light 50%, dark 40%, so both look equally off). Only set if it's a different
; one: the theme change message also comes for changes of the app mode, or several times for one.
SetTrayIcon(Suspended) {
    global TrayIconShown
    Mode := TaskbarIsLight() ? "light" : "dark"
    Icon := Mode (Suspended ? "-suspended" : "")
    if (Icon = TrayIconShown)
        return
    TrayIconShown := Icon
    ; (icon file missing: the default icon, no error box; braces: a try would take the else)
    if A_IsCompiled {
        try TraySetIcon(A_ScriptFullPath, -Map("dark", 159, "light", 300, "light-suspended", 301, "dark-suspended", 302)[Icon], true)
    } else {
        try TraySetIcon("PPCH_outlined_" Icon ".ico", , true)
    }
}

; Taskbar (system) in light mode? Missing before Windows 10 1903, which only had a dark taskbar.
TaskbarIsLight() {
    try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme")
    return false
}

SettingChanged(wParam, lParam, *) {
    if (lParam and StrGet(lParam) = "ImmersiveColorSet")
        SetTrayIcon(A_IsSuspended)
}
