// ==UserScript==
// @name         Supermicro IPMI / ATEN BMC: Login fix
// @description  Restore password autofilling capabilities that Supermicro/ATEN cripple more and more with each BMC generation. Part of iKVM-KeyPasta: https://github.com/Tabiskabis/iKVM-KeyPasta
// @version      7
// @author       Tabiskabis
// @namespace    Tabiskabis.iKVM-KeyPasta
// @homepageURL  https://github.com/Tabiskabis/iKVM-KeyPasta
// @updateURL    https://raw.githubusercontent.com/Tabiskabis/iKVM-KeyPasta/main/login-fix.user.js
// @downloadURL  https://raw.githubusercontent.com/Tabiskabis/iKVM-KeyPasta/main/login-fix.user.js
// @grant        none
// @include      /^https:\/\/(?:\d{1,3}\.){3}\d{1,3}(?:\/|$)/
// @include      /^https:\/\/\[?[0-9A-Fa-f:]+\]?(?:\/|$)/
// @match        https://*.ipv6-literal.net/
// Your BMCs by name: add your own URLs in the extension, not here (an update replaces this file):
//   Tampermonkey: the script's Settings tab, "User matches", e.g. https://*-ipmi.example.com/
//   Violentmonkey: the script's Settings, "@match rules", one per line, "Keep original" on.
// @icon         data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIHZpZXdCb3g9IjAgMCAxMDI0IDEwMjQiPjxkZWZzPjxwYXRoIGlkPSJmIiBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik02OTIuNSAyMjAuNkM1NzUuMyAxNTQuOCA0MjguMyAxNTQuMyAzMTEuOCAxODQuMkwzMTEuOCAxMzMuN0wyNjEuMiAxMzMuN0wyNjEuMiAxOTkuNkMyMzkuNCAyMDcuNSAyMTkuNCAyMTYuMyAyMDEuNSAyMjZDMjAxLjUgMjI2IDIyNi43IDIyMi45IDI2MS4yIDIyNUwyNjEuMiA2NjYuMUMyMzYgNzA0LjkgMjMwIDc0Mi41IDIzNiA3ODZDMjQyLjYgODM0LjYgMjc5LjMgODY3LjEgMzA4LjIgODkxLjFDMjkxLjEgODQyIDI4OS44IDc5Ny40IDI5NC45IDc3MC41QzMwNC40IDcyMC4xIDMzNCA2ODMuOCA0NjEuNSA2NTYuMkM1OTMuOSA2MjcuNyA3NTAuOCA2MTQuNSA4MDIuNiA0ODUuOUM4MjYuMiA0MjcuMiA4NDAuOCAzMDMuOCA2OTIuNSAyMjAuNlpNMzgzLjEgNTUyLjNDMzU0LjcgNTcyLjIgMzMxLjIgNTkwLjggMzExLjcgNjA4LjVMMzExLjcgMjMxLjdDMzUxLjIgMjQwIDM5Mi45IDI1Ny4xIDQyMS43IDI5MC45QzQ5Mi41IDM3NC41IDQ2OC41IDQ5Mi41IDM4My4xIDU1Mi4zWiIvPjwvZGVmcz48dXNlIGhyZWY9IiNmIiBmaWxsPSIjMDAwIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iNzQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48dXNlIGhyZWY9IiNmIiBmaWxsPSIjZmZmIi8+PHBhdGggZmlsbD0iIzAwMCIgZD0iTTYwMC4yIDI2M2g4MS42djk1LjJoOTUuMnY4MS42aC05NS4ydjk1LjJoLTgxLjZ2LTk1LjJoLTk1LjJ2LTgxLjZoOTUuMloiLz48L3N2Zz4K
// ==/UserScript==

function clickFocus() {
  const usernameInput = document.querySelector('[name="name"]');
  usernameInput.click(); // clear input field
  usernameInput.focus();
  console.log('Cleared and focussed username field');
}

if (document.querySelector('title')?.textContent == 'Supermicro BMC Login'
    || document.querySelector('meta[name^="ATEN International Co"]')) {

  console.log('Userscript found IPMI login page -> fixing up form inputs for autocompletion/autotype/autofill ...');

  const usernameInput = document.querySelector('[name="name"]');
  if (!usernameInput) {
    console.log('Could not find username input field');
  } else {
    usernameInput.autocomplete = 'username';
    console.log('Added autocomplete attribute to username input field');

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', clickFocus);
      console.log('Added EventListener DOMContentLoaded');
    } else {
      clickFocus();
    }
  }

  const passwordInput = document.querySelector('[name="pwd"]');
  if (!passwordInput) {
    console.log('Could not find password input field');
  } else {
    passwordInput.type = 'password';
    passwordInput.autocomplete = 'current-password';
    console.log('Added autocomplete attribute to password input field and changed type to password');
  }
}
