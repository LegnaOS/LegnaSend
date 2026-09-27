/* Direction panes stay mounted: switching never aborts an approved upload/download. */
(function (root) {
  'use strict';
  function init() {
    var selected = 'download', frames = {}, status = null, stopped = false, timer = null, request = null;
    var labels, language = document.getElementById('web-language');
    function text(id, value) { document.getElementById(id).textContent = value; }
    function renderLocale() {
      var i18n = root.LegnaWebUI.localize({}), locale = document.documentElement.lang; labels = i18n.webUi; language.value = locale;
      root.LegnaWebUI.apply('download', labels);
      text('tab-download', labels.takeFiles); text('tab-upload', labels.sendFiles);
      text('workspace-empty', labels.noSharedFiles); text('workspace-disabled', labels.uploadDisabled);
      render();
      Object.keys(frames).forEach(function (name) { frames[name].contentWindow.postMessage({ type: 'legna-locale', locale: locale }, root.location.origin); });
    }
    function frame(name) {
      if (frames[name]) return;
      var node = document.createElement('iframe'), query = new URLSearchParams(root.location.search);
      query.set('workspace', '1'); node.src = '/' + name + '?' + query.toString();
      node.title = name === 'download' ? labels.takeFiles : labels.sendFiles;
      node.addEventListener('load', function () { node.contentWindow.postMessage({ type: 'legna-locale', locale: document.documentElement.lang }, root.location.origin); });
      frames[name] = node; document.getElementById('pane-' + name).appendChild(node);
    }
    function render() {
      if (!labels) return;
      ['download', 'upload'].forEach(function (name) {
        var active = selected === name, tab = document.getElementById('tab-' + name);
        tab.setAttribute('aria-selected', String(active)); tab.tabIndex = active ? 0 : -1;
        document.getElementById('pane-' + name).hidden = !active;
      });
      text('workspace-state', !status ? labels.workspaceLoading : status.allowUpload ? labels.uploadAllowed : labels.uploadDisabled);
      document.getElementById('workspace-empty').hidden = !!frames.download || !!(status && status.fileCount);
      document.getElementById('workspace-disabled').hidden = !!frames.upload || !!(status && status.allowUpload);
      if (status && selected === 'download' && status.fileCount) frame('download');
      if (status && selected === 'upload' && status.allowUpload) frame('upload');
    }
    function select(name) { selected = name; render(); }
    function applyStatus(next) {
      status = next; render();
      Object.keys(frames).forEach(function (name) { frames[name].contentWindow.postMessage({ type: 'legna-workspace', status: status }, root.location.origin); });
    }
    async function refresh() {
      if (stopped || request) return;
      request = new AbortController();
      try {
        var response = await fetch('/web-status.json', { cache: 'no-store', signal: request.signal });
        if (!response.ok) throw new Error('Workspace unavailable');
        var next = await response.json(); if (!stopped) applyStatus(next);
      } catch (_) { if (!stopped) text('workspace-state', labels.connectionLost); }
      finally { request = null; if (!stopped) timer = setTimeout(refresh, 3000); }
    }
    ['download', 'upload'].forEach(function (name) {
      document.getElementById('tab-' + name).addEventListener('click', function () { select(name); });
    });
    document.getElementById('workspace-tabs').addEventListener('keydown', function (event) {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault(); select(event.key === 'Home' ? 'download' : event.key === 'End' ? 'upload' : selected === 'download' ? 'upload' : 'download');
      document.getElementById('tab-' + selected).focus();
    });
    root.LegnaWebUI.onLanguageChange = renderLocale;
    root.addEventListener('pagehide', function () { stopped = true; clearTimeout(timer); if (request) request.abort(); });
    renderLocale(); refresh();
  }
  if (typeof module === 'object' && module.exports) module.exports = { init: init };
  else init();
})(typeof window !== 'undefined' ? window : globalThis);
