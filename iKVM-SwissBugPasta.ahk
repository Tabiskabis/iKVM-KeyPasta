; AHK Boilerplate
SetWorkingDir %A_ScriptDir% ; Ensure a consistent starting directory
#Warn                       ; Enable warnings to assist with detecting common errors
#NoEnv                      ; Recommended for performance and compatibility with future AutoHotkey releases
#SingleInstance Force       ; Force: reload script if already running
#Persistent                 ; Do not exit script when actions are finished
StringCaseSense On          ; Default is case insensitive match and replace -> NOPE
;SetTitleMatchMode, regex    ; I wonder how many milliseconds this costs...
/*@Ahk2Exe-Keep
#KeyHistory 0               ; Disable the key history (This script will mostly handle password)
ListLines Off               ; Omit recently executed lines from history (Same again)
*/

; Replace default tray menu & icons
Menu, Tray, Tip, Paste clipboard text contents with alt-shift-v

; Images under creative commons License CC BY 3.0 CH by Pirate Party Switzerland
; https://www.piratenpartei.ch/logos-und-fotos/
;@Ahk2Exe-AddResource PPCH_outlined_dark.ico
;@Ahk2Exe-SetMainIcon PPCH_outlined_light.ico
/*@Ahk2Exe-Keep
	Menu, Tray, NoStandard
	Menu, Tray, Add, Suspend HotKeys, PauseResume
	Menu, Tray, Add, Exit, QuitScript
	Menu, Tray, Icon, %A_ScriptFullPath%, 6, 1
*/
;@Ahk2Exe-IgnoreBegin
	Menu, Tray, Icon, PPCH_outlined_dark.ico
;@Ahk2Exe-IgnoreEnd

; EXE informational properties
;@Ahk2Exe-SetProductName AutoHotKey
;@Ahk2Exe-SetLegalTrademarks AHK executable: autohotkey.com
;@Ahk2Exe-SetCopyright AHK script by Tabiskabis: CC BY 3.0
;@Ahk2Exe-SetDescription	Swiss hotkeys for iKVM
;@Ahk2Exe-SetFileVersion	0.3.4.0


; Individual Configuration (* is the suggested default)

PasteInOtherApps := true    ;  true: * activate shortcut for pasting clipboard to other programs, too
                            ; false:   use the hotkey for iVKM Java/HTML windows only

PasteNonAscii := "ask"      ;  true:   always send non ASCII characters
                            ; false:   omit non-ASCII in the sent characters
                            ; "ask": * prompt user what to do

ReplaceCRLFs := true        ;  true: * Replace CRLF with LF only and send as [enter] keystroke
                            ; false:   Send CR and LF characters separately using alt codes


; App specific characters that can be sent without using alt codes
NativeSpecialJava := "`t .,:;%&#""/|¦\*(<=>)@+°§¬ç¢"
NativeSpecialHTML := "`t .,%" ; line breaks handled separately


; Helper functions

ConvertAndSend(TargetChar) {
	CharCode := Asc(TargetChar)
	SendInput {ASC %CharCode%}
}

CurrentLayout() {
	WinGet, WinID,, A
	ThreadID := DllCall("GetWindowThreadProcessId", "UInt", WinID, "UInt", 0)
	InputLocaleID := DllCall("GetKeyboardLayout", "UInt", ThreadID, "UInt")
	Return InputLocaleID >> 16
}

IsNativeChar(NativeSpecial, TestChar, CharCode) {
	; alphanumerics:    0-9                                    A-Z                                    a-z
	if ((CharCode >= 48 and CharCode <= 57) or (CharCode >= 65 and CharCode <= 90) or (CharCode >= 97 and CharCode <= 122))
		Return true
	; other "native" characters
	if (InStr(NativeSpecial, TestChar))
		Return true
	Return false
}

SendClipboard(NativeSpecial) {
	WinGet, OriginalWinID,, A

	; reset global chars for each use
	global ReplaceCRLFs
	global PasteNonAscii
	SanitizeCRLFs := ReplaceCRLFs
	SendNonAscii := PasteNonAscii

	NativeChars := 0
	ControlChars := 0
	CodepageChars := 0
	UnicodeChars := 0

	ClipboardCache := Clipboard
	if (SanitizeCRLFs) {
		ClipboardCache := StrReplace(ClipboardCache, "`r`n", "`n")
		NativeSpecial := "`n" . NativeSpecial
	}
	ClipboardCache := StrReplace(ClipboardCache, "y", "Magic↔swap↔121")
	ClipboardCache := StrReplace(ClipboardCache, "Y", "Magic↔swap↔089")
	ClipboardCache := StrReplace(ClipboardCache, "z", "y")
	ClipboardCache := StrReplace(ClipboardCache, "Z", "Y")
	ClipboardCache := StrReplace(ClipboardCache, "Magic↔swap↔121", "z")
	ClipboardCache := StrReplace(ClipboardCache, "Magic↔swap↔089", "Z")

	loop, parse, ClipboardCache
	{
		CharCode := Asc(A_LoopField)
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
		MsgBox % MsgOptions, %MsgTitle%, %MsgText%
		IfMsgBox, Cancel
			Return
		IfMsgBox, Yes
			SendNonAscii := true
		else
			SendNonAscii := false
		; This dialog window often causes switching of the active window. Change back.
		WinActivate, ahk_id %OriginalWinID%
	}

	; Send a long string if possible
	if (OnlyNatives and SanitizeCRLFs) {
		; SendInput is great when it comes to long strings
		SendInput {Raw}%ClipboardCache%
		Return
	}

	; Or send it all character for character if alt codes are required
	loop, parse, ClipboardCache
	{
		CharCode := Asc(A_LoopField)
		if ((CharCode >= 32 and CharCode <= 126) and not SendNonAscii)
			Continue
		if (IsNativeChar(NativeSpecial, A_LoopField, CharCode)) {
			; Abort sending if active window is changed
			WinGet, CurrentWinID,, A
			if (not CurrentWinID = OriginalWinID)
				Return
			SendInput {Raw}%A_LoopField%
		} else {
			; Abort sending if active window is changed
			WinGet, CurrentWinID,, A
			if (not CurrentWinID = OriginalWinID)
				Return
			Send {Input}{ASC %CharCode%}
		}
	}
}


; Enable hotkey for sending clipboard

#If WinActive("Java iKVM Viewer")
!+v::
	Sleep, 250
	SendClipboard(NativeSpecialJava)
	return

#If WinActive("Resolution:")
!+v::
	Sleep, 250
	SendClipboard(NativeSpecialHTML)
	return

; for all other programs, fall back to sending text-only clipboard with no smartassery
#If PasteInOtherApps
!+v::
	Sleep, 250
	SendInput {Raw}%Clipboard%
	return


; Set of hotkeys for Asus iKVM Java app, when Swiss keyboard layout is active
#If WinActive("Java iKVM Viewer") and (CurrentLayout() = 0x0807)

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
!^SC028::ConvertAndSend("`{")

SC02b::ConvertAndSend("$")
+SC02b::ConvertAndSend("£")
!^SC02b::ConvertAndSend("`}")

SC035::ConvertAndSend("-")
+SC035::ConvertAndSend("_")


; Set of hotkeys for iKVM/HTML5 browser app, when Swiss keyboard layout is active
#If WinActive("Resolution:") and (CurrentLayout() = 0x0807)

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
+2::ConvertAndSend(chr(34))
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


; Script control functions

PauseResume:
	Suspend
	if  (A_IsSuspended) {
		Menu, Tray, Rename, Suspend HotKeys, Resume HotKeys
		/*@Ahk2Exe-Keep
			Menu, Tray, Icon, %A_ScriptFullPath%, 0, 1
		 */
		;@Ahk2Exe-IgnoreBegin
			Menu, Tray, Icon, PPCH_outlined_light.ico,, 1
		;@Ahk2Exe-IgnoreEnd
	} else {
		Menu, Tray, Rename, Resume HotKeys, Suspend HotKeys
		/*@Ahk2Exe-Keep
			Menu, Tray, Icon, %A_ScriptFullPath%, 6, 1
		*/
		;@Ahk2Exe-IgnoreBegin
			Menu, Tray, Icon, PPCH_outlined_dark.ico,, 1
		;@Ahk2Exe-IgnoreEnd
	}
Return

QuitScript:
	ExitApp
Return
