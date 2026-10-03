// ==UserScript==
// @name         Supermicro IPMI / ATEN BMC keyboard fix
// @namespace    https://github.com/Tabiskabis/iKVM-SwissBugPasta
// @version      0.1.1
// @description  iKVM/HTML5 viewer: sends every key by its physical position, so the remote's keyboard layout decides what it types, like a keyboard attached to it. Part of iKVM-SwissBugPasta: https://github.com/Tabiskabis/iKVM-SwissBugPasta
// @match        *://*/cgi/url_redirect.cgi?url_name=man_ikvm_html5_bootstrap*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

// The viewer (an old noVNC) turns each typed CHARACTER into a US key position (ast2100.js Keymap),
// sends only left-hand modifiers and never AltGr: most non-US layouts can't be typed correctly.
// This replaces its keyboard handling: the browser's physical key position (event.code) is sent
// as the matching USB key, modifiers included (right Alt = the remote's AltGr).
// The page title gets " ⌨" appended, so iKVM-SwissBugPasta.ahk knows this script is active.

(function () {
    "use strict";

    // Runs inside the page (not the userscript sandbox), to reach the viewer's objects
    function main() {
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
            IntlRo: 135, IntlYen: 137,
            ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, MetaLeft: 227, OSLeft: 227,
            ControlRight: 228, ShiftRight: 229, AltRight: 230, MetaRight: 231, OSRight: 231
        };
        var XK_Caps_Lock = 0xffe5;
        var down = {};          // event.code -> true, keys the remote has down
        var pendingCtrl = null; // left Ctrl down, held back: AltGr's (Windows adds it right before right Alt)?
        var droppedCtrl = false;

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

        function onKey(e) {
            if (!Hid[e.code]) { return; }
            // inactive (e.g. focus moved to the toolbar): still release keys the remote has down
            if (!active() && !(e.type === "keyup" && down[e.code] && rfb())) { return; }
            e.preventDefault();
            e.stopImmediatePropagation();
            if (e.type === "keypress") { return; }
            var isDown = e.type === "keydown";

            if (e.code === "ControlLeft") {
                if (isDown) {
                    if (pendingCtrl || down.ControlLeft) { return; }    // key repeat
                    pendingCtrl = setTimeout(flushCtrl, 30);
                    return;
                }
                if (pendingCtrl) {          // tapped within 30 ms
                    flushCtrl();
                } else if (droppedCtrl) {
                    droppedCtrl = false;
                    return;
                }
                if (down.ControlLeft) { send("ControlLeft", false); }
                return;
            }
            if (e.code === "AltRight" && isDown && pendingCtrl) {   // AltGr: drop its left Ctrl
                clearTimeout(pendingCtrl);
                pendingCtrl = null;
                droppedCtrl = true;
            }
            flushCtrl();
            if (!isDown && !down[e.code]) { return; }
            send(e.code, isDown);
        }

        function releaseAll() {
            if (pendingCtrl) { clearTimeout(pendingCtrl); pendingCtrl = null; }
            droppedCtrl = false;
            if (!rfb()) { return; }
            for (var code in down) { send(code, false); }
        }

        window.addEventListener("keydown", onKey, true);
        window.addEventListener("keyup", onKey, true);
        window.addEventListener("keypress", onKey, true);
        window.addEventListener("blur", releaseAll, true);

        // Marker for iKVM-SwissBugPasta.ahk, kept when the viewer updates the title
        var marker = " ⌨";
        function mark() {
            if (document.title.slice(-marker.length) !== marker) { document.title += marker; }
        }
        new MutationObserver(mark).observe(document.querySelector("title") || document.head,
            {childList: true, characterData: true, subtree: true});
        mark();
    }

    var script = document.createElement("script");
    script.textContent = "(" + main.toString() + ")();";
    (document.head || document.documentElement).appendChild(script);
    script.remove();
})();
