/* Runs in an opaque-origin frame, with no storage, navigation or data-network permission. */
(function () {
  'use strict';
  var token = null,
    owner = null,
    origin = null,
    renderer = null,
    busy = false,
    closed = false,
    canvas = document.getElementById('canvas');
  // Browsers may suspend rAF in a clipped near-viewport frame. Bound that wait
  // without changing the parent page's scheduler or retaining an idle loop.
  var nativeFrame = window.requestAnimationFrame.bind(window),
    nativeCancel = window.cancelAnimationFrame.bind(window),
    frames = new Map(),
    serial = 0;
  window.requestAnimationFrame = function (callback) {
    var id = ++serial,
      nativeId,
      timer;
    function run(time) {
      if (!frames.has(id)) return;
      frames.delete(id);
      nativeCancel(nativeId);
      clearTimeout(timer);
      if (!closed) callback(time);
    }
    nativeId = nativeFrame(run);
    timer = setTimeout(function () {
      run(performance.now());
    }, 100);
    frames.set(id, { nativeId: nativeId, timer: timer });
    return id;
  };
  window.cancelAnimationFrame = function (id) {
    var entry = frames.get(id);
    if (entry) {
      nativeCancel(entry.nativeId);
      clearTimeout(entry.timer);
      frames.delete(id);
    }
  };
  function post(data) {
    if (!closed && owner) owner.postMessage(Object.assign({ token: token }, data), origin);
  }
  function boundedSnapshot() {
    var value = renderer.snapshot(),
      encoded = JSON.stringify(value);
    return encoded.length * 2 <= 512 * 1024 ? value : null;
  }
  function snapshot() {
    if (renderer)
      try {
        post({ type: 'cache', cache: boundedSnapshot() });
      } catch (_) {}
  }
  async function load(kind) {
    var url = window.LegnaDiagramAssets && window.LegnaDiagramAssets[kind];
    if (!url) throw Error('format');
    await new Promise(function (resolve, reject) {
      var script = document.createElement('script');
      script.src = url;
      script.onload = resolve;
      script.onerror = reject;
      document.head.appendChild(script);
    });
  }
  window.addEventListener('message', async function (event) {
    var data = event.data;
    if (event.source !== parent || parent === window || !data) return;
    if (!token) {
      if (
        data.type !== 'render' ||
        typeof data.token !== 'string' ||
        data.token.length > 160 ||
        !['mermaid', 'markmap'].includes(data.kind) ||
        typeof data.source !== 'string'
      )
        return;
      token = data.token;
      owner = event.source;
      origin = event.origin;
      try {
        if (data.source.length > 16384 || new TextEncoder().encode(data.source).length > 16384 || data.source.split('\n').length > 500)
          throw Error('limit');
        if (!data.source.trim()) throw Error('format');
        document.documentElement.dataset.theme = data.dark ? 'dark' : 'light';
        document.documentElement.lang = typeof data.language === 'string' && /^[a-zA-Z-]{2,20}$/.test(data.language) ? data.language : 'en';
        canvas.setAttribute('aria-label', typeof data.label === 'string' ? data.label.slice(0, 80) : 'Diagram');
        await load(data.kind === 'mermaid' && data.cache?.kind === 'mermaid' ? 'cached-svg' : data.kind);
        if (closed) return;
        post({ type: 'rendering' });
        renderer = await window.LegnaDiagramRenderer({
          source: data.source,
          cache: data.cache,
          dark: !!data.dark,
          container: canvas,
          changed: snapshot
        });
        if (closed) {
          renderer.close();
          return;
        }
        post({ type: 'ready', height: renderer.height, cache: boundedSnapshot() });
      } catch (error) {
        canvas.replaceChildren();
        post({ type: 'error', error: error?.message === 'limit' ? 'limit' : 'format' });
      }
      return;
    }
    if (event.source !== owner || event.origin !== origin || data.token !== token || data.type !== 'action' || !renderer || busy) return;
    if (!['fit', 'zoomIn', 'zoomOut', 'expand', 'collapse'].includes(data.action)) return;
    busy = true;
    try {
      await renderer.action(data.action);
      snapshot();
    } catch (_) {
      post({ type: 'error', error: 'format' });
    } finally {
      busy = false;
    }
  });
  window.addEventListener('pagehide', function () {
    closed = true;
    frames.forEach(function (entry, id) {
      window.cancelAnimationFrame(id);
    });
    if (renderer) renderer.close();
    renderer = null;
  });
})();
