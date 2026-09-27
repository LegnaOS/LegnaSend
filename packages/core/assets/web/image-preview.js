/* Shared raster-image viewport. Keep the original authorized <img> URL; no Blob/canvas copy. */
(function (root) {
  'use strict';
  var defaults = {
    imageZoomIn: 'Zoom in',
    imageZoomOut: 'Zoom out',
    imageFit: 'Fit',
    imageActual: 'Actual size',
    imageView: 'Image preview',
    imageScale: 'Zoom',
    imageHint: 'Drag to pan. Pinch or Ctrl/⌘ + wheel to zoom. Keyboard: +/−, arrows, 0 to fit, 1 for actual size.'
  };
  function finite(value) {
    return Number.isFinite(value) && value > 0;
  }
  function Geometry(width, height, viewWidth, viewHeight) {
    if (![width, height, viewWidth, viewHeight].every(finite)) throw new Error('dimensions');
    this.width = width;
    this.height = height;
    this.x = 0;
    this.y = 0;
    this.mode = 'fit';
    this.scale = 1;
    this.resize(viewWidth, viewHeight);
  }
  Geometry.prototype.resize = function (width, height) {
    if (!finite(width) || !finite(height)) return;
    this.viewWidth = width;
    this.viewHeight = height;
    this.minimum = Math.min(1, width / this.width, height / this.height);
    this.maximum = 8;
    if (this.mode === 'fit') this.fit();
    else {
      this.scale = Math.max(this.minimum, Math.min(this.maximum, this.scale));
      this.constrain();
    }
  };
  Geometry.prototype.constrain = function () {
    var maxX = Math.max(0, (this.width * this.scale - this.viewWidth) / 2),
      maxY = Math.max(0, (this.height * this.scale - this.viewHeight) / 2);
    this.x = Math.max(-maxX, Math.min(maxX, this.x));
    this.y = Math.max(-maxY, Math.min(maxY, this.y));
  };
  Geometry.prototype.fit = function () {
    this.mode = 'fit';
    this.scale = this.minimum;
    this.x = this.y = 0;
  };
  Geometry.prototype.zoom = function (scale, x, y) {
    if (!finite(scale) || !Number.isFinite(x) || !Number.isFinite(y)) return;
    scale = Math.max(this.minimum, Math.min(this.maximum, scale));
    var factor = scale / this.scale,
      dx = x - this.viewWidth / 2,
      dy = y - this.viewHeight / 2;
    this.x = dx - (dx - this.x) * factor;
    this.y = dy - (dy - this.y) * factor;
    this.scale = scale;
    this.mode = 'custom';
    this.constrain();
  };
  Geometry.prototype.pan = function (x, y) {
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    var previousX = this.x,
      previousY = this.y;
    this.x += x;
    this.y += y;
    this.constrain();
    if (this.x !== previousX || this.y !== previousY) this.mode = 'custom';
  };
  Geometry.prototype.transform = function () {
    return {
      scale: this.scale,
      x: (this.viewWidth - this.width * this.scale) / 2 + this.x,
      y: (this.viewHeight - this.height * this.scale) / 2 + this.y
    };
  };
  function mount(options) {
    var doc = root.document,
      image = options.image,
      labels = Object.assign({}, defaults, options.labels),
      container = options.container;
    var closed = false,
      model = null,
      pointers = new Map(),
      gesture = null,
      listeners = [],
      resizeObserver = null;
    var resolveReady,
      rejectReady,
      settled = false;
    var ready = new Promise(function (resolve, reject) {
      resolveReady = resolve;
      rejectReady = reject;
    });
    ready.catch(function () {});
    function el(tag, cls, text) {
      var n = doc.createElement(tag);
      n.className = cls;
      if (text != null) n.textContent = text;
      return n;
    }
    var wrap = el('div', 'image-preview'),
      toolbar = el('div', 'image-toolbar'),
      stage = el('div', 'image-stage'),
      zoom = el('output', 'image-scale');
    zoom.setAttribute('aria-label', labels.imageScale);
    zoom.setAttribute('aria-live', 'polite');
    stage.tabIndex = 0;
    stage.setAttribute('role', 'region');
    stage.setAttribute('aria-label', labels.imageView + ': ' + (image.alt || ''));
    function on(target, type, fn, opts) {
      target.addEventListener(type, fn, opts);
      listeners.push(function () {
        target.removeEventListener(type, fn, opts);
      });
    }
    function button(text, label, action) {
      var n = el('button', '', text);
      n.type = 'button';
      n.title = label;
      n.setAttribute('aria-label', label);
      n.disabled = true;
      on(n, 'click', action);
      toolbar.appendChild(n);
      return n;
    }
    var minus = button('−', labels.imageZoomOut, function () {
      if (model) change(model.scale / 1.4);
    });
    toolbar.appendChild(zoom);
    var plus = button('+', labels.imageZoomIn, function () {
      if (model) change(model.scale * 1.4);
    });
    var fit = button(labels.imageFit, labels.imageFit, function () {
      if (model) {
        model.fit();
        resetGesture();
        draw();
      }
    });
    var actual = button('1:1', labels.imageActual, function () {
      if (model) change(1);
    });
    var hint = el('p', 'image-hint', labels.imageHint);
    image.draggable = false;
    image.decoding = 'async';
    image.style.maxWidth = 'none';
    image.style.maxHeight = 'none';
    image.style.margin = '0';
    image.style.borderRadius = '0';
    image.style.background = 'transparent';
    image.style.visibility = 'hidden';
    wrap.append(toolbar, stage, hint);
    stage.appendChild(image);
    container.appendChild(wrap);
    function draw() {
      if (closed || !model) return;
      var value = model.transform(),
        percent = model.scale * 100;
      image.style.transform = 'translate3d(' + value.x + 'px,' + value.y + 'px,0) scale(' + value.scale + ')';
      image.style.visibility = 'visible';
      var text = (percent < 1 ? percent.toFixed(2) : percent < 10 ? percent.toFixed(1) : Math.round(percent)) + '%';
      if (zoom.textContent !== text) zoom.textContent = text;
      minus.disabled = model.scale <= model.minimum * (1 + 1e-8);
      plus.disabled = model.scale >= model.maximum;
      fit.disabled = actual.disabled = false;
      stage.dataset.scale = String(value.scale);
      stage.dataset.x = String(value.x);
      stage.dataset.y = String(value.y);
      stage.dataset.mode = model.mode;
      stage.classList.toggle(
        'image-can-pan',
        model.width * model.scale > model.viewWidth + 1 || model.height * model.scale > model.viewHeight + 1
      );
    }
    function size() {
      if (closed || !model) return;
      var width = stage.clientWidth;
      if (width <= 0) return;
      var maximum = Math.max(120, Math.min(480, root.innerHeight * 0.5));
      var height = Math.min(maximum, Math.max(160, model.height * Math.min(1, width / model.width)));
      stage.style.height = Math.round(height) + 'px';
      model.resize(width, stage.clientHeight);
      resetGesture();
      draw();
    }
    async function load() {
      if (closed || !image.naturalWidth || !image.naturalHeight) return;
      try {
        if (image.decode) await image.decode();
      } catch (_) {
        fail();
        return;
      }
      if (closed) return;
      stage.hidden = false;
      model = new Geometry(image.naturalWidth, image.naturalHeight, Math.max(1, stage.clientWidth), Math.max(1, stage.clientHeight));
      image.style.width = image.naturalWidth + 'px';
      image.style.height = image.naturalHeight + 'px';
      size();
      wrap.dataset.state = 'ready';
      settled = true;
      resolveReady();
    }
    function point(event) {
      var box = stage.getBoundingClientRect();
      return { x: event.clientX - box.left, y: event.clientY - box.top };
    }
    function resetGesture() {
      if (!model || !pointers.size) {
        gesture = null;
        return;
      }
      var p = Array.from(pointers.values()).slice(0, 2);
      var center = p.length === 1 ? p[0] : { x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2 };
      gesture = {
        center: center,
        distance: p.length === 1 ? 0 : Math.hypot(p[1].x - p[0].x, p[1].y - p[0].y),
        scale: model.scale,
        x: model.x,
        y: model.y
      };
    }
    function change(scale, position) {
      if (!model) return;
      position = position || { x: model.viewWidth / 2, y: model.viewHeight / 2 };
      model.zoom(scale, position.x, position.y);
      resetGesture();
      draw();
    }
    function toggle(position) {
      if (!model) return;
      if (model.scale > model.minimum * 1.01) {
        model.fit();
        resetGesture();
        draw();
      } else change(Math.max(1, model.minimum * 2), position);
    }
    on(image, 'load', load);
    function releaseCapture(id) {
      try {
        if (stage.hasPointerCapture && stage.hasPointerCapture(id)) stage.releasePointerCapture(id);
      } catch (_) {}
    }
    function clearPointers() {
      pointers.forEach(function (_, id) {
        releaseCapture(id);
      });
      pointers.clear();
      gesture = null;
      stage.classList.remove('image-dragging');
    }
    function fail() {
      if (closed) return;
      model = null;
      clearPointers();
      stage.hidden = true;
      wrap.dataset.state = 'error';
      if (!settled) {
        settled = true;
        rejectReady(new Error('image'));
      }
      [plus, minus, fit, actual].forEach(function (n) {
        n.disabled = true;
      });
    }
    on(image, 'error', fail);
    on(image, 'dragstart', function (e) {
      e.preventDefault();
    });
    on(stage, 'pointerdown', function (e) {
      if (!model || (e.pointerType === 'mouse' && e.button !== 0) || pointers.size >= 2) return;
      stage.focus({ preventScroll: true });
      pointers.set(e.pointerId, point(e));
      try {
        if (stage.setPointerCapture) stage.setPointerCapture(e.pointerId);
      } catch (_) {}
      resetGesture();
      stage.classList.add('image-dragging');
    });
    on(stage, 'pointermove', function (e) {
      if (!model || !pointers.has(e.pointerId) || !gesture) return;
      pointers.set(e.pointerId, point(e));
      var p = Array.from(pointers.values()),
        center = p.length === 1 ? p[0] : { x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2 };
      model.scale = gesture.scale;
      model.x = gesture.x;
      model.y = gesture.y;
      if (p.length === 2 && gesture.distance > 0)
        model.zoom((gesture.scale * Math.hypot(p[1].x - p[0].x, p[1].y - p[0].y)) / gesture.distance, gesture.center.x, gesture.center.y);
      model.pan(center.x - gesture.center.x, center.y - gesture.center.y);
      draw();
    });
    function up(e) {
      if (!pointers.has(e.pointerId)) return;
      pointers.delete(e.pointerId);
      releaseCapture(e.pointerId);
      resetGesture();
      if (!pointers.size) stage.classList.remove('image-dragging');
    }
    on(stage, 'pointerup', up);
    on(stage, 'pointercancel', up);
    on(root, 'pointerup', up);
    on(root, 'pointercancel', up);
    on(stage, 'lostpointercapture', up);
    on(stage, 'dblclick', function (e) {
      e.preventDefault();
      toggle(point(e));
    });
    on(
      stage,
      'wheel',
      function (e) {
        if (!model || !(e.ctrlKey || e.metaKey)) return;
        e.preventDefault();
        change(
          model.scale *
            Math.exp(
              -Math.max(-100, Math.min(100, e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? model.viewHeight : 1))) * 0.005
            ),
          point(e)
        );
      },
      { passive: false }
    );
    on(stage, 'keydown', function (e) {
      if (!model || e.ctrlKey || e.metaKey || e.altKey) return;
      var handled = true;
      if (e.key === '+' || e.key === '=') change(model.scale * 1.4);
      else if (e.key === '-' || e.key === '_') change(model.scale / 1.4);
      else if (e.key === '0' || e.key === 'Home') {
        model.fit();
        resetGesture();
        draw();
      } else if (e.key === '1') change(1);
      else if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) {
        model.pan(
          e.key === 'ArrowLeft' ? 60 : e.key === 'ArrowRight' ? -60 : 0,
          e.key === 'ArrowUp' ? 60 : e.key === 'ArrowDown' ? -60 : 0
        );
        resetGesture();
        draw();
      } else handled = false;
      if (handled) e.preventDefault();
    });
    if (root.ResizeObserver) {
      resizeObserver = new root.ResizeObserver(size);
      resizeObserver.observe(stage);
    }
    on(root, 'resize', size);
    on(root, 'blur', clearPointers);
    wrap.dataset.state = 'loading';
    if (image.complete && image.naturalWidth) load();
    return {
      ready: ready,
      close: function () {
        if (closed) return;
        closed = true;
        if (!settled) {
          settled = true;
          rejectReady(new Error('closed'));
        }
        listeners.forEach(function (remove) {
          remove();
        });
        listeners = [];
        clearPointers();
        gesture = model = null;
        if (resizeObserver) resizeObserver.disconnect();
        image.removeAttribute('src');
        image.remove();
        wrap.remove();
      }
    };
  }
  var api = { Geometry: Geometry, mount: mount, defaults: defaults };
  if (typeof module === 'object') module.exports = api;
  else root.LegnaImagePreview = api;
})(typeof globalThis === 'object' ? globalThis : this);
