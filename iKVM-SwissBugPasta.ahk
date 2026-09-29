; AHK Boilerplate
#Requires AutoHotkey v2.0
#Warn                       ; Enable warnings to assist with detecting common errors
#SingleInstance Force       ; Force: reload script if already running
Persistent                  ; Do not exit script when actions are finished
SetWorkingDir A_ScriptDir   ; Ensure a consistent starting directory
A_StringCaseSense := "On"  ; Default is case insensitive match and replace -> NOPE (note: StrReplace/InStr need their own CaseSense param in v2)
;SetTitleMatchMode "RegEx"  ; I wonder how many milliseconds this costs...
/*@Ahk2Exe-Keep
KeyHistory 0                ; Disable the key history (This script will mostly handle password)
ListLines False             ; Omit recently executed lines from history (Same again)
*/

; EXE informational properties
;@Ahk2Exe-SetProductName AutoHotKey
;@Ahk2Exe-SetLegalTrademarks AHK executable: autohotkey.com
;@Ahk2Exe-SetCopyright AHK script by Tabiskabis: CC BY 3.0
;@Ahk2Exe-SetDescription Swiss hotkeys for iKVM
;@Ahk2Exe-SetFileVersion 0.4.0.0

; If code signing is not feasible, comment this out to automatically request elevation when launched
;;@Ahk2Exe-UpdateManifest 1
if !A_IsCompiled && !InStr(A_AhkPath, "_UIA.exe")
{
    uiaPath := RegExReplace(A_AhkPath, "i)\.exe$", "_UIA.exe")
    if !FileExist(uiaPath)
    {
        MsgBox "You won't be able to send keystrokes to elevated windows.`nUI Access executable not found:`n" uiaPath
    }
    else
    {
    try
        Run '"' uiaPath '" /restart "' A_ScriptFullPath '"'
    catch as e
        MsgBox "Failed to start with UI Access:`n" e.Message
    ExitApp
    }
}

; Replace default tray menu & icons
A_IconTip := "Paste clipboard text contents with alt-shift-v"

; Images under creative commons License CC BY 3.0 CH by Pirate Party Switzerland
; https://www.piratenpartei.ch/logos-und-fotos/
;@Ahk2Exe-SetMainIcon PPCH_outlined_light.ico
;@Ahk2Exe-AddResource PPCH_outlined_dark.ico, 300
; In the exe the icons are addressed by resource ID (negative IconNumber), not by
; index: 159 = main icon (light), 300 = added icon (dark). Indexes shift depending on
; how many icon groups the base exe contains and how named resources are sorted.

A_TrayMenu.Delete()
A_TrayMenu.Add("Suspend HotKeys", PauseResume)
A_TrayMenu.Add("Exit", QuitScript)
SetTrayIcon(false)


; Individual Configuration (* is the suggested default)

PasteInOtherApps := true    ;  true: * activate shortcut for pasting clipboard to other programs, too
                            ; false:   use the hotkey for iVKM Java/HTML windows only

PasteNonAscii := "ask"      ;  true:   always send non ASCII characters
                            ; false:   omit non-ASCII in the sent characters
                            ; "ask": * prompt user what to do

ReplaceCRLFs := true        ;  true: * Replace CRLF with LF only and send as [enter] keystroke
                            ; false:   Send CR and LF characters separately using alt codes

HtmlAltCodeMode := "masked" ; How alt codes are sent to the iKVM/HTML5 browser viewer (see IsHtmlKvm):
                            ; "masked": * Alt+Numpad with a dummy key before Alt is released, so the browser
                            ;             does not also compose the character locally (avoids double chars)
                            ; "text":    send the character as Unicode text (only if the viewer forwards typed chars)
                            ; "plain":   old {ASC} behaviour, types most characters :(


; App specific characters that can be sent without using alt codes
NativeSpecialJava := "`t .,:;%&#`"/|¦\*(<=>)@+°§¬ç¢"
NativeSpecialHTML := "`t .,%" ; line breaks handled separately


; Helper functions

ConvertAndSend(TargetChar) {
    SendAltCode(Ord(TargetChar))
}

; Browsers forward the Alt+Numpad keystrokes to the HTML5 viewer (the remote composes the
; character) AND compose the same character locally when Alt is released, which the viewer
; forwards as well -> every alt-coded character arrives twice. Pressing an unassigned key
; (vkE8, the same "mask" key AHK itself uses) before Alt up cancels the local composition.
SendAltCode(CharCode) {
    global HtmlAltCodeMode
    if (!IsHtmlKvm() or HtmlAltCodeMode = "plain") {
        SendInput "{ASC " CharCode "}"
        return
    }
    if (HtmlAltCodeMode = "text") {
        SendText Chr(CharCode)
        return
    }
    Keys := "{LAlt down}"
    Loop Parse String(CharCode)
        Keys .= "{Numpad" A_LoopField "}"
    SendInput Keys "{vkE8}{LAlt up}"
}

CurrentLayout() {
    WinID := WinExist("A")
    ThreadID := DllCall("GetWindowThreadProcessId", "Ptr", WinID, "Ptr", 0, "UInt")
    InputLocaleID := DllCall("GetKeyboardLayout", "UInt", ThreadID, "Ptr")
    return (InputLocaleID >> 16) & 0xFFFF
}

; iKVM/HTML5 browser viewer, window title is either
;   "Resolution: 1024x768 FPS :30"  or  "Console Redirection - iKVM/HTML5"
; (usually followed by " — Mozilla Firefox" or similar)
IsHtmlKvm() {
    try
        Title := WinGetTitle("A")
    catch
        return false
    return RegExMatch(Title, "Resolution: *\d+ *x *\d+ +FPS *: *\d+")
        or InStr(Title, "Console Redirection - iKVM/HTML5", true)
}

IsNativeChar(NativeSpecial, TestChar, CharCode) {
    ; alphanumerics:    0-9                                    A-Z                                    a-z
    if ((CharCode >= 48 and CharCode <= 57) or (CharCode >= 65 and CharCode <= 90) or (CharCode >= 97 and CharCode <= 122))
        return true
    ; other "native" characters
    if (InStr(NativeSpecial, TestChar, true))
        return true
    return false
}

SendClipboard(NativeSpecial) {
    global ReplaceCRLFs, PasteNonAscii

    OriginalWinID := WinExist("A")

    ; reset global chars for each use
    SanitizeCRLFs := ReplaceCRLFs
    SendNonAscii := PasteNonAscii

    NativeChars := 0
    ControlChars := 0
    CodepageChars := 0
    UnicodeChars := 0

    ClipboardCache := A_Clipboard
    if (SanitizeCRLFs) {
        ClipboardCache := StrReplace(ClipboardCache, "`r`n", "`n")
        NativeSpecial := "`n" . NativeSpecial
    }
    ClipboardCache := StrReplace(ClipboardCache, "y", "Magic↔swap↔121", true)
    ClipboardCache := StrReplace(ClipboardCache, "Y", "Magic↔swap↔089", true)
    ClipboardCache := StrReplace(ClipboardCache, "z", "y", true)
    ClipboardCache := StrReplace(ClipboardCache, "Z", "Y", true)
    ClipboardCache := StrReplace(ClipboardCache, "Magic↔swap↔121", "z", true)
    ClipboardCache := StrReplace(ClipboardCache, "Magic↔swap↔089", "Z", true)

    Loop Parse ClipboardCache {
        CharCode := Ord(A_LoopField)
        if (CharCode = 10 or CharCode = 13) {
            if (SanitizeCRLFs)
                NativeChars++
            else
                ControlChars++
        }
        else if (IsNativeChar(NativeSpecial, A_LoopField, CharCode))
            NativeChars++
        ;                       do not count as control characters:    CR,               LF,              HT
        else if ((CharCode < 32 or CharCode = 127) and not (CharCode = 10 and CharCode = 13 and CharCode = 9))
            ControlChars++
        else if (CharCode > 126 and CharCode <= 255)
            CodepageChars++
        else if (CharCode > 255)
            UnicodeChars++
    }
    OnlyNatives := (NativeChars = StrLen(ClipboardCache)) ? true : false

    if (SendNonAscii = "ask" and (ControlChars + CodepageChars + UnicodeChars) > 0) {
        MsgOptions := 0x2023
        MsgTitle := "Potentially problematic characters in clipboard"

        MsgText := ""
        if (ControlChars > 0) {
            MsgText := MsgText . "ASCII control characters (this seems dangerous): " . ControlChars . "`n"
            MsgOptions += 0x100
        }
        if (CodepageChars > 0) {
            MsgText := MsgText . "Extended ASCII (works if remote uses same code page): " . CodepageChars . "`n"
        }
        if (UnicodeChars > 0) {
            MsgText := MsgText . "Unicode (can be sent to Linux only): " . UnicodeChars . "`n"
        }
        MsgText := MsgText . "`nPress Yes to include or No to omit these characters."
        Result := MsgBox(MsgText, MsgTitle, MsgOptions)
        if (Result = "Cancel")
            return
        SendNonAscii := (Result = "Yes")
        ; This dialog window often causes switching of the active window. Change back.
        try WinActivate("ahk_id " OriginalWinID)
    }

    ; Send a long string if possible
    if (OnlyNatives and SanitizeCRLFs) {
        ; SendInput is great when it comes to long strings
        SendInput "{Raw}" ClipboardCache
        return
    }

    ; Or send it all character for character if alt codes are required
    Loop Parse ClipboardCache {
        CharCode := Ord(A_LoopField)
        ; FIXME? Changed during v2 conversion: the v1 condition was
        ;   if ((CharCode >= 32 and CharCode <= 126) and not SendNonAscii)
        ; which skipped printable ASCII instead of non-ASCII when answering "No".
        ; Native chars (tab, LF) are kept so line breaks survive answering "No".
        ; Revert to the line above if manual testing shows the old logic was right.
        if (not SendNonAscii and not (CharCode >= 32 and CharCode <= 126) and not IsNativeChar(NativeSpecial, A_LoopField, CharCode))
            continue
        ; Abort sending if active window is changed
        if (WinExist("A") != OriginalWinID)
            return
        if (IsNativeChar(NativeSpecial, A_LoopField, CharCode))
            SendInput "{Raw}" A_LoopField
        else
            SendAltCode(CharCode)
    }
}


; Enable hotkey for sending clipboard

#HotIf WinActive("Java iKVM Viewer")
!+v:: {
    Sleep 250
    SendClipboard(NativeSpecialJava)
}

#HotIf IsHtmlKvm()
!+v:: {
    Sleep 250
    SendClipboard(NativeSpecialHTML)
}

; for all other programs, fall back to sending text-only clipboard with no smartassery
#HotIf PasteInOtherApps
!+v:: {
    Sleep 250
    SendInput "{Raw}" A_Clipboard
}


; Set of hotkeys for Asus iKVM Java app, when Swiss keyboard layout is active
#HotIf WinActive("Java iKVM Viewer") and (CurrentLayout() = 0x0807)

; Remap keys available on Swiss and US layout
*SC015::VK59 ; z
*SC02c::VK5a ; y
*SC029::VKdd ; §°
*SC00c::VKbd ; '?´

; Where keys are unmappable, send alt codes instead

SC00d::ConvertAndSend("^")
+SC00d::ConvertAndSend("``")
!^SC00d::ConvertAndSend("~")

+SC01a::ConvertAndSend("è")
!^SC01a::ConvertAndSend("[")

SC01b::ConvertAndSend("¨")
+SC01b::ConvertAndSend("!")
!^SC01b::ConvertAndSend("]")

+SC027::ConvertAndSend("é")

+SC028::ConvertAndSend("à")
!^SC028::ConvertAndSend("{")

SC02b::ConvertAndSend("$")
+SC02b::ConvertAndSend("£")
!^SC02b::ConvertAndSend("}")

SC035::ConvertAndSend("-")
+SC035::ConvertAndSend("_")


; Set of hotkeys for iKVM/HTML5 browser app, when Swiss keyboard layout is active
#HotIf IsHtmlKvm() and (CurrentLayout() = 0x0807)

; Only z/y are mappable
*VK5a::VK59
*VK59::VK5a

; Rest is alt codes

VKe2::ConvertAndSend("<")
+VKe2::ConvertAndSend(">")
!^VKe2::ConvertAndSend("\")

SC029::ConvertAndSend("§")
+SC029::ConvertAndSend("°")

+1::ConvertAndSend("+")
+2::ConvertAndSend(Chr(34))
+3::ConvertAndSend("*")
+4::ConvertAndSend("ç")
+5::ConvertAndSend("%")
+6::ConvertAndSend("&")
+7::ConvertAndSend("/")
+8::ConvertAndSend("(")
+9::ConvertAndSend(")")
+0::ConvertAndSend("=")

!^1::ConvertAndSend("¦")
!^2::ConvertAndSend("@")
!^3::ConvertAndSend("#")
!^4::ConvertAndSend("°")
!^5::ConvertAndSend("§")
!^6::ConvertAndSend("¬")
!^7::ConvertAndSend("|")
!^8::ConvertAndSend("¢")

SC00c::ConvertAndSend("'")
SC00d::ConvertAndSend("^")
SC01a::ConvertAndSend("ü")
SC01b::ConvertAndSend("¨")
SC027::ConvertAndSend("ö")
SC028::ConvertAndSend("ä")
SC02b::ConvertAndSend("$")
SC035::ConvertAndSend("-")

+SC00c::ConvertAndSend("?")
+SC00d::ConvertAndSend("``")
+SC01a::ConvertAndSend("è")
+SC01b::ConvertAndSend("!")
+SC027::ConvertAndSend("é")
+SC028::ConvertAndSend("à")
+SC02b::ConvertAndSend("£")
+SC033::ConvertAndSend(";")
+SC034::ConvertAndSend(":")
+SC035::ConvertAndSend("_")

!^SC00c::ConvertAndSend("´")
!^SC00d::ConvertAndSend("~")
!^SC01a::ConvertAndSend("[")
!^SC01b::ConvertAndSend("]")
!^SC028::ConvertAndSend("{")
!^SC02b::ConvertAndSend("}")

#HotIf


; Script control functions

PauseResume(ItemName, ItemPos, TrayMenu) {
    Suspend -1  ; Toggle
    if (A_IsSuspended)
        TrayMenu.Rename("Suspend HotKeys", "Resume HotKeys")
    else
        TrayMenu.Rename("Resume HotKeys", "Suspend HotKeys")
    SetTrayIcon(A_IsSuspended)
}

SetTrayIcon(Suspended) {
    if A_IsCompiled
        TraySetIcon(A_ScriptFullPath, Suspended ? -159 : -300, true)
    else
        TraySetIcon(Suspended ? "PPCH_outlined_light.ico" : "PPCH_outlined_dark.ico", , true)
}

QuitScript(*) {
    ExitApp
}
