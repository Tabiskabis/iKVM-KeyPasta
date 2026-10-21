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
