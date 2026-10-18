// ==UserScript==
// @name         Supermicro IPMI / ATEN BMC: iKVM KeyPasta (keyboard fix)
// @namespace    https://github.com/Tabiskabis/iKVM-KeyPasta
// @version      2.4.0
// @match        *://*/cgi/url_redirect.cgi?url_name=man_ikvm_html5_bootstrap*
// @match        *://*/redfish/*.IKVM
// @grant        GM.getValue
// @grant        GM.setValue
// @grant        GM.registerMenuCommand
// @run-at       document-idle
// @description  iKVM/HTML5 viewer: sends every key by its physical position, so the remote's keyboard layout decides what it types, like a keyboard attached to it, and pastes the clipboard with Alt+Shift+V (macOS: Cmd+Shift+V). Part of iKVM-KeyPasta: https://github.com/Tabiskabis/iKVM-KeyPasta
// ==/UserScript==

// The viewer (an old noVNC) turns each typed CHARACTER into a US key position (ast2100.js Keymap),
// sends only left-hand modifiers and never AltGr: most non-US layouts can't be typed correctly.
// This replaces its keyboard handling: the browser's physical key position (event.code) is sent
// as the matching USB key, modifiers included (right Alt = the remote's AltGr).
// Alt+Shift+V (macOS: Cmd+Shift+V) types the clipboard into the remote (with CapsLock on: safe
// paste, everything as alt codes). Where this script runs, iKVM-KeyPasta.ahk leaves the
// hotkey to it.
// The page title gets " ⌨" appended, so iKVM-KeyPasta.ahk knows this script is active.
// Settings (the extension's menu, "KeyPasta settings…"): the remote's layout, a default and per BMC
// (by host), characters not on the keyboard, the remote system for alt codes. Kept in the
// extension's storage for this script (GM.getValue/setValue: not readable by the BMC's pages,
// not lost with the site's data), loaded before the page part starts.

(function () {
    "use strict";

    // Runs inside the page (not the userscript sandbox), to reach the viewer's objects. settings:
    // from the extension's storage (see below); changes go back with the event ikvm-keypasta-save.
    function main(settings) {
        var LAYOUTS = [["us", "United States"], ["de-CH", "Swiss German"], ["fr-CH", "Swiss French"],
            ["de-DE", "German"], ["other", "Other: everything as alt codes (slow)"]];
        var defaultLayout = settings.defaultLayout || "de-CH";  // remote layout for fast paste (code above)
        var hostLayout = settings.hostLayout || null;           // this BMC's own; null: the default
        var layoutSaid = !!(settings.defaultLayout || settings.hostLayout);   // said: no question about it
        var PASTE_NON_ASCII = settings.pasteNonAscii || "ask";  // characters typed as alt codes: "ask", "always", "never"
        var remoteWindows = !!settings.remoteWindows;  // remote OS for alt codes of Windows-1252 128-159 (changeable in the dialog)
        var KEY_DELAY = 10;             // ms per keystroke when pasting: the BMC types slower than the browser sends

        function remoteLayout() { return hostLayout || defaultLayout; }
        function layoutName(code) {
            for (var i = 0; i < LAYOUTS.length; i++) { if (LAYOUTS[i][0] === code) { return LAYOUTS[i][1]; } }
            return code;
        }
        function save(values) {
            window.dispatchEvent(new CustomEvent("ikvm-keypasta-save", {detail: JSON.stringify(values)}));
        }

        // event.code -> USB HID usage
        var Hid = {
            KeyA: 4, KeyB: 5, KeyC: 6, KeyD: 7, KeyE: 8, KeyF: 9, KeyG: 10, KeyH: 11, KeyI: 12,
            KeyJ: 13, KeyK: 14, KeyL: 15, KeyM: 16, KeyN: 17, KeyO: 18, KeyP: 19, KeyQ: 20,
            KeyR: 21, KeyS: 22, KeyT: 23, KeyU: 24, KeyV: 25, KeyW: 26, KeyX: 27, KeyY: 28,
            KeyZ: 29,
            Digit1: 30, Digit2: 31, Digit3: 32, Digit4: 33, Digit5: 34, Digit6: 35, Digit7: 36,
            Digit8: 37, Digit9: 38, Digit0: 39,
            Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46,
            BracketLeft: 47, BracketRight: 48, Backslash: 49, Semicolon: 51, Quote: 52,
            Backquote: 53, Comma: 54, Period: 55, Slash: 56, CapsLock: 57,
            F1: 58, F2: 59, F3: 60, F4: 61, F5: 62, F6: 63, F7: 64, F8: 65, F9: 66, F10: 67,
            F11: 68, F12: 69, PrintScreen: 70, ScrollLock: 71, Pause: 72, Insert: 73, Home: 74,
            PageUp: 75, Delete: 76, End: 77, PageDown: 78, ArrowRight: 79, ArrowLeft: 80,
            ArrowDown: 81, ArrowUp: 82, NumLock: 83, NumpadDivide: 84, NumpadMultiply: 85,
            NumpadSubtract: 86, NumpadAdd: 87, NumpadEnter: 88, Numpad1: 89, Numpad2: 90,
            Numpad3: 91, Numpad4: 92, Numpad5: 93, Numpad6: 94, Numpad7: 95, Numpad8: 96,
            Numpad9: 97, Numpad0: 98, NumpadDecimal: 99, IntlBackslash: 100, ContextMenu: 101,
            NumpadEqual: 103, F13: 104, F14: 105, F15: 106, F16: 107, F17: 108, F18: 109, F19: 110,
            F20: 111, F21: 112, F22: 113, F23: 114, F24: 115, NumpadComma: 133,
            IntlRo: 135, IntlYen: 137, Lang1: 144, Lang2: 145,
            ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, MetaLeft: 227, OSLeft: 227,
            ControlRight: 228, ShiftRight: 229, AltRight: 230, MetaRight: 231, OSRight: 231
        };
        var XK_Caps_Lock = 0xffe5;
        var down = {};          // event.code -> true, keys the remote has down
        var pendingCtrl = null; // left Ctrl down, held back: AltGr's (Windows adds it right before right Alt)?
        var droppedCtrl = false;
        var pasting = false;
        var abortPaste = false;
        var pasteEsc = false;       // Esc while pasting (abortPaste: also focus loss)
        var pasteCodeHeld = null;
        var dialogOpen = false;
        var dialogCancel = null;    // closes the open dialog as Esc does
        var dialogTab = null;       // moves the focus within the open dialog (Tab, Shift+Tab)
        var capsSent = null;        // macOS: CapsLock state last passed on (see onKey)

        function rfb() { return window.UI && UI.rfb; }

        function active() {
            var r = rfb();
            return r && r._rfb_insydevnc && r._rfb_state === "normal" && !r._view_only
                && r._keyboard && r._keyboard._focused;
        }

        function send(code, isDown) {
            var r = rfb();
            if (code === "CapsLock") {      // keep the viewer's own CapsLock handling
                r._handleKeyPress(XK_Caps_Lock, isDown);
            } else {
                var hid = Hid[code];
                r._sock.send(RFB.messages.keyEventInsyde([[hid, hid]], hid, isDown ? 1 : 0));
            }
            if (isDown) { down[code] = true; } else { delete down[code]; }
        }

        function flushCtrl() {
            if (pendingCtrl) {
                clearTimeout(pendingCtrl);
                pendingCtrl = null;
                send("ControlLeft", true);
            }
        }

        var MAC = /Mac|iPhone|iPad/.test(navigator.platform || "");

        // Alt+Shift+V, macOS: Cmd+Shift+V. By letter like Ctrl+V (e.key), wherever the local layout has it
        function isPasteHotkey(e) {
            return e.type === "keydown" && e.shiftKey && !e.ctrlKey
                && (MAC ? e.metaKey && !e.altKey : e.altKey && !e.metaKey)
                && (e.code === "KeyV" || (e.key && e.key.toLowerCase() === "v"));
        }

        // The viewer's own hotkeys (Options › Hotkey Settings: Ctrl+Shift+F2..F6, shortcut.js on the
        // document) never saw a key, as onKey takes them first: each is tried with a stand-in event,
        // the one that matches acts (it stops the stand-in's propagation).
        function viewerHotkey(e) {
            var all = window.shortcut && window.shortcut.all_shortcuts;
            if (!all) { return false; }
            var hit = false;
            var standIn = {type: "keydown", keyCode: e.keyCode, which: e.which, ctrlKey: e.ctrlKey,
                shiftKey: e.shiftKey, altKey: e.altKey, metaKey: e.metaKey, target: e.target, srcElement: e.target,
                stopPropagation: function () { hit = true; }, preventDefault: function () {}};
            for (var k in all) {
                if (all[k] && all[k].event === "keydown" && typeof all[k].callback === "function") {
                    try { all[k].callback(standIn); } catch (ex) { /* not this one */ }
                    if (hit) { return true; }
                }
            }
            return false;
        }

        function onKey(e) {
            // the paste dialog: its keys go to it only, not to the viewer (stopping the event here
            // leaves the browser's own handling: Enter/Space click a button, Tab moves)
            if (dialogOpen) {
                e.stopImmediatePropagation();
                if (e.type === "keydown" && e.key === "Escape") { e.preventDefault(); dialogCancel(); }
                // Tab stays in the dialog (not on to the viewer's toolbar behind it)
                if (e.type === "keydown" && e.key === "Tab") { e.preventDefault(); dialogTab(e.shiftKey); }
                // a key the remote still has down (held when the dialog opened): released there
                if (e.type === "keyup" && down[e.code] && rfb()) { send(e.code, false); }
                return;
            }
            if (!Hid[e.code]) {     // unknown key: the viewer's, except while pasting
                if (pasting) { e.preventDefault(); e.stopImmediatePropagation(); }
                return;
            }
            if (pasting) {          // only Esc (stop) and releasing modifiers while pasting
                if (!active() && e.type !== "keyup") { return; }
                e.preventDefault();
                e.stopImmediatePropagation();
                if (e.type === "keydown" && e.code === "Escape") { abortPaste = true; pasteEsc = true; }
                if (e.type === "keyup" && down[e.code]) { send(e.code, false); }
                return;
            }
            // inactive (e.g. focus moved to the toolbar): still release keys the remote has down
            if (!active() && !(e.type === "keyup" && down[e.code] && rfb())) { return; }
            e.preventDefault();
            e.stopImmediatePropagation();
            if (e.type === "keypress") { return; }
            var isDown = e.type === "keydown";

            if (e.code === pasteCodeHeld) {     // its release: the paste hotkey's own key
                pasteCodeHeld = null;           // (a press: the release got lost, macOS with Cmd held)
                if (!isDown) { return; }
            }
            if (isPasteHotkey(e)) {
                pasteCodeHeld = e.code;
                startPaste(e.getModifierState && e.getModifierState("CapsLock"));
                return;
            }
            if (isDown && viewerHotkey(e)) { return; }      // done by the viewer, not sent

            if (e.code === "ControlLeft") {
                if (isDown) {
                    if (pendingCtrl || down.ControlLeft) { return; }    // key repeat
                    pendingCtrl = setTimeout(flushCtrl, 30);
                    return;
                }
                if (pendingCtrl) {          // tapped within 30 ms
                    flushCtrl();
                } else if (droppedCtrl) {   // AltGr's Ctrl: its release is dropped too
                    droppedCtrl = false;
                    if (!down.ControlLeft) { return; }  // (unless a real Ctrl went down meanwhile)
                }
                if (down.ControlLeft) { send("ControlLeft", false); }
                return;
            }
            // macOS reports CapsLock down when it turns on and up when it turns off: one tap each time
            if (MAC && e.code === "CapsLock") {
                var on = e.getModifierState("CapsLock");
                if (on !== capsSent) {
                    capsSent = on;
                    send("CapsLock", true);
                    send("CapsLock", false);
                }
                return;
            }
            if (e.code === "AltRight" && isDown && pendingCtrl) {   // AltGr: drop its left Ctrl
                clearTimeout(pendingCtrl);
                pendingCtrl = null;
                droppedCtrl = true;
            }
            flushCtrl();
            // macOS doesn't report releasing a key while Cmd is held: such a key as one tap right
            // away (held down until Cmd goes up, the remote's key repeat would type it again and again)
            if (MAC && isDown && e.metaKey && !/^(Control|Shift|Alt|Meta|OS|CapsLock)/.test(e.code)) {
                send(e.code, true);
                send(e.code, false);
                return;
            }
            if (!isDown && !down[e.code]) {
                // Windows browsers report only the release of PrintScreen: one tap then
                if (e.code === "PrintScreen") { send(e.code, true); send(e.code, false); }
                return;
            }
            send(e.code, isDown);
            // (and keys held before Cmd went down, if their release got lost: released with Cmd)
            if (MAC && !isDown && /^(Meta|OS)(Left|Right)$/.test(e.code)) {
                for (var code in down) {
                    if (!/^(Control|Shift|Alt|Meta|OS|CapsLock)/.test(code)) { send(code, false); }
                }
            }
        }

        function releaseAll() {
            if (pendingCtrl) { clearTimeout(pendingCtrl); pendingCtrl = null; }
            droppedCtrl = false;
            if (!rfb()) { return; }
            // Alt or Win (Command) alone would act on the remote (menu bar, Start menu): a Ctrl tap
            // breaks them up (switching away with Alt+Tab, Cmd+Tab)
            if ((down.AltLeft || down.AltRight || down.MetaLeft || down.MetaRight || down.OSLeft || down.OSRight)
                    && !down.ControlLeft) {
                send("ControlLeft", true);
                send("ControlLeft", false);
            }
            for (var code in down) { send(code, false); }
        }

        // while pasting, only the browser window losing focus counts (the dialog takes focus too)
        function onBlur(e) {
            if (pasting) {
                if (e.target === window) { abortPaste = true; }
                return;
            }
            releaseAll();
        }

        // ---- Paste ----

        // Layouts: event.code -> characters with no modifier, Shift, AltGr ("" = none or dead key).
        // The same tables as the Java agent's (Layouts.java).
        var SWISS_ROWS = [
            ["Digit1", "1", "+", "¦"], ["Digit2", "2", "\"", "@"], ["Digit3", "3", "*", "#"],
            ["Digit4", "4", "ç", "°"], ["Digit5", "5", "%", "§"], ["Digit6", "6", "&", "¬"],
            ["Digit7", "7", "/", "|"], ["Digit8", "8", "(", "¢"], ["Digit9", "9", ")", ""],
            ["Digit0", "0", "=", ""], ["Minus", "'", "?", ""], ["KeyE", "e", "E", "€"],
            ["BracketLeft", "ü", "è", "["], ["BracketRight", "", "!", "]"],
            ["Semicolon", "ö", "é", ""], ["Quote", "ä", "à", "{"],
            ["Backquote", "§", "°", ""], ["Backslash", "$", "£", "}"],
            ["Comma", ",", ";", ""], ["Period", ".", ":", ""], ["Slash", "-", "_", ""],
            ["IntlBackslash", "<", ">", "\\"], ["Tab", "\t", "", ""], ["Space", " ", "", ""]
        ];
        var GERMAN_ROWS = [     // (X11 has a dead ~ on AltGr++; Windows and the Linux console don't)
            ["Backquote", "", "°", ""],
            ["Digit1", "1", "!", ""], ["Digit2", "2", "\"", "²"], ["Digit3", "3", "§", "³"],
            ["Digit4", "4", "$", ""], ["Digit5", "5", "%", ""], ["Digit6", "6", "&", ""],
            ["Digit7", "7", "/", "{"], ["Digit8", "8", "(", "["], ["Digit9", "9", ")", "]"],
            ["Digit0", "0", "=", "}"], ["Minus", "ß", "?", "\\"],
            ["KeyQ", "q", "Q", "@"], ["KeyE", "e", "E", "€"],
            ["BracketLeft", "ü", "Ü", ""], ["BracketRight", "+", "*", "~"],
            ["Semicolon", "ö", "Ö", ""], ["Quote", "ä", "Ä", ""], ["Backslash", "#", "'", ""],
            ["KeyM", "m", "M", "µ"], ["Comma", ",", ";", ""], ["Period", ".", ":", ""], ["Slash", "-", "_", ""],
            ["IntlBackslash", "<", ">", "|"], ["Tab", "\t", "", ""], ["Space", " ", "", ""]
        ];
        var US_ROWS = [         // (the ISO key left out: \ and | are on Backslash on every US keyboard)
            ["Backquote", "`", "~", ""],
            ["Digit1", "1", "!", ""], ["Digit2", "2", "@", ""], ["Digit3", "3", "#", ""],
            ["Digit4", "4", "$", ""], ["Digit5", "5", "%", ""], ["Digit6", "6", "^", ""],
            ["Digit7", "7", "&", ""], ["Digit8", "8", "*", ""], ["Digit9", "9", "(", ""],
            ["Digit0", "0", ")", ""], ["Minus", "-", "_", ""], ["Equal", "=", "+", ""],
            ["BracketLeft", "[", "{", ""], ["BracketRight", "]", "}", ""],
            ["Semicolon", ";", ":", ""], ["Quote", "'", "\"", ""], ["Backslash", "\\", "|", ""],
            ["Comma", ",", "<", ""], ["Period", ".", ">", ""], ["Slash", "/", "?", ""],
            ["Tab", "\t", "", ""], ["Space", " ", "", ""]
        ];
        // QWERTZ: z and y swapped against the key codes (which name the US letter at that place)
        var QWERTZ = { q: "KeyQ", w: "KeyW", e: "KeyE", r: "KeyR", t: "KeyT", z: "KeyY", u: "KeyU",
            i: "KeyI", o: "KeyO", p: "KeyP", a: "KeyA", s: "KeyS", d: "KeyD", f: "KeyF", g: "KeyG",
            h: "KeyH", j: "KeyJ", k: "KeyK", l: "KeyL", y: "KeyZ", x: "KeyX", c: "KeyC", v: "KeyV",
            b: "KeyB", n: "KeyN", m: "KeyM" };
        var QWERTY = {};
        "abcdefghijklmnopqrstuvwxyz".split("").forEach(function (l) { QWERTY[l] = "Key" + l.toUpperCase(); });

        // character -> [code, modifiers (1 Shift, 2 AltGr)], fewest modifiers first
        function layoutTable(layout) {
            var french = layout === "fr-CH";
            var rows = layout === "us" ? US_ROWS : layout === "de-DE" ? GERMAN_ROWS : SWISS_ROWS;
            var letters = layout === "us" ? QWERTY : QWERTZ;
            var table = {};
            for (var mods = 0; mods <= 2; mods++) {
                if (mods < 2) {
                    for (var letter in letters) {
                        var c = mods ? letter.toUpperCase() : letter;
                        if (!(c in table)) { table[c] = [letters[letter], mods]; }
                    }
                }
                for (var i = 0; i < rows.length; i++) {
                    var row = rows[i];
                    var value = row[1 + mods];
                    // Swiss French: the umlauts and the accented letters swap places
                    if (french && mods < 2 && (row[0] === "BracketLeft" || row[0] === "Semicolon" || row[0] === "Quote")) {
                        value = row[mods ? 1 : 2];
                    }
                    if (value && !(value in table)) { table[value] = [row[0], mods]; }
                }
            }
            return table;
        }

        // Windows-1252 characters 128-159: Unicode code point -> ANSI code
        var CP1252 = { 0x20AC: 128, 0x201A: 130, 0x0192: 131, 0x201E: 132, 0x2026: 133, 0x2020: 134,
            0x2021: 135, 0x02C6: 136, 0x2030: 137, 0x0160: 138, 0x2039: 139, 0x0152: 140, 0x017D: 142,
            0x2018: 145, 0x2019: 146, 0x201C: 147, 0x201D: 148, 0x2022: 149, 0x2013: 150, 0x2014: 151,
            0x02DC: 152, 0x2122: 153, 0x0161: 154, 0x203A: 155, 0x0153: 156, 0x017E: 158, 0x0178: 159 };

        // Windows reads Alt+nnn as OEM code page and Alt+0nnn as ANSI, the Linux console reads both
        // as Unicode: 160-255 always get the leading 0, only Windows-1252 128-159 differ
        function altCodeDigits(cp) {
            if (cp >= 160 && cp <= 255) { return "0" + cp; }
            if (remoteWindows && (cp in CP1252)) { return "0" + CP1252[cp]; }
            return String(cp);
        }

        function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

        function plan(text, safe) {
            var layout = remoteLayout() === "other" ? "de-CH" : remoteLayout();
            var table = layoutTable(layout);
            var swiss = layout === "de-CH" || layout === "fr-CH";
            var items = [];
            for (var i = 0; i < text.length;) {
                var cp = text.codePointAt(i);
                var ch = String.fromCodePoint(cp);
                i += ch.length;
                var key = null;
                if (ch === "\n") { key = ["Enter", 0]; }
                else if (safe) {
                    if (ch === "\t") { key = ["Tab", 0]; } else if (ch === " ") { key = ["Space", 0]; }
                } else if (!(swiss && "´`^~¨¦".indexOf(ch) >= 0) && (ch in table)) { key = table[ch]; }   // Swiss: dead keys; ¦: | on Linux
                items.push({ cp: cp, key: key });
            }
            return items;
        }

        // Dialogs: in a shadow root of their own, so the BMC page's styles don't reach them
        var DIALOG_CSS = ":host{all:initial}"
            + ".shade{position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:2147483647;display:flex;"
            + "align-items:center;justify-content:center;padding:16px;box-sizing:border-box;"
            + "font:13px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;"
            + "--bg:#fff;--fg:#1d1d1f;--dim:#6e6e73;--line:#c7c7cc;--accent:#0a64d8;color:var(--fg)}"
            + "@media (prefers-color-scheme:dark){.shade{--bg:#2c2c2e;--fg:#f2f2f7;--dim:#a1a1a6;"
            + "--line:#545458;--accent:#3d8bfd}}"
            + ".box{background:var(--bg);border-radius:10px;box-shadow:0 12px 40px rgba(0,0,0,.35);"
            + "width:460px;max-width:100%;padding:18px 20px 16px;box-sizing:border-box}"
            + "h1{font-size:15px;font-weight:600;margin:0 0 12px}"
            + "p{margin:0 0 8px}"
            + "h2{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;"
            + "color:var(--dim);margin:10px 0 0}"
            + "h2{grid-column:1/-1}h2:first-child{margin-top:0}"
            + ".grid{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 12px;align-items:center}"
            + "select{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--line);"
            + "border-radius:6px;padding:4px 6px;width:100%;box-sizing:border-box}"
            + ".note{margin-top:16px;font-size:12px;color:var(--dim)}"
            + ".os{margin-top:10px;display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center}"
            + ".os label{display:inline-flex;gap:5px;align-items:center}"
            + ".buttons{display:flex;justify-content:flex-end;gap:8px;margin-top:18px}"
            + "button{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--line);"
            + "border-radius:6px;padding:5px 14px;min-width:76px;cursor:pointer}"
            + "button.default{background:var(--accent);border-color:var(--accent);color:#fff}"
            + "button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid var(--accent);"
            + "outline-offset:2px}";

        // Dialog with its own buttons; resolves to the label clicked, or null (Esc)
        function ask(html, buttons, defaultButton, osSelector, extra, title) {
            return new Promise(function (resolve) {
                var host = document.createElement("div");
                var root = host.attachShadow({mode: "open"});
                var style = document.createElement("style");
                style.textContent = DIALOG_CSS;
                root.appendChild(style);
                var shade = document.createElement("div");
                shade.className = "shade";
                var box = document.createElement("div");
                box.className = "box";
                box.setAttribute("role", "dialog");
                box.innerHTML = "<h1></h1>" + html;
                box.querySelector("h1").textContent = title || "iKVM clipboard autotype";
                if (osSelector) {
                    var os = document.createElement("div");
                    os.className = "os";
                    os.innerHTML = "Remote OS: <label><input type=radio name=sbp-os value=linux> Linux console</label>"
                        + "<label><input type=radio name=sbp-os value=windows> Windows</label>";
                    os.querySelector("input[value=" + (remoteWindows ? "windows" : "linux") + "]").checked = true;
                    os.addEventListener("change", function (ev) {
                        remoteWindows = ev.target.value === "windows";
                        save({remoteWindows: remoteWindows});
                    });
                    box.appendChild(os);
                }
                if (extra) { box.appendChild(extra); }
                var row = document.createElement("div");
                row.className = "buttons";
                var done = function (label) {
                    dialogOpen = false;
                    dialogCancel = null;
                    dialogTab = null;
                    host.remove();
                    resolve(label);
                };
                dialogCancel = function () { done(null); };     // Esc, see onKey
                dialogTab = function (back) {                   // Tab, see onKey
                    var items = Array.prototype.slice.call(box.querySelectorAll("select, button, input:checked"));
                    var i = items.indexOf(root.activeElement);
                    i = i < 0 ? 0 : (i + (back ? items.length - 1 : 1)) % items.length;
                    items[i].focus();
                };
                var focusButton = null;
                buttons.forEach(function (label, i) {
                    var b = document.createElement("button");
                    b.textContent = label;
                    if (i === defaultButton) { b.className = "default"; focusButton = b; }
                    b.addEventListener("click", function () { done(label); });
                    row.appendChild(b);
                });
                box.appendChild(row);
                shade.appendChild(box);
                root.appendChild(shade);
                document.body.appendChild(host);
                dialogOpen = true;
                (extra && extra.querySelector("select") || focusButton).focus();
            });
        }

        async function startPaste(capsLock) {
            pasting = true;
            abortPaste = false;
            pasteEsc = false;
            try {
                // The hotkey's modifiers went down on the remote. Released with nothing in between,
                // the remote sees them alone (Alt+Shift: Windows switches the input language; Alt:
                // menu bars). A Ctrl tap while they're held breaks them up.
                send("ControlLeft", true);
                send("ControlLeft", false);
                // wait until the hotkey is released (onKey sends those releases)
                for (var t = 0; t < 500 && (down.AltLeft || down.AltRight || down.ShiftLeft || down.ShiftRight || down.MetaLeft || down.MetaRight || down.OSLeft || down.OSRight); t++) {
                    await sleep(10);
                }
                var text;
                if (!navigator.clipboard || !navigator.clipboard.readText) {
                    await ask("The browser only lets secure pages read the clipboard: open the BMC with https://.", ["OK"], 0, false);
                    return;
                }
                try {
                    text = await navigator.clipboard.readText();
                } catch (err) {
                    await ask("Can't read the clipboard here: " + String(err).replace(/</g, "&lt;"), ["OK"], 0, false);
                    return;
                }
                abortPaste = false;     // focus lost meanwhile (permission prompt) doesn't count, Esc does
                if (pasteEsc || !text) { return; }
                text = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
                var safe = !!capsLock || remoteLayout() === "other";
                var sendNonAscii = PASTE_NON_ASCII !== "never";
                var items = plan(text, safe);

                var lineBreaks = 0, altGr = 0, control = 0, codepage = 0, unicode = 0, cp1252 = 0, beyond = 0;
                items.forEach(function (it) {
                    var cp = it.cp;
                    if (it.key) {
                        if (cp === 10) { lineBreaks++; } else if (it.key[1] & 2) { altGr++; }
                        return;
                    }
                    if (cp < 32 || cp === 127) { control++; }
                    else if ((cp >= 128 && cp <= 255) || (remoteWindows && (cp in CP1252))) { codepage++; }
                    else if (cp > 255) { unicode++; }
                    if (cp > 255) { if (cp in CP1252) { cp1252++; } else { beyond++; } }
                });
                var askLayout = !safe && !layoutSaid && (lineBreaks > 0 || altGr > 0);
                var slow = control + codepage + unicode;
                var askSlow = PASTE_NON_ASCII === "ask" && slow > 0;
                if (askLayout || askSlow) {
                    var msg = "";
                    if (askLayout) {
                        msg += "<p>• Includes line breaks or AltGr characters (@ # | { } …): if the remote "
                            + "system doesn't use the " + layoutName(remoteLayout()) + " layout, garbled commands could run. "
                            + "Safe paste works with any layout, but is slower. (The extension's menu, KeyPasta "
                            + "settings: say this BMC's layout, and this isn't asked again.)</p>";
                    }
                    if (askSlow) {
                        msg += "<p>• " + slow + (slow > 1 ? " characters" : " character")
                            + " not on the keyboard: typed slowly as Alt + number."
                            + (control ? " Includes control characters!" : "") + "</p>";
                        if (cp1252 + beyond) {
                            msg += "<p>• " + (cp1252 + beyond) + " of them depend on the remote's OS, choose it below"
                                + (beyond ? " (" + beyond + " of them likely don't work on Windows at all)." : ".") + "</p>";
                        }
                    }
                    var buttons = askLayout ? ["Fast paste", "Safe paste", "Cancel"] : ["Paste", "Cancel"];
                    var answer = await ask(msg, buttons, control ? buttons.length - 1 : 0, askSlow && cp1252 + beyond > 0);
                    if (!answer || answer === "Cancel") { return; }
                    abortPaste = false;     // switched away and back while the dialog was open
                    sendNonAscii = PASTE_NON_ASCII === "ask" || sendNonAscii;
                    if (answer === "Safe paste") { safe = true; items = plan(text, true); }
                    var canvas = document.querySelector("canvas");
                    if (canvas) { canvas.focus(); }
                    await sleep(100);
                }

                for (var n = 0; n < items.length; n++) {
                    var it = items[n];
                    var cp = it.cp;
                    if (!it.key && !sendNonAscii && !(cp >= 32 && cp <= 126)) { continue; }
                    if (abortPaste || !rfb() || !document.hasFocus()) { return; }
                    if (!it.key) {
                        send("AltLeft", true);
                        var digits = altCodeDigits(cp);
                        for (var d = 0; d < digits.length; d++) {
                            send("Numpad" + digits[d], true);
                            send("Numpad" + digits[d], false);
                            await sleep(KEY_DELAY);
                        }
                        send("AltLeft", false);
                    } else {
                        if (it.key[1] & 1) { send("ShiftLeft", true); }
                        if (it.key[1] & 2) { send("AltRight", true); }
                        send(it.key[0], true);
                        send(it.key[0], false);
                        if (it.key[1] & 2) { send("AltRight", false); }
                        if (it.key[1] & 1) { send("ShiftLeft", false); }
                    }
                    await sleep(KEY_DELAY);
                }
            } finally {
                pasting = false;
            }
        }

        // Settings dialog (the extension's menu: KeyPasta settings…)
        var selectCount = 0;
        function select(options, value) {
            var sel = document.createElement("select");
            sel.id = "kp-select-" + (++selectCount);
            options.forEach(function (o) {
                var opt = document.createElement("option");
                opt.value = o[0];
                opt.textContent = o[1];
                sel.appendChild(opt);
            });
            sel.value = value;
            return sel;
        }
        function section(grid, heading, rows) {     // in one grid: the controls line up
            var h = document.createElement("h2");
            h.textContent = heading;
            grid.appendChild(h);
            rows.forEach(function (r) {
                var label = document.createElement("label");
                label.textContent = r[0];
                label.htmlFor = r[1].id;
                grid.appendChild(label);
                grid.appendChild(r[1]);
            });
        }
        async function showSettings() {
            if (dialogOpen) { return; }
            var panel = document.createElement("div");
            var def = select(LAYOUTS, defaultLayout);
            var own = select([["", "Same as the default"]].concat(LAYOUTS), hostLayout || "");
            var nonAscii = select([["ask", "Ask when pasting"], ["always", "Type as alt codes (slow)"],
                ["never", "Leave out"]], PASTE_NON_ASCII);
            var os = select([["linux", "Linux console"], ["windows", "Windows"]], remoteWindows ? "windows" : "linux");
            var grid = document.createElement("div");
            grid.className = "grid";
            panel.appendChild(grid);
            section(grid, "Keyboard layout of the remote computer", [["Default", def], ["This BMC" + (location.hostname ? " (" + location.hostname + ")" : ""), own]]);
            section(grid, "Pasting", [["Characters not on the keyboard", nonAscii], ["Alt codes for", os]]);
            var note = document.createElement("div");
            note.className = "note";
            note.textContent = "With CapsLock on, a paste types everything as alt codes (safe paste).";
            panel.appendChild(note);
            var answer = await ask("", ["Cancel", "OK"], 1, false, panel, "iKVM-KeyPasta settings");
            if (answer !== "OK") { return; }
            defaultLayout = def.value;
            hostLayout = own.value || null;
            layoutSaid = true;
            PASTE_NON_ASCII = nonAscii.value;
            remoteWindows = os.value === "windows";
            save({defaultLayout: defaultLayout, hostLayout: hostLayout, pasteNonAscii: PASTE_NON_ASCII,
                remoteWindows: remoteWindows});
            var canvas = document.querySelector("canvas");
            if (canvas) { canvas.focus(); }
        }
        window.addEventListener("ikvm-keypasta-settings", function () { showSettings(); });

        // Video recording: the viewer records only in Chrome. In other browsers it shows a warning
        // each time it opens (UI.HandleVideoRecorder) and drops its Record menu (older viewer:
        // #VideoRecordingModal, Capture menu) or its record button (newer viewer, the one with
        // buttons: .ikvm-card.record, the warning in the shared #warningModal). The warning is left
        // out; a grayed out "Video recording (unavailable)" (older: in the Capture menu, newer: the
        // record button kept, grayed) shows it when clicked.
        (function () {
            var jq = window.$jq || window.jQuery;
            if (!jq || !jq.fn || !jq.fn.modal || navigator.userAgent.indexOf("Chrome") >= 0) { return; }
            var UNAVAILABLE = "Video recording (unavailable)";
            var wanted = false;     // the warning shown on purpose (clicked)
            function oldModal() { return document.getElementById("VideoRecordingModal"); }
            function recordText() {
                try { return window.translator && translator.g("LANG_PREFER_RECORD_NOT_ALLOW"); } catch (e) { return null; }
            }
            function isRecordWarning(el) {
                if (!el) { return false; }
                if (el === oldModal()) { return true; }
                var text = recordText();
                return el.id === "warningModal" && !!text && el.textContent.indexOf(text) >= 0;
            }
            var originalModal = jq.fn.modal;
            jq.fn.modal = function (option) {
                if (!wanted && this.length && isRecordWarning(this[0]) && (option === undefined || option === "show"
                        || typeof option === "object")) { return this; }
                return originalModal.apply(this, arguments);
            };
            Object.keys(originalModal).forEach(function (k) { jq.fn.modal[k] = originalModal[k]; });
            function hideNow(el) {      // shown before this ran: gone at once (no fade), backdrop included
                var fade = el.classList.contains("fade");
                el.classList.remove("fade");
                originalModal.call(jq(el), "hide");
                if (fade) { el.classList.add("fade"); }
            }
            ["VideoRecordingModal", "warningModal"].forEach(function (id) {
                var el = document.getElementById(id);
                if (!el) { return; }
                jq(el).on("hidden.bs.modal", function () { wanted = false; });
                // also when shown some other way, or already on its way in (Bootstrap 5: its element
                // appears after the backdrop, and a hide while it fades in is ignored)
                jq(el).on("show.bs.modal", function (ev) {
                    if (ev.target === el && !wanted && isRecordWarning(el)) { ev.preventDefault(); }
                });
                jq(el).on("shown.bs.modal", function (ev) {
                    if (ev.target === el && !wanted && isRecordWarning(el)) { hideNow(el); }
                });
                if ((el.classList.contains("in") || el.classList.contains("show") || el.style.display === "block")
                        && isRecordWarning(el)) { hideNow(el); }
            });
            function showWarning() {
                wanted = true;
                if (oldModal()) { originalModal.call(jq(oldModal()), "show"); return; }
                var text = recordText();
                if (text && typeof window.warnModalObj === "function") { new window.warnModalObj(text).init(); }
                originalModal.call(jq("#warningModal"), "show");
            }

            // older viewer: an item in the Capture menu
            var capture = document.getElementById("capture");
            var list = oldModal() && capture && capture.closest("ul");
            if (list) {
                var li = document.createElement("li");
                li.className = "disabled";
                // not an <a>: the viewer labels its menu items by counting "li a" (lang.menus)
                var item = document.createElement("span");
                item.textContent = UNAVAILABLE;
                item.title = "Recording works in Chrome only";
                item.setAttribute("role", "menuitem");
                item.style.cssText = "display:block;clear:both;white-space:nowrap;cursor:not-allowed;color:#777";
                // looks like its neighbor, measured when the menu opens (its padding depends on the layout)
                jq(list.parentNode).on("shown.bs.dropdown", function () {
                    var cs = getComputedStyle(capture);
                    ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft", "lineHeight", "fontSize"].forEach(function (k) {
                        item.style[k] = cs[k];
                    });
                });
                item.addEventListener("click", showWarning);
                li.appendChild(item);
                list.appendChild(li);
                return;
            }

            // newer viewer: the record button kept (it removes it), grayed out
            var style = document.createElement("style");
            style.textContent = ".ikvm-card.kp-unavailable,.ikvm-card.kp-unavailable:hover{"
                + "background-image:linear-gradient(to bottom,#6b7480,#3c434b);cursor:not-allowed}"
                + ".ikvm-card.kp-unavailable img{opacity:.45}"
                + ".ikvm-card.kp-unavailable:hover .img-front{display:inline-block}"
                + ".ikvm-card.kp-unavailable:hover .img-back{display:none}";
            document.head.appendChild(style);
            function gray(card) {
                card.classList.add("kp-unavailable");
                var tip = card.querySelector(".tooltiptext");
                if (tip) { tip.textContent = UNAVAILABLE; } else { card.title = UNAVAILABLE; }
            }
            var originalRemove = jq.fn.remove;
            jq.fn.remove = function () {
                var cards = this.filter(".ikvm-card.record");
                if (!cards.length) { return originalRemove.apply(this, arguments); }
                cards.each(function () { gray(this); });
                return originalRemove.apply(this.not(".ikvm-card.record"), arguments);
            };
            // removed before this ran: one like it, before the screenshot button
            if (!document.querySelector(".ikvm-card.record")) {
                var shot = document.getElementById("captures");
                var next = shot && (shot.closest(".ikvm-card") || shot);
                if (next && next.parentNode) {
                    var card = document.createElement("div");
                    card.className = "ikvm-card record";
                    card.innerHTML = "<img class='img-front' src='/images/ikvm/record.png' alt=''>"
                        + "<img class='img-back' src='/images/ikvm/hover/record.png' alt=''>"
                        + "<span class='tooltiptext'></span>";
                    next.parentNode.insertBefore(card, next);
                    gray(card);
                }
            } else {
                Array.prototype.forEach.call(document.querySelectorAll(".ikvm-card.record"), gray);
            }
            // its own click handlers (start recording) never get the click
            document.addEventListener("click", function (e) {
                if (!e.target.closest || !e.target.closest(".ikvm-card.kp-unavailable")) { return; }
                e.preventDefault();
                e.stopImmediatePropagation();
                showWarning();
            }, true);
        })();

        window.addEventListener("keydown", onKey, true);
        window.addEventListener("keyup", onKey, true);
        window.addEventListener("keypress", onKey, true);
        window.addEventListener("blur", onBlur, true);

        // Layout: the page sits in Bootstrap's fixed-width, centered .container (made for small remote
        // resolutions); a larger remote screen stuck out of it to the right only. The container
        // takes the width of its content instead: centered while it fits the window, else from the
        // left edge (the page scrolls).
        if (document.getElementById("VideoRecordingModal")) {   // the older viewer's page only
            var layoutStyle = document.createElement("style");
            layoutStyle.textContent = "body>.container{width:max-content;max-width:none}";
            document.head.appendChild(layoutStyle);
        }

        // Marker for iKVM-KeyPasta.ahk (it leaves the keys alone then), kept when the viewer
        // updates the title. Only once the viewer is one this script works with (Insyde protocol).
        var marker = " ⌨";
        function mark() {
            var r = rfb();
            if (r && r._rfb_insydevnc && document.title.slice(-marker.length) !== marker) { document.title += marker; }
        }
        new MutationObserver(mark).observe(document.querySelector("title") || document.head,
            {childList: true, characterData: true, subtree: true});
        setInterval(mark, 1000);
        mark();
    }

    // The settings, from the extension's storage: a default layout, one per BMC (key: layout:<host>),
    // the rest global. Saved when the page part reports a change.
    var host = location.host;
    async function load() {
        return {
            defaultLayout: await GM.getValue("defaultLayout", ""),
            hostLayout: await GM.getValue("layout:" + host, ""),
            pasteNonAscii: await GM.getValue("pasteNonAscii", ""),
            remoteWindows: await GM.getValue("remoteWindows", false)
        };
    }
    window.addEventListener("ikvm-keypasta-save", function (ev) {
        var values = JSON.parse(ev.detail);
        if ("defaultLayout" in values) { GM.setValue("defaultLayout", values.defaultLayout); }
        if ("hostLayout" in values) { GM.setValue("layout:" + host, values.hostLayout || ""); }
        if ("pasteNonAscii" in values) { GM.setValue("pasteNonAscii", values.pasteNonAscii); }
        if ("remoteWindows" in values) { GM.setValue("remoteWindows", !!values.remoteWindows); }
    });
    if (typeof GM.registerMenuCommand === "function") {
        GM.registerMenuCommand("KeyPasta settings…", function () {
            window.dispatchEvent(new CustomEvent("ikvm-keypasta-settings"));
        });
    }
    load().then(function (settings) {
        var script = document.createElement("script");
        script.textContent = "(" + main.toString() + ")(" + JSON.stringify(settings) + ");";
        (document.head || document.documentElement).appendChild(script);
        script.remove();
    });
})();
