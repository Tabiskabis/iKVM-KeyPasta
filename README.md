# iKVM-SwissBugPasta

Lazy try at enabling clipboard pasting in Supermicro/Asus iKVM and make it usable with a Swiss keyboard layout.  
**ONLY for the specific case where both input layouts (yours and the remote machine's) are set to Switzerland (German).**

## Part 1: Workarounds for Swiss keyboard layout

Asus iKVM (prominently used for remote control of Supermicro servers) is a really stupid ass app when it comes to keystrokes.  
Instead of forwarding keyboard scan codes, the Java app tries to map the resulting *characters* according to its Virtual Keyboard Input setting.  
Some of that actually works. However, it can't map all characters. It then tries to look up and send the corresponding scan code to that character on the US layout (but mostly fails).  
  
The corresponding iKVM HTML5 browser app currently only supports the US keyboard layout. As soon as it finally supports other layouts, this script will probably break that functionality!  
  
The correct way to counter these input problems is to switching to the US keyboard layout. And even then there is the problem of the missing ISO key (VK_OEM_102).  
To counter that, I've made the ["US with Swiss style ISO key" keyboard layout](https://github.com/Tabiskabis/us-iso-layout).  
  
*Very much inadequate* but slightly more convenient: using this script.  
Input of otherwise unavailable characters is simulated using alt codes.  
To quickly enter a password and fix SSH or networking, it might just do.  

## Part 2: Enable paste from clipboard

Works in iKVM Java and HTML5, but quite slowly.
The paste from clipboard hotkey sends the clipboard's text contents, character for character, non-alphanumeric ones as alt codes.  
  
Chosen hotkey: `alt-shift-v` - makes sense to use alt, as alt codes are sent :-) and a few common apps already use ctrl-shift-v.

## Installation

I will not publish executable binaries on the internet. Use [AutoHotKey](https://www.autohotkey.com/) (v1) to run the .ahk file (or compile it into a Windows executable yourself).  

### Bugs/Limitations

 - Manual input: Dead keys don't work  
   You can't directly input letters with diacritics, but you can paste them from clipboard.
   
 - Clipboard paste: Input can be incomplete
   - iKVM is slow and its framerate drops when it receives clipboard contents
   - Race conditions can cause alt code numbers to get registered instead of character
   - Pretty much only the Linux console (not GUI) and Windows (but nnot all programs) support alt code input.
   - Unicode support (untested) depends intirely on the remote OS and application

 - UI Access: Send keystrokes to elevated (admin) windows (alternative to running as admin)
   When compiling to exe, make a self-signed developer certificate, trust it, sign the exe with it, then move the signed exe into a protected folder, i.e. %ProgramFiles%\*
   PowerShell:
```
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=My AHK UIAccess" -CertStoreLocation Cert:\CurrentUser\My
$tmp = "$env:TEMP\ahk_uia.cer"
Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Remove-Item $tmp
$installedcert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Subject -eq "CN=My AHK UIAccess"
Set-AuthenticodeSignature -FilePath "iKVM-SwissBugPasta.exe" -Certificate $installedcert
```

## Licenses

### App icons `PPCH*.ico`
Based on the [logo of the Pirate Party Switzerland](https://www.piratenpartei.ch/logos-und-fotos/). Slightly modified by myself.
License: [CC BY 3.0 CH](https://creativecommons.org/licenses/by/3.0/ch/)
