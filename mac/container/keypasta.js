// iKVM-KeyPasta in the container's browser view (noVNC): the paste hotkey with this computer's
// clipboard, the clipboard shared both ways, and keys as a Mac's browser gives them fixed up.
//
// PASTE HOTKEY
//
// The agent's paste hotkey (in the viewer, in the container) types what is in the container's
// clipboard. That is the Mac's clipboard only once noVNC has handed it over (its clipboard panel).
// Here the hotkey does that itself: pressed in the page, it reads the browser's clipboard, gives
// it to the container (noVNC's clipboardPasteFrom: TigerVNC's extended clipboard, UTF-8), then
// sends the hotkey's key on, so the agent pastes it. The modifiers (Option, Shift) have gone to
// the container already, as pressed. Reading the clipboard is up to the browser: Chrome and Edge
// ask once per page (each port is a page of its own), Safari shows a "Paste" button, Firefox a
// menu entry. Not allowed or empty: the key goes on all the same (the container's clipboard).
//
// The hotkeys: keypasta.json next to the page, {"paste": ["alt+shift+V", ...]}: every paste hotkey
// in the agent's settings, the default and the hosts' own (keypasta-websockify reads them from
// agent.properties); the page can't know which BMC's viewer has the focus, the agent decides. The
// agent's syntax: ctrl, alt (option), shift, meta (cmd), then the key: a letter, a digit, or a
// Java key name (F1-F24, INSERT, NUMPAD5, SEMICOLON, ...; NAMED below has the ones known here, a
// hotkey with another key is left to the agent: the container's clipboard). By the key's position
// on a US keyboard (the container's layout, where the agent looks for it).

import UI from './app/ui.js';

let specs = ['alt+shift+V'];
try {
    const r = await fetch('keypasta.json', { cache: 'no-store' });
    if (r.ok) {
        const p = (await r.json()).paste;
        if (Array.isArray(p) && p.length) specs = p;
        else if (typeof p === 'string' && p) specs = [p];
    }
} catch (err) {
    // the default
}
const hotkeys = specs.map(parse).filter(h => /^[A-Z0-9]$/.test(h.key) || NAMED[h.key]);
const spec = specs.join(', ');
const swallowed = new Set();

function parse(s) {
    const parts = s.split('+').map(p => p.trim().toLowerCase());
    const h = { ctrl: false, alt: false, shift: false, meta: false, key: (parts.pop() || '').toUpperCase() };
    for (const m of parts) {
        if (m === 'ctrl' || m === 'control') h.ctrl = true;
        else if (m === 'alt' || m === 'option') h.alt = true;
        else if (m === 'shift') h.shift = true;
        else if (m === 'meta' || m === 'cmd' || m === 'win') h.meta = true;
    }
    return h;
}

// Java key names (KeyEvent.VK_ without VK_) -> [e.code, X keysym], besides letters, digits, F1-F24
const NAMED = {
    INSERT: ['Insert', 0xFF63], DELETE: ['Delete', 0xFFFF], HOME: ['Home', 0xFF50], END: ['End', 0xFF57],
    PAGE_UP: ['PageUp', 0xFF55], PAGE_DOWN: ['PageDown', 0xFF56], UP: ['ArrowUp', 0xFF52],
    DOWN: ['ArrowDown', 0xFF54], LEFT: ['ArrowLeft', 0xFF51], RIGHT: ['ArrowRight', 0xFF53],
    PAUSE: ['Pause', 0xFF13], SCROLL_LOCK: ['ScrollLock', 0xFF14], PRINTSCREEN: ['PrintScreen', 0xFF61],
    ENTER: ['Enter', 0xFF0D], TAB: ['Tab', 0xFF09], SPACE: ['Space', 0x20], BACK_SPACE: ['Backspace', 0xFF08],
    ESCAPE: ['Escape', 0xFF1B], MULTIPLY: ['NumpadMultiply', 0xFFAA], ADD: ['NumpadAdd', 0xFFAB],
    SUBTRACT: ['NumpadSubtract', 0xFFAD], DECIMAL: ['NumpadDecimal', 0xFFAE], DIVIDE: ['NumpadDivide', 0xFFAF],
    SEMICOLON: ['Semicolon', 0x3B], EQUALS: ['Equal', 0x3D], COMMA: ['Comma', 0x2C], MINUS: ['Minus', 0x2D],
    PERIOD: ['Period', 0x2E], SLASH: ['Slash', 0x2F], BACK_QUOTE: ['Backquote', 0x60],
    OPEN_BRACKET: ['BracketLeft', 0x5B], CLOSE_BRACKET: ['BracketRight', 0x5D], BACK_SLASH: ['Backslash', 0x5C],
    QUOTE: ['Quote', 0x27],
};
for (let n = 0; n <= 9; n++) NAMED['NUMPAD' + n] = ['Numpad' + n, 0xFFB0 + n];
for (let n = 1; n <= 24; n++) NAMED['F' + n] = ['F' + n, 0xFFBE + n - 1];

// The key by its position, in the agent's names: "V", "5", "F5", "INSERT"; null for others.
function keyOf(e) {
    let m = /^Key([A-Z])$/.exec(e.code);
    if (m) return m[1];
    m = /^Digit([0-9])$/.exec(e.code);
    if (m) return m[1];
    for (const name in NAMED) if (NAMED[name][0] === e.code) return name;
    return null;
}

// X keysym of such a key: the lowercase letter, the digit, else from NAMED.
function keysymOf(key) {
    if (/^[A-Z]$/.test(key)) return key.toLowerCase().charCodeAt(0);
    if (/^[0-9]$/.test(key)) return key.charCodeAt(0);
    return NAMED[key][1];
}

// The hotkey this key press is, or null
function hotkeyOf(e) {
    const key = keyOf(e);
    return hotkeys.find(h => key === h.key && e.ctrlKey === h.ctrl && e.altKey === h.alt
        && e.shiftKey === h.shift && e.metaKey === h.meta) || null;
}

function stop(e) {
    e.preventDefault();
    e.stopImmediatePropagation();
}

// Capture phase on the window: before noVNC's own key handling (on its canvas) sees the key.
window.addEventListener('keydown', (e) => {
    const rfb = UI.rfb;
    if (!rfb || !hotkeys.length) return;
    if (swallowed.has(e.code)) {                // its key repeat
        stop(e);
        return;
    }
    const hotkey = hotkeyOf(e);
    if (!hotkey) return;
    stop(e);
    swallowed.add(e.code);
    const code = e.code;
    const send = () => {
        rfb.sendKey(keysymOf(hotkey.key), code, true);
        rfb.sendKey(keysymOf(hotkey.key), code, false);
    };
    let read;
    try {
        read = navigator.clipboard.readText();
    } catch (err) {
        read = Promise.reject(err);
    }
    read.then((text) => {
        if (text) rfb.clipboardPasteFrom(text);
    }, (err) => {
        console.info('KeyPasta: the clipboard could not be read (' + err + '): the container\'s is pasted');
    }).then(send);
}, true);

window.addEventListener('keyup', (e) => {
    if (swallowed.delete(e.code)) stop(e);
    // macOS sends no release for a key pressed with Command held: the hotkey's key (cmd+shift+V)
    // stayed "swallowed", and every later press of it with it. Command up: none is held any more.
    if (e.key === 'Meta') swallowed.clear();
}, true);

// CLIPBOARD, shared both ways, as far as the browser lets a page:
// - copied in the container (Xvnc sends the CLIPBOARD selection, not a mere selection: SendPrimary=0)
//   -> this computer's clipboard (writeText: Chrome and Edge while the page has the focus; else
//   when it gets it back);
// - this computer's clipboard -> the container's, whenever the page gets the focus, if reading it
//   is allowed already (Chrome, Edge: once asked by the paste hotkey, or the site's settings).
//   Not asked for here: Safari and Firefox would ask on every switch to the tab.
let lastText = null;            // the last text that went either way: not sent back
let pendingWrite = null;        // copied in the container while the page had no focus
let hookedRfb = null;

function writeHost(text) {
    if (!navigator.clipboard || !navigator.clipboard.writeText) return;
    navigator.clipboard.writeText(text).then(() => {
        pendingWrite = null;
    }, () => {
        pendingWrite = text;    // no focus (or not allowed): on the next focus
    });
}

function hookRfb() {
    const rfb = UI.rfb;
    if (!rfb || rfb === hookedRfb) return;
    hookedRfb = rfb;
    rfb.addEventListener('clipboard', (e) => {
        const text = e.detail && e.detail.text;
        if (typeof text !== 'string' || text === lastText) return;
        lastText = text;
        writeHost(text);
    });
}
setInterval(hookRfb, 500);      // UI.rfb is made (again) on every connect

async function readAllowed() {
    try {
        const p = await navigator.permissions.query({ name: 'clipboard-read' });
        return p.state === 'granted';
    } catch (err) {
        return false;           // no such permission here (Safari, Firefox)
    }
}

async function syncFromHost() {
    const rfb = UI.rfb;
    if (!rfb) return;
    if (pendingWrite !== null) {
        writeHost(pendingWrite);
        return;                 // the container's copy is the newer one
    }
    if (!navigator.clipboard || !navigator.clipboard.readText || !(await readAllowed())) return;
    try {
        const text = await navigator.clipboard.readText();
        if (text && text !== lastText) {
            lastText = text;
            rfb.clipboardPasteFrom(text);
        }
    } catch (err) {
        // not focused after all, or refused
    }
}
window.addEventListener('focus', () => { setTimeout(syncFromHost, 50); });
document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') setTimeout(syncFromHost, 50);
});

// KEYS from a Mac's browser. Xvnc takes each key by its place (RawKeyboard, from the key's code),
// so the codes must be right:
// - The key left of 1 and the ISO key (left of Z, Swiss/German <) come with each other's codes on
//   ISO keyboards in some browsers (macOS swaps them; Chrome passes that on). Which is which, by
//   the character, as the agent does natively (Layouts.macBackQuotePosition): § ° ± ¶ • ` ~ ^ ¬ and
//   dead keys (German ^) are left of 1, anything else is the ISO key.
// - macOS sends no key release for a key pressed with Command held: the remote kept it pressed
//   (with Alt and Command swapped, after Cmd+C: C repeating). Released when Command goes up.
// - In fullscreen (noVNC's button), the keyboard is locked to the page where the browser can
//   (Chrome, Edge: Keyboard Lock): Cmd+W, Cmd+T and the like go to the remote; hold Esc to leave.
const MAC = /mac/i.test(navigator.platform || '');
const LEFT_OF_1 = '§°±¶•`~^¬';
const fixedCode = new Map();    // original code -> code sent, from keydown to keyup
const heldWithMeta = new Map(); // code -> target, pressed with Command, no release seen yet

function redispatch(e, code) {
    const copy = new KeyboardEvent(e.type, {
        key: e.key, code: code, location: e.location, repeat: e.repeat,
        ctrlKey: e.ctrlKey, altKey: e.altKey, shiftKey: e.shiftKey, metaKey: e.metaKey,
        bubbles: true, cancelable: true,
    });
    copy.keypastaCopy = true;
    stop(e);
    e.target.dispatchEvent(copy);
}

function isoFix(e) {
    if (e.keypastaCopy) return false;
    if (e.type === 'keydown' && (e.code === 'Backquote' || e.code === 'IntlBackslash')) {
        const want = (e.key === 'Dead' || LEFT_OF_1.includes(e.key)) ? 'Backquote' : 'IntlBackslash';
        fixedCode.set(e.code, want);
        if (want !== e.code) {
            redispatch(e, want);
            return true;
        }
    } else if (e.type === 'keyup' && fixedCode.has(e.code)) {
        const want = fixedCode.get(e.code);
        fixedCode.delete(e.code);
        if (want !== e.code) {
            redispatch(e, want);
            return true;
        }
    }
    return false;
}

if (MAC) {
    window.addEventListener('keydown', (e) => {
        if (isoFix(e)) return;
        if (e.metaKey && e.key !== 'Meta' && !e.repeat) heldWithMeta.set(e.code, e.target);
    }, true);
    window.addEventListener('keyup', (e) => {
        if (isoFix(e)) return;
        heldWithMeta.delete(e.code);
        if (e.key === 'Meta' && !e.keypastaCopy) {
            for (const [code, target] of heldWithMeta) {
                const up = new KeyboardEvent('keyup', { code: code, key: 'Unidentified', bubbles: true, cancelable: true });
                up.keypastaCopy = true;
                target.dispatchEvent(up);
            }
            heldWithMeta.clear();
        }
    }, true);
}

document.addEventListener('fullscreenchange', () => {
    if (!navigator.keyboard || !navigator.keyboard.lock) return;
    if (document.fullscreenElement) navigator.keyboard.lock().catch(() => {});
    else navigator.keyboard.unlock();
});

console.info('KeyPasta: paste hotkey ' + spec + ' with this computer\'s clipboard');
