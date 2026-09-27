/* Lazy complete-block Markdown. Offscreen content is ranges, not retained DOM/text. */
(function (root) {
  'use strict';
  var CHUNK = 64 * 1024,
    SECTION = 100,
    CACHE = 4 * 1024 * 1024;
  function checkCurrent(isCurrent) {
    if (isCurrent && !isCurrent()) throw new Error('cancelled');
  }
  function Source(reader) {
    this.reader = reader;
    this.row = 0;
    this.position = 0;
    this.previous = null;
    this.checkpoints = [];
    this.eof = false;
  }
  Source.prototype.next = async function () {
    var reader = this.reader,
      text = '',
      start = this.position,
      rows = 0;
    this.checkpoints.push({ position: start, row: this.row, previous: this.previous });
    while (rows < 128 && text.length < CHUNK - 16386) {
      await reader.ensureRows(this.row + 1);
      if (this.row >= reader.rows) {
        this.eof = reader.eof;
        break;
      }
      var row = (await reader.getRows(this.row, 1))[0];
      text += (this.previous !== null && row.number !== this.previous ? '\n' : '') + row.text;
      this.previous = row.number;
      this.row++;
      rows++;
    }
    this.position += text.length;
    if (reader.eof && this.row === reader.rows) this.eof = true;
    return { text: text, start: start, final: this.eof };
  };
  Source.prototype.read = async function (start, end, isCurrent) {
    checkCurrent(isCurrent);
    var low = 0,
      high = this.checkpoints.length;
    while (low + 1 < high) {
      var mid = (low + high) >>> 1;
      if (this.checkpoints[mid].position <= start) low = mid;
      else high = mid;
    }
    var c = this.checkpoints[low],
      p = c.position,
      row = c.row,
      previous = c.previous,
      text = '';
    while (p < end) {
      checkCurrent(isCurrent);
      var value = (await this.reader.getRows(row++, 1))[0];
      checkCurrent(isCurrent);
      if (!value) throw new Error('changed');
      var piece = (previous !== null && previous !== value.number ? '\n' : '') + value.text;
      text += piece.slice(Math.max(0, start - p), Math.max(0, Math.min(piece.length, end - p)));
      p += piece.length;
      previous = value.number;
    }
    return text;
  };
  // Independent range cursor: inline lookahead never advances the block index.
  // Only two physical lines are examined; giant physical lines remain bounded
  // row segments and 64 Ki UTF-16 messages, never a concatenated source string.
  Source.prototype.scanInline = async function (start, consume, isCurrent) {
    checkCurrent(isCurrent);
    var low = 0, high = this.checkpoints.length;
    while (low + 1 < high) {
      var mid = (low + high) >>> 1;
      if (this.checkpoints[mid].position <= start) low = mid;
      else high = mid;
    }
    var checkpoint = this.checkpoints[low];
    if (!checkpoint || checkpoint.position > start) throw new Error('boundary');
    var position = checkpoint.position, row = checkpoint.row, previous = checkpoint.previous;
    var chunk = '', lines = 0, total = 0;
    while (true) {
      checkCurrent(isCurrent);
      await this.reader.ensureRows(row + 1);
      checkCurrent(isCurrent);
      if (row >= this.reader.rows) {
        if (!this.reader.eof) throw new Error('boundary');
        return consume(chunk, true, total + chunk.length);
      }
      var value = (await this.reader.getRows(row++, 1))[0];
      checkCurrent(isCurrent);
      if (!value) throw new Error('changed');
      var piece = (previous !== null && previous !== value.number ? '\n' : '') + value.text;
      previous = value.number;
      var from = Math.max(0, start - position);
      position += piece.length;
      piece = piece.slice(from);
      for (var offset = 0; offset < piece.length;) {
        var end = Math.min(piece.length, offset + CHUNK - chunk.length);
        var newline = piece.indexOf('\n', offset);
        if (newline >= offset && newline < end) {
          end = newline + 1;
          lines++;
        }
        chunk += piece.slice(offset, end);
        offset = end;
        var final = lines === 2;
        if (chunk.length === CHUNK || final) {
          total += chunk.length;
          var result = await consume(chunk, final, total);
          checkCurrent(isCurrent);
          chunk = '';
          if (final || result && (result.done || result.unsupported)) return result;
        }
      }
    }
  };
  function Client() {
    var self = this;
    this.worker = new root.Worker('/assets/markdown-stream-worker.js');
    this.requests = new Map();
    this.id = 0;
    this.closed = false;
    this.worker.onmessage = function (event) {
      var data = event.data,
        request = self.requests.get(data.id);
      if (!request) return;
      clearTimeout(request.timer);
      self.requests.delete(data.id);
      if (data.error) request.reject(new Error(data.error));
      else request.resolve(data.result);
    };
    this.worker.onerror = function () {
      self.close(new Error('worker'));
    };
  }
  Client.prototype.call = function (message) {
    var self = this;
    return new Promise(function (resolve, reject) {
      if (self.closed) {
        reject(new Error('closed'));
        return;
      }
      var id = ++self.id;
      var timer = setTimeout(function () {
        self.close(new Error('timeout'));
      }, 5000);
      self.requests.set(id, { resolve: resolve, reject: reject, timer: timer });
      self.worker.postMessage(Object.assign({ id: id }, message));
    });
  };
  Client.prototype.close = function (error) {
    this.closed = true;
    this.worker.terminate();
    this.requests.forEach(function (r) {
      clearTimeout(r.timer);
      r.reject(error || new Error('closed'));
    });
    this.requests.clear();
  };
  function Index(source, worker) {
    this.source = source;
    this.worker = worker;
    this.sections = [];
    this.detail = new Map();
    this.pending = [];
    this.done = false;
    this.version = 0;
    this.tail = 0;
    this.references = new Map();
    this.referenceBytes = 0;
    this.referenceVersion = 0;
  }
  Index.prototype.remember = function (number, blocks) {
    this.detail.delete(number);
    this.detail.set(number, blocks);
    while (this.detail.size > 4) this.detail.delete(this.detail.keys().next().value);
  };
  Index.prototype.ensure = async function (number) {
    while (!this.done && this.sections.length <= number) {
      var chunk = await this.source.next(),
        result = await this.worker.call({ op: 'feed', text: chunk.text, final: chunk.final });
      this.version = result.version;
      this.pending.push.apply(this.pending, result.blocks);
      this.tail = result.offset;
      while (this.pending.length >= SECTION || (chunk.final && this.pending.length)) {
        var blocks = this.pending.splice(0, SECTION),
          n = this.sections.length;
        this.sections.push({ start: blocks[0].start, end: blocks[blocks.length - 1].end, count: blocks.length, context: blocks[0].replay || null });
        this.remember(n, blocks);
      }
      if (chunk.final) this.done = true;
    }
  };
  Index.prototype.get = async function (number) {
    await this.ensure(number);
    var cached = this.detail.get(number);
    if (cached) {
      this.remember(number, cached);
      return cached;
    }
    var section = this.sections[number];
    if (!section) return [];
    await this.worker.call({ op: 'replayStart', start: section.start, context: section.context });
    var blocks = [];
    for (var start = section.start; start < section.end; start += CHUNK) {
      var end = Math.min(start + CHUNK, section.end),
        text = await this.source.read(start, end);
      var result = await this.worker.call({ op: 'replay', text: text, final: end === section.end });
      blocks.push.apply(blocks, result.blocks);
    }
    if (blocks.length !== section.count) throw new Error('boundary');
    this.remember(number, blocks);
    return blocks;
  };
  // Definitions are resolved only for labels used by the visible bounded block.
  // Scan the already-indexed immutable source instead of retaining every URL in
  // worker memory. Negative results are invalidated when more definitions arrive.
  Index.prototype.resolveReferences = async function (names, isCurrent) {
    checkCurrent(isCurrent);
    if (this.referenceVersion !== this.version) {
      this.references.clear(); this.referenceBytes = 0; this.referenceVersion = this.version;
    }
    var result = Object.create(null), missing = [], self = this;
    names.forEach(function (name) {
      if (!self.references.has(name)) missing.push(name);
      else {
        var value = self.references.get(name);
        self.references.delete(name); self.references.set(name, value);
        if (value.value) result[name] = value.value;
      }
    });
    if (missing.length) {
      await this.worker.call({ op: 'lookupStart', names: missing });
      checkCurrent(isCurrent);
      var found = {}, tail = this.tail;
      for (var start = 0; start < tail; start += CHUNK) {
        var end = Math.min(start + CHUNK, tail);
        checkCurrent(isCurrent);
        found = await this.worker.call({ op: 'lookup', text: await this.source.read(start, end, isCurrent), final: end === tail });
        checkCurrent(isCurrent);
      }
      missing.forEach(function (name) {
        var value = found[name] || null, cost = (name.length + JSON.stringify(value).length) * 2;
        if (value) result[name] = value;
        while (self.references.size && self.referenceBytes + cost > 1024 * 1024) {
          var first = self.references.keys().next().value;
          self.referenceBytes -= self.references.get(first).cost; self.references.delete(first);
        }
        if (cost <= 1024 * 1024) { self.references.set(name, { value: value, cost: cost }); self.referenceBytes += cost; }
      });
    }
    return result;
  };
  function mount(options) {
    var reader = options.reader,
      source = new Source(reader),
      worker = new Client(),
      index = new Index(source, worker);
    var doc = root.document,
      container = options.container,
      labels = options.labels,
      closed = false,
      active = false,
      page = 0,
      blocks = [],
      heights = [],
      prefix = [];
    var mounted = new Map(),
      cache = new Map(),
      cacheBytes = 0,
      version = 0,
      busy = false,
      rendering = false,
      dirty = false,
      timer = null,
      generation = 0,
      paintGeneration = 0,
      inlineJob = null,
      nextInlineJob = 0,
      scanning = false;
    var diagrams = root.LegnaDiagrams ? new root.LegnaDiagrams.Manager({ container: container, labels: labels }) : null;
    function el(tag, cls, text) {
      var n = doc.createElement(tag);
      n.className = cls;
      if (text != null) n.textContent = text;
      return n;
    }
    var nav = el('div', 'markdown-navigation'),
      prev = el('button', '', labels.previous),
      next = el('button', '', labels.next),
      info = el('span', '', '');
    var scan = el('button', 'markdown-scan', labels.markdownScan);
    scan.type = 'button';
    var note = el('p', 'markdown-stream-note', labels.markdownStreaming),
      error = el('p', 'markdown-stream-error', '');
    error.setAttribute('role', 'status');
    var progress = el('p', 'markdown-stream-progress', '');
    progress.setAttribute('role', 'status');
    var stage = el('div', 'markdown-block-stage');
    nav.append(prev, info, next);
    container.replaceChildren(nav, scan, note, progress, error, stage);
    prev.type = next.type = 'button';
    container.tabIndex = 0;
    container.setAttribute('aria-label', labels.rendered);
    function rebuild() {
      prefix = [0];
      heights.forEach(function (h) {
        prefix.push(prefix[prefix.length - 1] + h);
      });
      stage.style.height = prefix[prefix.length - 1] + 'px';
    }
    function measureMounted() {
      if (closed || !active || !blocks.length) return;
      var anchor = at(Math.max(0, container.getBoundingClientRect().top - stage.getBoundingClientRect().top));
      var before = prefix[anchor], changed = false;
      mounted.forEach(function (node, i) {
        var height = Math.max(12, node.getBoundingClientRect().height);
        if (Math.abs(heights[i] - height) > 0.5) { heights[i] = height; changed = true; }
      });
      if (!changed) return;
      rebuild();
      mounted.forEach(function (node, i) { node.style.top = prefix[i] + 'px'; });
      container.scrollTop += prefix[anchor] - before;
      schedule();
    }
    function at(y) {
      var low = 0,
        high = blocks.length;
      while (low < high) {
        var mid = (low + high) >>> 1;
        if (prefix[mid + 1] < y) low = mid + 1;
        else high = mid;
      }
      return Math.min(low, Math.max(0, blocks.length - 1));
    }
    function release(number) {
      var node = mounted.get(number);
      if (!node) return;
      if (diagrams) diagrams.detach(node);
      observer && observer.unobserve(node);
      node.remove();
      mounted.delete(number);
    }
    function clear() {
      Array.from(mounted.keys()).forEach(release);
    }
    function update() {
      prev.disabled = busy || !page;
      next.disabled = busy || (index.done && page + 1 >= index.sections.length);
      info.textContent = labels.section + ' ' + (page + 1) + ' / ' + index.sections.length + (index.done ? ' · ' + labels.complete : '+');
      scan.textContent = scanning ? labels.markdownStop : labels.markdownScan;
      scan.disabled = (busy && !scanning) || index.done;
      container.dataset.markdownSections = String(index.sections.length);
      container.dataset.markdownDone = String(index.done);
      container.dataset.markdownCacheBytes = String(cacheBytes);
      container.dataset.markdownCheckpoints = String(source.checkpoints.length);
      container.dataset.markdownReferenceBytes = String(index.referenceBytes);
    }
    function fail(e) {
      if (!closed && e.message !== 'cancelled')
        error.textContent = ['block', 'complexity', 'references'].includes(e.message) ? labels.markdownBlockLimit : labels.markdownFailed;
    }
    function schedule() {
      dirty = true;
      if (timer || closed || !active) return;
      timer = setTimeout(function () {
        timer = null;
        paint();
      }, 16);
    }
    async function inlinePlan(start, isCurrent) {
      checkCurrent(isCurrent);
      if (inlineJob && inlineJob.start === start && inlineJob.complete) return inlineJob;
      var job = inlineJob = { id: String(++nextInlineJob), start: start, complete: false, unsupported: false, names: [] };
      progress.textContent = labels.loading;
      container.setAttribute('aria-busy', 'true');
      try {
        await worker.call({ op: 'inlineStart', job: job.id, start: start });
        checkCurrent(isCurrent);
        var result = await source.scanInline(start, async function (text, final, count) {
          checkCurrent(isCurrent);
          var result = await worker.call({ op: 'inlineFeed', job: job.id, text: text, final: final });
          checkCurrent(isCurrent);
          progress.textContent = labels.loading + ' · ' + labels.indexed + ': ' + count.toLocaleString();
          return result;
        }, isCurrent);
        checkCurrent(isCurrent);
        job.complete = true;
        job.unsupported = !result || result.unsupported || !result.done;
        job.names = result && result.names || [];
        return job;
      } finally {
        if (inlineJob === job) {
          progress.textContent = '';
          container.removeAttribute('aria-busy');
          if (!job.complete) inlineJob = null;
        }
      }
    }
    async function parsed(block, isCurrent) {
      checkCurrent(isCurrent);
      if (version !== index.version) {
        cache.clear();
        cacheBytes = 0;
        version = index.version;
        clear();
      }
      var key = block.start,
        value = cache.get(key);
      if (value) {
        cache.delete(key);
        cache.set(key, value);
        return value;
      }
      var text = await source.read(block.start, block.end, isCurrent), result, semantic = false;
      checkCurrent(isCurrent);
      var fragment = block.fragment || null;
      if (fragment && Number.isSafeInteger(fragment.inlineStart) && fragment.inlineStart >= 0 && fragment.inlineStart <= block.start) {
        var plan = await inlinePlan(fragment.inlineStart, isCurrent);
        checkCurrent(isCurrent);
        if (!plan.unsupported) {
          var resolved = plan.names.length ? await index.resolveReferences(plan.names, isCurrent) : {};
          checkCurrent(isCurrent);
          result = await worker.call({ op: 'inlineRender', job: plan.id, from: block.start, to: block.end, text: text, links: resolved });
          checkCurrent(isCurrent);
          semantic = !!result.semantic;
          if (!semantic) result = null;
        }
      }
      if (!result) {
        var names = await worker.call({ op: 'needed', text: text, fragment: fragment });
        checkCurrent(isCurrent);
        var links = names.length ? await index.resolveReferences(names, isCurrent) : {};
        checkCurrent(isCurrent);
        result = await worker.call({ op: 'render', text: text, fragment: fragment, links: links });
        checkCurrent(isCurrent);
      }
      var cost = JSON.stringify(result.tokens).length * 2;
      value = { tokens: result.tokens, cost: cost, semantic: semantic };
      if (cost <= CACHE) {
        while (cache.size && cacheBytes + cost > CACHE) {
          var old = cache.keys().next().value;
          cacheBytes -= cache.get(old).cost;
          cache.delete(old);
        }
        cache.set(key, value);
        cacheBytes += cost;
      }
      return value;
    }
    async function paint() {
      if (closed || !active || rendering || busy) return;
      rendering = true;
      dirty = false;
      var token = generation, paintToken = paintGeneration;
      function isCurrent() { return !closed && active && token === generation && paintToken === paintGeneration; }
      try {
        var y = Math.max(0, container.getBoundingClientRect().top - stage.getBoundingClientRect().top),
          first = Math.max(0, at(y) - 2),
          last = Math.min(blocks.length, at(y + container.clientHeight) + 3, first + 24);
        Array.from(mounted.keys()).forEach(function (n) {
          if (n < first || n >= last) release(n);
        });
        for (var i = first; i < last; i++) {
          if (mounted.has(i)) continue;
          var block = blocks[i],
            tokens, semantic = false,
            fallback = null;
          try {
            var parsedBlock = await parsed(block, isCurrent);
            tokens = parsedBlock.tokens;
            semantic = parsedBlock.semantic;
          } catch (e) {
            if (!['block', 'complexity', 'references'].includes(e.message)) throw e;
            checkCurrent(isCurrent);
            fallback = await source.read(block.start, block.end, isCurrent);
          }
          if (!isCurrent()) return;
          var ordinal = 0;
          var adapter = diagrams
            ? {
                blocks: diagrams.blocks,
                block: function (lang, text) {
                  return diagrams.block(lang, text, String(block.start) + ':' + ordinal++);
                }
              }
            : null;
          var node;
          try {
            if (fallback !== null) throw new Error('limit');
            node = root.LegnaMarkdown.render(tokens, doc, adapter, Math.max(1, 6000 - stage.querySelectorAll('*').length));
          } catch (e) {
            semantic = false;
            checkCurrent(isCurrent);
            if (diagrams) {
              diagrams.blocks.slice().forEach(function (b) {
                if (!container.contains(b.element)) diagrams.detach(b.element);
              });
            }
            node = el('article', 'markdown-document');
            node.append(
              el('p', 'markdown-stream-note', labels.markdownBlockLimit),
              el('pre', '', fallback === null ? await source.read(block.start, block.end, isCurrent) : fallback)
            );
          }
          if (!isCurrent()) return;
          node.classList.add('markdown-virtual-block');
          node.dataset.inlineSemantic = String(semantic);
          if (block.fragment) {
            node.classList.add('markdown-' + block.fragment.kind + '-window');
            if (semantic) {
              node.classList.add('markdown-inline-window');
              node.dataset.inlineStart = String(block.fragment.inlineStart);
              if (block.start === block.fragment.inlineStart) node.classList.add('markdown-inline-first');
            }
            if (!semantic && ['table-row-source', 'list-item-source', 'quote-child-source', 'table-header-source'].includes(block.fragment.kind)) {
              node.classList.add('markdown-source-window');
              if (block.fragment.first) node.prepend(el('p', 'markdown-stream-note', labels.markdownSourceWindow));
            }
            if (!semantic && block.fragment.kind === 'paragraph' && block.fragment.first)
              node.prepend(el('p', 'markdown-stream-note', labels.markdownParagraphSource));
            if (block.fragment.kind === 'fence' && block.fragment.from && /^(mermaid|markmap|markedmap)$/i.test(block.fragment.lang)) {
              node.prepend(el('p', 'markdown-stream-note', labels.diagramLimit || labels.markdownBlockLimit));
            }
          }
          node.dataset.blockStart = String(block.start);
          node.style.top = prefix[i] + 'px';
          mounted.set(i, node);
          stage.appendChild(node);
          if (observer) observer.observe(node);
          measureMounted();
        }
        mounted.forEach(function (node, i) {
          node.style.top = prefix[i] + 'px';
        });
        update();
        if (diagrams) diagrams.schedule();
      } catch (e) {
        fail(e);
      } finally {
        rendering = false;
        if (dirty) schedule();
      }
    }
    // ResizeObserver handles viewport width, font metrics and asynchronous
    // diagrams. Reflow preserves the current visible block rather than jumping
    // as a formatted inline window becomes taller than its estimate.
    var observer = root.ResizeObserver ? new root.ResizeObserver(measureMounted) : null;
    if (observer) observer.observe(container);
    function resized() { measureMounted(); schedule(); }
    if (root.addEventListener) root.addEventListener('resize', resized);
    if (doc.fonts && doc.fonts.addEventListener) doc.fonts.addEventListener('loadingdone', resized);
    async function open(number) {
      if (busy || closed) return;
      busy = true;
      update();
      error.textContent = '';
      var token = ++generation;
      try {
        var result = await index.get(number);
        if (closed || token !== generation) return;
        if (!result.length && number) return;
        page = number;
        blocks = result;
        heights = blocks.map(function (b) {
          return b.type === 'code' ? 160 : b.type === 'heading' ? 56 : 80;
        });
        clear();
        rebuild();
        container.scrollTop = 0;
      } catch (e) {
        fail(e);
        if (!blocks.length) throw e;
      } finally {
        busy = false;
        update();
        schedule();
      }
    }
    scan.onclick = async function () {
      if (scanning) {
        scanning = false;
        update();
        return;
      }
      if (busy || index.done || closed) return;
      scanning = true;
      busy = true;
      error.textContent = '';
      update();
      try {
        while (scanning && !closed && !index.done) {
          await index.ensure(index.sections.length);
          if (closed) return;
          update();
          await new Promise(function (resolve) {
            setTimeout(resolve, 0);
          });
        }
      } catch (e) {
        fail(e);
      } finally {
        scanning = false;
        busy = false;
        if (!closed) {
          clear();
          update();
          schedule();
        }
      }
    };
    prev.onclick = function () {
      open(page - 1);
    };
    next.onclick = function () {
      open(page + 1);
    };
    container.addEventListener('scroll', schedule);
    var ready = open(0);
    return {
      ready: ready,
      setActive: function (value) {
        active = value;
        if (diagrams) diagrams.setActive(value);
        if (value) { measureMounted(); schedule(); }
        else {
          scanning = false;
          paintGeneration++;
          clearTimeout(timer); timer = null;
          progress.textContent = '';
          container.removeAttribute('aria-busy');
          clear();
        }
      },
      close: function () {
        closed = true;
        scanning = false;
        generation++;
        paintGeneration++;
        inlineJob = null;
        progress.textContent = '';
        container.removeAttribute('aria-busy');
        clearTimeout(timer);
        worker.close();
        clear();
        if (observer) observer.disconnect();
        if (diagrams) diagrams.close();
        container.removeEventListener('scroll', schedule);
        if (root.removeEventListener) root.removeEventListener('resize', resized);
        if (doc.fonts && doc.fonts.removeEventListener) doc.fonts.removeEventListener('loadingdone', resized);
        source.checkpoints = [];
        index.sections = [];
        index.detail.clear();
        index.pending = [];
        index.references.clear(); index.referenceBytes = 0;
        cache.clear();
        cacheBytes = 0;
      }
    };
  }
  var api = { Source: Source, Index: Index, mount: mount, limits: { chunk: CHUNK, section: SECTION, cache: CACHE } };
  if (typeof module === 'object') module.exports = api;
  else root.LegnaMarkdownStream = api;
})(typeof globalThis === 'object' ? globalThis : this);
