/* Bounded, viewport-driven diagram frames. No source or credentials in frame URLs. */
(function (root) {
  'use strict';
  var MAX_SOURCE = 16384,
    MAX_BLOCKS = 64,
    MAX_FRAMES = 2,
    MAX_CACHE = 4 * 1024 * 1024;
  var defaults = {
    diagramQueued: 'Diagram · loads near the viewport',
    diagramLoading: 'Rendering diagram…',
    diagramReady: 'Diagram',
    diagramFailed: 'This diagram could not be rendered. Read its source or try again.',
    diagramLimit: 'This diagram exceeds the preview limit. Its source is still available.',
    diagramSource: 'Source',
    diagramRender: 'Diagram',
    diagramRetry: 'Try again',
    diagramFit: 'Fit',
    diagramZoomIn: 'Zoom in',
    diagramZoomOut: 'Zoom out',
    diagramExpand: 'Expand all',
    diagramCollapse: 'Collapse branches',
    diagramHint: 'Drag to pan. Use buttons or Ctrl/⌘ + wheel to zoom.',
    diagramUnavailable: 'Diagram rendering is unavailable in this browser. The source is shown.'
  };
  function kind(language) {
    var value = String(language || '')
      .trim()
      .split(/\s/)[0]
      .toLowerCase();
    return value === 'mermaid' ? 'mermaid' : ['markmap', 'markedmap'].includes(value) ? 'markmap' : null;
  }
  function Manager(options) {
    this.container = options.container;
    this.labels = Object.assign({}, defaults, options.labels);
    this.blocks = [];
    this.cache = new Map();
    this.cacheBytes = 0;
    this.closed = false;
    this.active = false;
    this.resumeTimer = null;
    this.needsYield = false;
    this.frames = 0;
    var self = this;
    this.observer = root.IntersectionObserver
      ? new root.IntersectionObserver(
          function (entries) {
            entries.forEach(function (e) {
              var b = self.blocks.find(function (b) {
                return b.element === e.target;
              });
              if (b) b.near = e.isIntersecting;
            });
            self.schedule();
          },
          { root: this.container, rootMargin: '180px 0px' }
        )
      : null;
    this.onMessage = function (e) {
      self.message(e);
    };
    root.addEventListener('message', this.onMessage);
    this.onVisibility = function () {
      self.schedule();
    };
    root.document.addEventListener('visibilitychange', this.onVisibility);
    this.onTheme = function () {
      self.blocks.forEach(function (b) {
        self.release(b);
      });
      self.cache.clear();
      self.cacheBytes = 0;
      self.schedule();
    };
    this.theme = !root.LegnaTheme && root.matchMedia ? root.matchMedia('(prefers-color-scheme: dark)') : null;
    root.addEventListener('legna-theme-change', this.onTheme);
    if (this.theme && this.theme.addEventListener) this.theme.addEventListener('change', this.onTheme);
  }
  Manager.prototype.block = function (language, source, cacheKey) {
    var self = this,
      doc = root.document,
      labels = this.labels;
    if (this.blocks.length >= MAX_BLOCKS) {
      var fallback = doc.createElement('pre');
      fallback.className = 'diagram-source';
      fallback.textContent = this.labels.diagramLimit + '\n' + source;
      return fallback;
    }
    function el(tag, cls, text) {
      var n = doc.createElement(tag);
      n.className = cls || '';
      if (text != null) n.textContent = text;
      return n;
    }
    var element = el('section', 'diagram-block'),
      toolbar = el('div', 'diagram-toolbar'),
      name = el('strong', 'diagram-name', kind(language) === 'mermaid' ? 'Mermaid' : 'Markmap'),
      status = el('p', 'diagram-status'),
      stage = el('div', 'diagram-stage'),
      pre = el('pre', 'diagram-source'),
      code = el('code', '', source);
    var b = {
      element: element,
      cacheKey: cacheKey,
      toolbar: toolbar,
      status: status,
      stage: stage,
      source: source,
      kind: kind(language),
      near: false,
      manual: false,
      frame: null,
      token: null,
      error: null,
      ready: false,
      sourceView: false,
      height: 240
    };
    pre.appendChild(code);
    pre.hidden = true;
    status.setAttribute('role', 'status');
    element.dataset.kind = b.kind;
    function button(text, action) {
      var n = el('button', '', text);
      n.type = 'button';
      n.addEventListener('click', action);
      toolbar.appendChild(n);
      return n;
    }
    toolbar.appendChild(name);
    b.toggle = button(labels.diagramSource, function () {
      b.sourceView = !b.sourceView;
      pre.hidden = !b.sourceView;
      stage.hidden = b.sourceView;
      b.toggle.textContent = b.sourceView ? labels.diagramRender : labels.diagramSource;
      if (b.sourceView) self.release(b);
      self.schedule();
    });
    b.retry = button(labels.diagramRetry, function () {
      b.error = null;
      b.manual = true;
      pre.hidden = true;
      b.sourceView = false;
      stage.hidden = false;
      b.toggle.textContent = labels.diagramSource;
      self.schedule();
    });
    b.retry.hidden = true;
    b.controls = [];
    [
      ['diagramZoomOut', 'zoomOut', '−'],
      ['diagramZoomIn', 'zoomIn', '+'],
      ['diagramFit', 'fit']
    ]
      .concat(
        b.kind === 'markmap'
          ? [
              ['diagramCollapse', 'collapse'],
              ['diagramExpand', 'expand']
            ]
          : []
      )
      .forEach(function (item) {
        var n = button(item[2] || labels[item[0]], function () {
          self.send(b, { type: 'action', action: item[1] });
        });
        n.title = labels[item[0]];
        n.setAttribute('aria-label', labels[item[0]]);
        n.disabled = true;
        b.controls.push(n);
      });
    var hint = el('p', 'diagram-hint', labels.diagramHint);
    stage.style.height = b.height + 'px';
    element.append(toolbar, status, stage, pre, hint);
    b.pre = pre;
    if (
      !b.kind ||
      source.length > MAX_SOURCE ||
      new TextEncoder().encode(source).length > MAX_SOURCE ||
      source.split('\n').length > 500 ||
      this.blocks.length >= MAX_BLOCKS
    ) {
      b.error = 'limit';
      pre.hidden = false;
      stage.hidden = true;
    } else if (!root.IntersectionObserver || !root.postMessage) {
      b.error = 'unavailable';
      pre.hidden = false;
      stage.hidden = true;
    }
    this.blocks.push(b);
    if (this.observer && !b.error) this.observer.observe(element);
    this.status(b);
    return element;
  };
  Manager.prototype.status = function (b) {
    var label =
      b.error === 'limit'
        ? 'diagramLimit'
        : b.error === 'unavailable'
          ? 'diagramUnavailable'
          : b.error
            ? 'diagramFailed'
            : b.ready
              ? 'diagramReady'
              : b.frame
                ? 'diagramLoading'
                : 'diagramQueued';
    b.stage.hidden = !!b.error || b.sourceView;
    b.status.textContent = this.labels[label];
    b.element.dataset.state = b.error ? 'error' : b.ready ? 'ready' : b.frame ? 'loading' : 'idle';
    b.controls.forEach(function (n) {
      n.disabled = !b.ready;
    });
    b.retry.hidden = !b.error || b.error === 'limit' || b.error === 'unavailable';
  };
  Manager.prototype.put = function (b, value) {
    var text;
    try {
      text = JSON.stringify(value);
    } catch (_) {
      return;
    }
    if (!text || text.length * 2 > 512 * 1024) return;
    var old = this.cache.get(b.cacheKey || b);
    if (old) this.cacheBytes -= old.length * 2;
    this.cache.delete(b.cacheKey || b);
    this.cache.set(b.cacheKey || b, text);
    this.cacheBytes += text.length * 2;
    while (this.cacheBytes > MAX_CACHE) {
      var key = this.cache.keys().next().value;
      this.cacheBytes -= this.cache.get(key).length * 2;
      this.cache.delete(key);
    }
  };
  Manager.prototype.release = function (b) {
    clearTimeout(b.deadline);
    b.deadline = null;
    if (b.frame) {
      b.token = null;
      b.frame.remove();
      b.frame = null;
      this.frames--;
      this.needsYield = true;
    }
    b.ready = false;
    this.status(b);
  };
  // A virtual Markdown block leaves the DOM; retain only its keyed, bounded result.
  Manager.prototype.detach = function (parent) {
    var self = this;
    this.blocks = this.blocks.filter(function (b) {
      if (!parent.contains(b.element)) return true;
      self.release(b);
      if (self.observer) self.observer.unobserve(b.element);
      return false;
    });
  };
  Manager.prototype.send = function (b, message) {
    if (b.frame && b.frame.contentWindow) b.frame.contentWindow.postMessage(Object.assign({ token: b.token }, message), '*');
  };
  Manager.prototype.deadline = function (b, ms) {
    var self = this,
      frame = b.frame;
    clearTimeout(b.deadline);
    b.deadline = setTimeout(function () {
      if (b.frame === frame) {
        self.release(b);
        b.error = 'timeout';
        b.pre.hidden = false;
        self.status(b);
        self.schedule();
      }
    }, ms);
  };
  Manager.prototype.start = function (b) {
    var self = this,
      frame = root.document.createElement('iframe');
    b.manual = false;
    b.frame = frame;
    b.ready = false;
    this.frames++;
    var random = new Uint32Array(4);
    if (root.crypto && root.crypto.getRandomValues) root.crypto.getRandomValues(random);
    else random[0] = Math.random() * 0xffffffff;
    b.token = Array.from(random).join('-') + '-' + Date.now();
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.referrerPolicy = 'no-referrer';
    frame.title = b.kind === 'mermaid' ? 'Mermaid' : 'Markmap';
    frame.src = '/assets/diagram-frame.html';
    frame.addEventListener('load', function () {
      if (b.frame !== frame) return;
      var cached = self.cache.get(b.cacheKey || b);
      if (cached) {
        self.cache.delete(b.cacheKey || b);
        self.cache.set(b.cacheKey || b, cached);
      }
      self.send(b, {
        type: 'render',
        label: self.labels.diagramReady,
        language: root.document.documentElement.lang || 'en',
        source: b.source,
        kind: b.kind,
        dark: root.LegnaTheme ? root.LegnaTheme.resolved() === 'dark' : !!(self.theme && self.theme.matches),
        cache: cached ? JSON.parse(cached) : null
      });
    });
    b.stage.style.height = b.height + 'px';
    b.stage.replaceChildren(frame);
    this.deadline(b, 60000);
    this.status(b);
  };
  Manager.prototype.message = function (event) {
    if (this.closed || event.origin !== 'null') return;
    var b = this.blocks.find(function (b) {
      return b.frame && b.frame.contentWindow === event.source;
    });
    var data = event.data;
    if (!b || !data || data.token !== b.token) return;
    if (data.type === 'rendering' && !b.ready) {
      this.deadline(b, 12000);
      return;
    }
    if (data.type === 'ready') {
      clearTimeout(b.deadline);
      b.ready = true;
      b.error = null;
      if (Number.isFinite(data.height)) {
        b.height = Math.max(170, Math.min(320, data.height));
        b.stage.style.height = b.height + 'px';
      }
      if (data.cache) this.put(b, data.cache);
      this.status(b);
    } else if (data.type === 'cache' && b.ready) {
      this.put(b, data.cache);
    } else if (data.type === 'error') {
      if (this.cache.has(b.cacheKey || b)) {
        this.cacheBytes -= this.cache.get(b.cacheKey || b).length * 2;
        this.cache.delete(b.cacheKey || b);
      }
      this.release(b);
      b.error = data.error === 'limit' ? 'limit' : 'format';
      b.pre.hidden = false;
      this.status(b);
      this.schedule();
    }
  };
  Manager.prototype.schedule = function () {
    var self = this;
    if (this.closed) return;
    if (!this.active || root.document.hidden) {
      clearTimeout(this.resumeTimer);
      this.resumeTimer = null;
      this.blocks.forEach(function (b) {
        self.release(b);
      });
      return;
    }
    if (this.resumeTimer) return;
    var candidates = this.blocks.filter(function (b) {
      return (b.near || b.manual) && !b.sourceView && !b.error;
    });
    // Prioritize actual visibility over the small prefetch margin.
    var rect = this.container.getBoundingClientRect();
    candidates.sort(function (a, b) {
      function score(n) {
        var r = n.element.getBoundingClientRect();
        return r.bottom >= rect.top && r.top <= rect.bottom ? 0 : 1;
      }
      return score(a) - score(b);
    });
    var selected = candidates.slice(0, MAX_FRAMES);
    this.blocks.forEach(function (b) {
      if (!selected.includes(b)) self.release(b);
    });
    // Let detached frame contexts and cancelled script loads settle before replacements.
    if (this.needsYield) {
      this.resumeTimer = setTimeout(function () {
        self.resumeTimer = null;
        self.needsYield = false;
        self.schedule();
      }, 32);
      return;
    }
    selected.forEach(function (b) {
      if (!b.frame) self.start(b);
    });
  };
  Manager.prototype.setActive = function (active) {
    this.active = active;
    this.schedule();
  };
  Manager.prototype.close = function () {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.resumeTimer);
    this.resumeTimer = null;
    var self = this;
    this.blocks.forEach(function (b) {
      self.release(b);
    });
    if (this.observer) this.observer.disconnect();
    root.removeEventListener('message', this.onMessage);
    root.document.removeEventListener('visibilitychange', this.onVisibility);
    root.removeEventListener('legna-theme-change', this.onTheme);
    if (this.theme && this.theme.removeEventListener) this.theme.removeEventListener('change', this.onTheme);
    this.cache.clear();
    this.cacheBytes = 0;
    this.blocks = [];
  };
  var api = {
    Manager: Manager,
    kind: kind,
    defaults: defaults,
    limits: { source: MAX_SOURCE, blocks: MAX_BLOCKS, frames: MAX_FRAMES, cache: MAX_CACHE }
  };
  if (typeof module === 'object') module.exports = api;
  else root.LegnaDiagrams = api;
})(typeof globalThis === 'object' ? globalThis : this);
