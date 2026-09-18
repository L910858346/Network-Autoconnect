var DEFAULTS = {
  enabled: true,
  username: '',
  password: '',
  urlPatterns: ['portal', 'wlan', 'unicom', '10010', 'cucc', 'edu\\.cn', '10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}', '192\\.168\\.\\d{1,3}\\.\\d{1,3}', '172\\.(1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3}'],
  submitSelectors: ['input[type="submit"]', 'button[type="submit"]', 'button[id*="login" i]', 'button[name*="login" i]', 'input[id*="login" i]', 'a[id*="login" i]', 'button[id*="connect" i]'],
  autoSubmit: true
};

function $(id) { return document.getElementById(id); }

function load() {
  chrome.storage.local.get(DEFAULTS, function (items) {
    $('enabled').checked = items.enabled !== false;
    $('autoSubmit').checked = items.autoSubmit !== false;
    $('username').value = items.username || '';
    $('password').value = items.password || '';
    $('urlPatterns').value = (items.urlPatterns || []).join('\n');
    $('submitSelectors').value = (items.submitSelectors || []).join('\n');
  });
}

function lines(id) {
  return $(id).value.split('\n').map(function (s) { return s.trim(); }).filter(Boolean);
}

$('save').addEventListener('click', function () {
  chrome.storage.local.set({
    enabled: $('enabled').checked,
    autoSubmit: $('autoSubmit').checked,
    username: $('username').value.trim(),
    password: $('password').value,
    urlPatterns: lines('urlPatterns'),
    submitSelectors: lines('submitSelectors')
  }, function () {
    $('msg').textContent = '已保存';
    setTimeout(function () { $('msg').textContent = ''; }, 1500);
  });
});

load();
