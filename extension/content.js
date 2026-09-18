/* 校园网门户自动登录 —— 内容脚本
 * 只在 URL 命中「门户特征」且页面存在密码框时才动作，避免误填其他网站的登录框。
 * 每个标签页每次会话最多尝试 2 次，防止死循环。
 */
(function () {
  'use strict';

  var DEFAULTS = {
    enabled: true,
    urlPatterns: ['portal', 'wlan', 'unicom', '10010', 'cucc', 'edu\\.cn', '10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}', '192\\.168\\.\\d{1,3}\\.\\d{1,3}', '172\\.(1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3}'],
    username: '',
    password: '',
    usernameSelectors: ['input[name*="user" i]', 'input[id*="user" i]', 'input[name*="account" i]', 'input[name*="name" i]', 'input[type="text"]'],
    passwordSelectors: ['input[type="password"]'],
    submitSelectors: ['input[type="submit"]', 'button[type="submit"]', 'button[id*="login" i]', 'button[name*="login" i]', 'input[id*="login" i]', 'a[id*="login" i]', 'button[id*="connect" i]'],
    agreeSelectors: ['input[type="checkbox"][id*="agree" i]', 'input[type="checkbox"][name*="agree" i]', 'input[type="checkbox"][id*="protocol" i]'],
    autoSubmit: true,
    delayMs: 800,
    maxAttempts: 2
  };

  var KEY = 'unicomAutoLoginTries';

  function tries() {
    var n = 0;
    try { n = parseInt(sessionStorage.getItem(KEY) || '0', 10) || 0; } catch (e) { n = 0; }
    return n;
  }
  function bumpTries() {
    try { sessionStorage.setItem(KEY, String(tries() + 1)); } catch (e) { }
  }

  function matches(url, patterns) {
    for (var i = 0; i < patterns.length; i++) {
      var p = patterns[i];
      if (!p) { continue; }
      try { if (new RegExp(p, 'i').test(url)) { return true; } } catch (e) { }
    }
    return false;
  }

  function visible(el) {
    if (!el) { return false; }
    if (el.disabled || el.readOnly) { return false; }
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function pick(selectors, root) {
    for (var i = 0; i < selectors.length; i++) {
      var list;
      try { list = (root || document).querySelectorAll(selectors[i]); } catch (e) { continue; }
      for (var j = 0; j < list.length; j++) {
        if (visible(list[j])) { return list[j]; }
      }
    }
    return null;
  }

  function fill(el, value) {
    if (!el || !value) { return false; }
    el.focus();
    el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.blur();
    return true;
  }

  function run(settings) {
    if (!settings.enabled) { return false; }
    if (tries() >= settings.maxAttempts) { return false; }
    if (!matches(location.href, settings.urlPatterns)) { return false; }

    var pwd = pick(settings.passwordSelectors);
    if (!pwd) { return false; }               // 页面没有密码框，不动
    if (!settings.username || !settings.password) { return false; }

    var user = pick(settings.usernameSelectors, pwd.form || document);
    var okUser = fill(user, settings.username);
    var okPwd = fill(pwd, settings.password);
    if (!okUser && !okPwd) { return false; }

    var agree = pick(settings.agreeSelectors, pwd.form || document);
    if (agree && !agree.checked) { agree.click(); }

    bumpTries();
    if (!settings.autoSubmit) { return true; }

    var button = pick(settings.submitSelectors, pwd.form || document);
    setTimeout(function () {
      if (button) { button.click(); }
      else if (pwd.form) {
        try { pwd.form.submit(); } catch (e) { }
      }
    }, 300);
    return true;
  }

  function start() {
    try {
      chrome.storage.local.get(DEFAULTS, function (items) {
        var settings = {};
        for (var k in DEFAULTS) { settings[k] = (items && items[k] !== undefined) ? items[k] : DEFAULTS[k]; }
        var attempts = 0;
        (function tick() {
          attempts++;
          if (run(settings)) { return; }
          if (attempts < 10) { setTimeout(tick, settings.delayMs); }
        })();
      });
    } catch (e) { /* 扩展上下文失效时静默退出 */ }
  }

  start();
})();
