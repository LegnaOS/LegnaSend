/* One origin-wide preference for every sharing page. Never reload a transfer frame. */
(function (root) {
  'use strict';
  var doc = root.document, key = 'legnasend.webTheme', mode = 'system';
  var media = root.matchMedia ? root.matchMedia('(prefers-color-scheme: dark)') : null;
  var controls = [], observer;
  function valid(value) { return value === 'light' || value === 'dark' || value === 'system'; }
  try { var saved = root.localStorage.getItem(key); if (valid(saved)) mode = saved; } catch (_) {}
  // Also works when third-party/embedded storage is unavailable.
  try { if (root.parent !== root && root.parent.location.origin === root.location.origin && root.parent.LegnaTheme) mode = root.parent.LegnaTheme.preference(); } catch (_) {}
  function resolved() { return mode === 'system' ? media && media.matches ? 'dark' : 'light' : mode; }
  function notifyFrames() {
    doc.querySelectorAll('iframe').forEach(function (frame) {
      try { frame.contentWindow.postMessage({ type: 'legna-theme', preference: mode }, root.location.origin); } catch (_) {}
    });
  }
  function apply() {
    var next = resolved(), previous = doc.documentElement.getAttribute('data-theme');
    doc.documentElement.setAttribute('data-theme', next);
    doc.documentElement.setAttribute('data-theme-preference', mode);
    controls.forEach(function (control) { control.value = mode; });
    if (previous !== next) root.dispatchEvent(new CustomEvent('legna-theme-change', { detail: { theme: next } }));
    notifyFrames();
  }
  function set(value, persist) {
    if (!valid(value)) return;
    mode = value;
    if (persist) { try { root.localStorage.setItem(key, mode); } catch (_) {} }
    apply();
  }
  var fallback = { theme: 'Appearance', themeSystem: 'System', themeLight: 'Light', themeDark: 'Dark' };
  function localize() {
    var locale = doc.documentElement.lang || 'en';
    var labels = (root.LegnaWebLocales && root.LegnaWebLocales[locale] || {}).webUi || fallback;
    controls.forEach(function (control) {
      control.setAttribute('aria-label', labels.theme || fallback.theme);
      control.title = labels.theme || fallback.theme;
      Array.from(control.options).forEach(function (option) { var name = 'theme' + option.value.charAt(0).toUpperCase() + option.value.slice(1); option.textContent = labels[name] || fallback[name]; });
    });
  }
  function mount() {
    doc.querySelectorAll('[data-theme-control]').forEach(function (host) {
      var select = doc.createElement('select'); select.className = 'theme-selector';
      ['system', 'light', 'dark'].forEach(function (value) { var option = doc.createElement('option'); option.value = value; select.appendChild(option); });
      select.value = mode; select.addEventListener('change', function () { set(select.value, true); });
      controls.push(select); host.appendChild(select);
    });
    localize();
    if (root.MutationObserver) { observer = new MutationObserver(localize); observer.observe(doc.documentElement, { attributes: true, attributeFilter: ['lang'] }); }
  }
  function systemChanged() { if (mode === 'system') apply(); }
  if (media && media.addEventListener) media.addEventListener('change', systemChanged);
  else if (media && media.addListener) media.addListener(systemChanged);
  root.addEventListener('storage', function (event) { if (event.key === key) set(event.newValue == null ? 'system' : event.newValue, false); });
  root.addEventListener('message', function (event) {
    if (event.origin === root.location.origin && event.source === root.parent && root.parent !== root && event.data && event.data.type === 'legna-theme') set(event.data.preference, false);
  });
  root.LegnaTheme = { set: function (value) { set(value, true); }, preference: function () { return mode; }, resolved: resolved, localize: localize };
  apply();
  if (doc.readyState === 'loading') doc.addEventListener('DOMContentLoaded', mount, { once: true }); else mount();
})(typeof window !== 'undefined' ? window : globalThis);
