/* LegnaSend bounded text reader. No remote dependencies; file content is never HTML. */
(function (root) {
  'use strict';
  var CHUNK = 64 * 1024, SEGMENT = 16 * 1024, CACHE = 4 * 1024 * 1024;
  var ROW_HEIGHT = 28, SECTION = 1000, BUFFER = 6;
  var defaults = {
    encoding: 'Encoding', auto: 'Auto (BOM / UTF-8)', previous: 'Previous section', next: 'Next section',
    more: 'Load more', retry: 'Reload preview', indexed: 'Indexed', lines: 'Lines', section: 'Section',
    complete: 'End of file', loading: 'Loading text…', view: 'Text preview',
    range: 'This source does not support bounded text reads. Download the original file.',
    changed: 'The shared file changed. Reopen the share before previewing it.',
    decode: 'Invalid text encoding. Choose another encoding or download the original file.',
    failed: 'Text could not be loaded. Check the connection and reload the preview.',
    unsupported: 'This browser does not support streaming text preview.',
    hint: 'Only visible rows and a small buffer are rendered. Wrapping keeps long text within the page.',
    wrap: 'Wrap text', numbers: 'Line numbers', search: 'Search content', searchScope: 'Search scope',
    loaded: 'Indexed content', full: 'Entire file', find: 'Find', stop: 'Stop search', caseSensitive: 'Match case',
    previousMatch: 'Previous match', nextMatch: 'Next match', matches: 'Matches', scanned: 'Scanned',
    searching: 'Searching…', searchDone: 'Search complete', searchStopped: 'Search stopped', noMatches: 'No matches in scanned content',
    searchLimit: 'First 1,000 matches shown. Refine the query to search further.', clearSearch: 'Clear search',
    textJumpLine: 'Go to line', textJumpGo: 'Go', textJumpCancel: 'Stop indexing', textJumpIndexing: 'Indexing toward line',
    textJumpStopped: 'Line indexing stopped. The current view is unchanged.', textJumpFound: 'Showing line',
    textJumpMissing: 'That line is beyond the end of this file. Total lines', textJumpInvalid: 'Enter a whole line number starting at 1.',
    rendered: 'Reading view', source: 'Source', markdownHint: 'Markdown search covers source text; results open at the exact source position.',
    markdownLimit: 'Large Markdown loads in complete-block sections with virtual scrolling.',
    markdownScan: 'Index references', markdownStop: 'Stop indexing',
    markdownStreaming: 'Complete blocks load by section. Reference links update as their definitions are indexed.',
    markdownSourceWindow: 'Large syntax block · complete source in reading windows; formatting that crosses windows stays literal.',
    markdownParagraphSource: 'Very large paragraph · complete source in reading windows; cross-window inline formatting stays literal.',
    markdownBlockLimit: 'This syntax block exceeds the reading budget. Use Source to continue without truncation.',
    markdownFailed: 'Formatting is unavailable for this document. The source reader remains available.'
  };
  function failure(code) { var error = new Error(code); error.code = code; return error; }
  function abortError() { var error = new Error('Closed'); error.name = 'AbortError'; return error; }
  function encodingFor(bytes, requested) {
    if (requested !== 'auto') return requested;
    if (bytes[0] === 0xff && bytes[1] === 0xfe && bytes[2] === 0 && bytes[3] === 0 ||
        bytes[0] === 0 && bytes[1] === 0 && bytes[2] === 0xfe && bytes[3] === 0xff) throw failure('decode');
    if (bytes[0] === 0xff && bytes[1] === 0xfe) return 'utf-16le';
    if (bytes[0] === 0xfe && bytes[1] === 0xff) return 'utf-16be';
    return 'utf-8';
  }
  function decoder(encoding) { return new TextDecoder(encoding, { fatal: true, ignoreBOM: true }); }
  // Page boundaries are code-point and row boundaries, so a discarded page can be
  // decoded again without retaining an unbounded decoder/string from the prefix.
  function parsePage(bytes, options) {
    var encoding = options.encoding, wide = encoding.indexOf('utf-16') === 0;
    var unit = wide ? 2 : 1, little = encoding === 'utf-16le';
    function value(i) { return wide ? little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1] : bytes[i]; }
    function width(i) {
      var c = value(i);
      if (wide) return c >= 0xd800 && c <= 0xdbff ? 4 : 2;
      if (encoding === 'gb18030') return c >= 0x81 && c <= 0xfe ? bytes[i + 1] >= 0x30 && bytes[i + 1] <= 0x39 ? 4 : 2 : 1;
      return c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 1;
    }
    var p = 0, start = 0, delta = 0, continued = options.continued, count = 0;
    var index = new Uint32Array((bytes.length + 1) * 4);
    if (options.first) {
      if (encoding === 'utf-8' && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) start = p = 3;
      else if (wide && bytes.length >= 2 && value(0) === 0xfeff) start = p = 2;
    }
    function add(end) {
      index[count++] = start; index[count++] = end; index[count++] = delta; index[count++] = continued ? 1 : 0;
    }
    while (p + unit <= bytes.length) {
      var c = value(p);
      if (c === 10 || c === 13) {
        if (c === 13 && p + unit === bytes.length && !options.final && !options.completeBoundary) break;
        // A newline immediately after a long-line segment belongs to that line.
        if (p !== start || !continued) add(p);
        p += unit;
        if (c === 13 && p + unit <= bytes.length && value(p) === 10) p += unit;
        start = p; delta++; continued = false;
      } else {
        var length = width(p);
        if (p + length > bytes.length) break;
        p += length;
        if (p - start >= SEGMENT) { add(p); start = p; continued = true; }
      }
    }
    if (options.final) {
      // Flush the final fragment, including an empty line after a trailing newline.
      if (start < bytes.length || !continued) add(bytes.length);
      start = bytes.length;
    }
    if (!options.final && start === 0) throw failure('decode');
    try { decoder(encoding).decode(bytes.subarray(0, start)); } catch (_) { throw failure('decode'); }
    return { bytes: bytes.slice(0, start), index: index.slice(0, count), count: count / 4,
      consumed: start, nextLine: options.line + delta, continued: continued };
  }

  function Reader(url, size, options) {
    options = options || {};
    if (!Number.isSafeInteger(size) || size < 0) throw failure('range');
    this.url = url; this.size = size; this.fetch = options.fetch || root.fetch.bind(root);
    this.requested = options.encoding || 'auto'; this.encoding = null; this.etag = null;
    this.pages = []; this.cache = new Map(); this.cacheBytes = 0; this.cacheLimit = options.cacheLimit || CACHE;
    this.inflight = new Map(); this.controllers = new Set(); this.rows = 0; this.offset = 0;
    this.line = 1; this.continued = false; this.eof = false; this.closed = false; this.loading = null;
    this.timeout = options.timeout || 20000;
  }
  Reader.prototype.close = function () {
    this.closed = true; this.controllers.forEach(function (c) { c.abort(); }); this.controllers.clear();
    this.cache.clear(); this.cacheBytes = 0; this.pages = []; this.inflight.clear();
  };
  Reader.prototype.request = async function (method, start, end) {
    if (this.closed) throw abortError();
    var controller = new AbortController(), response;
    this.controllers.add(controller);
    var timer = setTimeout(function () { controller.abort(); }, this.timeout);
    try {
      var headers = {};
      if (method === 'GET') { headers.Range = 'bytes=' + start + '-' + end; headers['If-Match'] = this.etag; }
      response = await this.fetch(this.url, { method: method, headers: headers, signal: controller.signal, cache: 'no-store' });
      if (this.closed) throw abortError();
      if (response.status === 409 || response.status === 412) throw failure('changed');
      if (method === 'HEAD') {
        if (response.status !== 200) throw failure('failed');
        var length = response.headers.get('Content-Length'), etag = response.headers.get('ETag');
        if (!/^\d+$/.test(length || '') || Number(length) !== this.size) throw failure('changed');
        if (response.headers.get('Accept-Ranges') !== 'bytes' || !/^"[^"\r\n]+"$/.test(etag || '')) throw failure('range');
        this.etag = etag;
        return null;
      }
      if (response.status === 200) throw failure('range');
      if (response.status !== 206) throw failure('failed');
      if (response.headers.get('ETag') !== this.etag) throw failure('changed');
      if (response.headers.get('Content-Range') !== 'bytes ' + start + '-' + end + '/' + this.size ||
          Number(response.headers.get('Content-Length')) !== end - start + 1) throw failure('range');
      if (!response.body || !response.body.getReader) throw failure('unsupported');
      var reader = response.body.getReader(), result = new Uint8Array(end - start + 1), offset = 0;
      try {
        while (true) {
          var chunk = await reader.read();
          if (this.closed) throw abortError();
          if (chunk.done) break;
          if (offset + chunk.value.length > result.length) throw failure('range');
          result.set(chunk.value, offset); offset += chunk.value.length;
        }
        if (offset !== result.length) throw failure('failed');
      } finally { await reader.cancel().catch(function () {}); reader.releaseLock(); }
      return result;
    } finally {
      clearTimeout(timer); controller.abort(); this.controllers.delete(controller);
      if (response && response.body && !response.body.locked) await response.body.cancel().catch(function () {});
    }
  };
  Reader.prototype.init = async function () {
    await this.request('HEAD');
    await this.ensureRows(1);
  };
  Reader.prototype.remember = function (page, parsed) {
    if (this.closed) return;
    if (this.cache.has(page.start)) return;
    var cost = parsed.bytes.byteLength + parsed.index.byteLength;
    while (this.cache.size && this.cacheBytes + cost > this.cacheLimit) {
      var oldest = this.cache.keys().next().value, removed = this.cache.get(oldest);
      this.cacheBytes -= removed.bytes.byteLength + removed.index.byteLength; this.cache.delete(oldest);
    }
    this.cache.set(page.start, parsed); this.cacheBytes += cost;
  };
  Reader.prototype.appendPage = async function () {
    var start = this.offset, final = start + CHUNK >= this.size;
    var bytes = this.size ? await this.request('GET', start, Math.min(start + CHUNK, this.size) - 1) : new Uint8Array();
    if (this.closed) throw abortError();
    if (!this.encoding) this.encoding = encodingFor(bytes, this.requested);
    var parsed = parsePage(bytes, { encoding: this.encoding, first: start === 0, final: final, line: this.line, continued: this.continued });
    var page = { start: start, end: start + parsed.consumed, row: this.rows, count: parsed.count,
      line: this.line, continued: this.continued, final: final };
    this.pages.push(page); this.remember(page, parsed);
    this.offset = page.end; this.rows += parsed.count; this.line = parsed.nextLine; this.continued = parsed.continued; this.eof = final;
  };
  Reader.prototype.ensureRows = async function (target) {
    if (this.closed) throw abortError();
    if (this.loading) { await this.loading; return this.ensureRows(target); }
    var self = this;
    this.loading = (async function () {
      while (self.rows < target && !self.eof && !self.closed) {
        await self.appendPage();
        // Yield between index pages so close/encoding changes can cancel a long seek.
        await new Promise(function (resolve) { setTimeout(resolve, 0); });
      }
      if (self.closed) throw abortError();
    })();
    try { await this.loading; } finally { this.loading = null; }
  };
  Reader.prototype.pageAt = function (row) {
    var low = 0, high = this.pages.length;
    while (low < high) { var mid = (low + high) >>> 1; if (this.pages[mid].row + this.pages[mid].count <= row) low = mid + 1; else high = mid; }
    return this.pages[low];
  };
  Reader.prototype.loadPage = async function (page) {
    if (this.closed) throw abortError();
    var cached = this.cache.get(page.start);
    if (cached) { this.cache.delete(page.start); this.cache.set(page.start, cached); return cached; }
    if (this.inflight.has(page.start)) return this.inflight.get(page.start);
    var self = this;
    var task = (async function () {
      var bytes = page.end > page.start ? await self.request('GET', page.start, page.end - 1) : new Uint8Array();
      if (self.closed) throw abortError();
      var parsed = parsePage(bytes, { encoding: self.encoding, first: page.start === 0, final: page.final, completeBoundary: true, line: page.line, continued: page.continued });
      if (parsed.count !== page.count || parsed.consumed !== page.end - page.start) throw failure('changed');
      self.remember(page, parsed); return parsed;
    })();
    this.inflight.set(page.start, task);
    try { return await task; } finally { this.inflight.delete(page.start); }
  };
  Reader.prototype.getRows = async function (start, count) {
    var result = [], end = Math.min(start + count, this.rows), textDecoder = decoder(this.encoding);
    while (start < end) {
      var page = this.pageAt(start), data = await this.loadPage(page);
      for (var local = start - page.row; local < page.count && start < end; local++, start++) {
        var i = local * 4;
        result.push({ number: page.line + data.index[i + 2], continued: !!data.index[i + 3],
          text: textDecoder.decode(data.bytes.subarray(data.index[i], data.index[i + 1])) });
      }
    }
    return result;
  };

  Reader.prototype.snapshot = function (copy) {
    return { pages: copy === false ? this.pages : this.pages.slice(), pageCount: this.pages.length, rows: this.rows, offset: this.offset, line: this.line, continued: this.continued,
      eof: this.eof, encoding: this.encoding, etag: this.etag, size: this.size };
  };
  Reader.prototype.adopt = function (index) {
    if (!index || this.closed || this.loading || index.etag !== this.etag || index.size !== this.size ||
        index.encoding !== this.encoding || index.offset < this.offset) return;
    this.pages = index.pages.slice(0, index.pageCount); this.rows = index.rows; this.offset = index.offset;
    this.line = index.line; this.continued = index.continued; this.eof = index.eof;
  };

  // Independent cancellable seek: never close or advance the visible reader
  // until the target's actual physical-line index is verified.
  function LineSeek(source, target, options) {
    if (!Number.isSafeInteger(target) || target < 1) throw failure('line');
    this.source = source; this.target = target; this.options = options || {};
    this.reader = null; this.index = null; this.row = null; this.running = false;
    this.cancelled = false; this.error = null; this.complete = false; this.knownLine = source.line;
  }
  LineSeek.prototype.cancel = function () { this.cancelled = true; this.running = false; if (this.reader) this.reader.close(); this.publish(); };
  LineSeek.prototype.publish = function () {
    if (this.reader && !this.reader.closed) { this.index = this.reader.snapshot(false); this.knownLine = this.reader.line; }
    if (this.options.onProgress) this.options.onProgress(this);
  };
  LineSeek.prototype.find = async function () {
    var reader = this.reader, target = this.target, low = 0, high = reader.pages.length;
    // Lower bound, not upper bound: a long physical line can span many pages.
    while (low < high) { var mid = (low + high) >>> 1; if (reader.pages[mid].line < target) low = mid + 1; else high = mid; }
    for (var p = Math.max(0, low - 1); p < reader.pages.length && p <= low; p++) {
      var page = reader.pages[p];
      if (page.line > target) break;
      var data = await reader.loadPage(page);
      for (var i = 0; i < data.count; i++) {
        var line = page.line + data.index[i * 4 + 2];
        if (line === target && !data.index[i * 4 + 3]) return page.row + i;
        if (line > target) break;
      }
    }
    return null;
  };
  LineSeek.prototype.run = async function () {
    if (this.cancelled || !this.source.encoding) return this;
    var source = this.source;
    var scan = this.reader = new Reader(source.url, source.size, {fetch: source.fetch, encoding: source.encoding, cacheLimit: 2 * 1024 * 1024});
    this.running = true;
    try {
      await scan.request('HEAD');
      if (scan.etag !== source.etag) throw failure('changed');
      scan.encoding = source.encoding; scan.adopt(source.snapshot());
      while (!this.cancelled) {
        this.row = await this.find();
        this.publish();
        if (this.row !== null || scan.eof) { this.complete = true; break; }
        await scan.appendPage();
        this.publish();
        await new Promise(function (resolve) { setTimeout(resolve, 0); });
      }
    } catch (error) { if (!this.cancelled) this.error = error; }
    finally { this.running = false; this.publish(); scan.close(); }
    return this;
  };

  // One section only. Measured heights replace estimates without retaining document strings.
  function Heights(count) { this.values = new Float64Array(SECTION); this.values.fill(ROW_HEIGHT); this.count = count; this.dirty = true; }
  Heights.prototype.rebuild = function () {
    if (!this.dirty) return;
    this.prefix = new Float64Array(SECTION + 1);
    for (var i = 0; i < SECTION; i++) this.prefix[i + 1] = this.prefix[i] + this.values[i];
    this.dirty = false;
  };
  Heights.prototype.offset = function (row) { this.rebuild(); return this.prefix[Math.max(0, Math.min(SECTION, row))]; };
  Heights.prototype.at = function (offset) {
    this.rebuild(); var low = 0, high = this.count;
    while (low < high) { var mid = (low + high) >>> 1; if (this.prefix[mid + 1] <= offset) low = mid + 1; else high = mid; }
    return Math.min(low, Math.max(0, this.count - 1));
  };
  Heights.prototype.measure = function (row, height) {
    height = Math.max(ROW_HEIGHT, Math.round(height * 100) / 100);
    if (this.values[row] === height) return false;
    this.values[row] = height; this.dirty = true; return true;
  };

  function mount(options) {
    var labels = Object.assign({}, defaults, options.labels || {}), container = options.container, status = options.status;
    var disposed = false, generation = 0, reader, busy = false, rendering = false, scheduled = false, dirty = false, section = 0, failed = false;
    var heights = new Heights(0), search = null, searchToken = 0, searchTimer, selected = -1, hitRows = new Map(), pendingHit = false;
    var markdown = null, rendered = false, resizeObserver = null, viewRequest = 0;
    var seek = null, jumpedLine = null, pendingLine = false;
    function element(tag, cls, text) { var el = document.createElement(tag); el.className = cls || ''; if (text != null) el.textContent = text; return el; }
    if (!root.fetch || !root.TextDecoder || !root.AbortController || !root.ReadableStream) { status.textContent = labels.unsupported; return { close: function () {} }; }
    var toolbar = element('div', 'text-toolbar'), encodingLabel = element('label', '', labels.encoding + ' ');
    var select = element('select'); select.setAttribute('aria-label', labels.encoding);
    [['auto', labels.auto], ['utf-8', 'UTF-8'], ['utf-16le', 'UTF-16 LE'], ['utf-16be', 'UTF-16 BE'], ['gb18030', 'GB18030 / GBK']].forEach(function (entry) {
      var option = element('option', '', entry[1]); option.value = entry[0]; select.appendChild(option);
    });
    encodingLabel.appendChild(select); toolbar.appendChild(encodingLabel);
    function button(parent, label, cls) { var el = element('button', cls, label); el.type = 'button'; parent.appendChild(el); return el; }
    var previous = button(toolbar, labels.previous), next = button(toolbar, labels.next), more = button(toolbar, labels.more), retry = button(toolbar, labels.retry);
    function check(parent, label, initial) {
      var wrapper = element('label', 'text-check'), input = element('input'); input.type = 'checkbox'; input.checked = initial;
      wrapper.appendChild(input); wrapper.appendChild(element('span', '', label)); parent.appendChild(wrapper); return input;
    }
    var wrap = check(toolbar, labels.wrap, true), numbers = check(toolbar, labels.numbers, false);
    var viewButton = button(toolbar, labels.rendered, 'text-view-button'); viewButton.hidden = !options.markdown;
    var jumpBar = element('div', 'text-jump'), lineLabel = element('label', 'text-jump-label', labels.textJumpLine + ' ');
    var lineInput = element('input', 'text-jump-input'); lineInput.type = 'text'; lineInput.inputMode = 'numeric'; lineInput.maxLength = 16;
    lineInput.setAttribute('aria-label', labels.textJumpLine); lineLabel.appendChild(lineInput); jumpBar.appendChild(lineLabel);
    var lineGo = button(jumpBar, labels.textJumpGo, 'text-jump-go'), lineCancel = button(jumpBar, labels.textJumpCancel, 'text-jump-cancel');
    var lineStatus = element('span', 'text-jump-status'); lineStatus.setAttribute('role', 'status'); lineStatus.setAttribute('aria-live', 'polite');
    jumpBar.appendChild(lineStatus); toolbar.appendChild(jumpBar);
    var searchBar = element('div', 'text-search'), query = element('input', 'text-query'); query.type = 'search'; query.maxLength = 256;
    query.placeholder = labels.search; query.setAttribute('aria-label', labels.search); searchBar.appendChild(query);
    var scope = element('select'); scope.setAttribute('aria-label', labels.searchScope);
    [['loaded', labels.loaded], ['full', labels.full]].forEach(function (entry) { var o = element('option', '', entry[1]); o.value = entry[0]; scope.appendChild(o); }); searchBar.appendChild(scope);
    var sensitive = check(searchBar, labels.caseSensitive, false);
    var find = button(searchBar, labels.find), stop = button(searchBar, labels.stop), prevHit = button(searchBar, '↑'), nextHit = button(searchBar, '↓'), clear = button(searchBar, '×', 'text-search-clear');
    prevHit.setAttribute('aria-label', labels.previousMatch); nextHit.setAttribute('aria-label', labels.nextMatch); clear.setAttribute('aria-label', labels.clearSearch);
    var searchStatus = element('p', 'text-search-status'); searchStatus.setAttribute('role', 'status'); searchStatus.setAttribute('aria-live', 'polite');
    var progress = element('p', 'text-progress'), viewport = element('div', 'text-viewport');
    viewport.tabIndex = 0; viewport.setAttribute('role', 'region'); viewport.setAttribute('aria-label', labels.view);
    var spacer = element('div', 'text-spacer'), rows = element('div', 'text-rows'); spacer.appendChild(rows); viewport.appendChild(spacer);
    var article = element('div', 'markdown-viewport'); article.hidden = true;
    var hint = element('p', 'text-hint', options.markdown ? labels.markdownHint : labels.hint);
    container.appendChild(toolbar); container.appendChild(searchBar); container.appendChild(searchStatus); container.appendChild(progress);
    container.appendChild(viewport); container.appendChild(article); container.appendChild(hint);
    function available() { return reader ? Math.max(0, Math.min(SECTION, reader.rows - section * SECTION)) : 0; }
    function fitViewport() {
      if (options.compact) viewport.style.maxHeight = (reader && reader.eof ? Math.max(160, Math.min(600, heights.offset(heights.count))) : 600) + 'px';
    }
    function update() {
      if (disposed || !reader) return;
      heights.count = available(); spacer.style.height = heights.offset(heights.count) + 'px';
      fitViewport();
      viewport.className = 'text-viewport' + (wrap.checked ? '' : ' text-nowrap') + (numbers.checked ? ' text-numbered' : '');
      progress.textContent = labels.indexed + ': ' + reader.offset.toLocaleString() + ' / ' + reader.size.toLocaleString() + ' B · ' +
        labels.lines + ': ' + reader.line.toLocaleString() + (rendered ? '' : ' · ' + labels.section + ': ' + (section + 1)) + (reader.eof ? ' · ' + labels.complete : '');
      previous.hidden = next.hidden = more.hidden = rendered;
      wrap.parentNode.hidden = numbers.parentNode.hidden = rendered;
      previous.disabled = busy || section === 0; next.disabled = busy || failed || reader.eof && reader.rows <= (section + 1) * SECTION;
      more.disabled = busy || failed || reader.eof; retry.hidden = !failed;
      query.disabled = find.disabled = !reader.encoding || reader.closed; stop.hidden = !search || !search.running;
      prevHit.disabled = nextHit.disabled = !search || !search.matches.length;
      viewButton.textContent = rendered ? labels.source : labels.rendered;
      lineGo.disabled = !reader.encoding || reader.closed || !!(seek && seek.running); lineCancel.hidden = !seek || !seek.running;
    }
    function showError(error, token) {
      if (disposed || token !== generation) return;
      failed = true; status.textContent = labels[error.code] || labels.failed; update();
    }
    async function work(action) {
      if (busy || disposed) return;
      var token = generation; busy = true; failed = false; status.textContent = labels.loading; update();
      try { await action(); if (disposed || token !== generation) return; status.textContent = ''; }
      catch (error) { showError(error, token); }
      finally { if (token === generation && !disposed) { busy = false; update(); schedule(); } }
    }
    function schedule() {
      if (rendering) { dirty = true; return; }
      if (disposed || scheduled) return; scheduled = true;
      root.requestAnimationFrame(render);
    }
    function highlighted(line, id) {
      var node = element('span', 'text-line'), hits = hitRows.get(id) || [], at = 0;
      hits.forEach(function (hit) {
        // Overlapping ranges are merged visually; the selected match still has a precise source position.
        if (hit.end <= at) return;
        if (hit.start > at) node.appendChild(element('span', '', line.slice(at, hit.start)));
        var mark = element('mark', hit.match === selected ? 'text-match-current' : '', line.slice(Math.max(at, hit.start), hit.end));
        if (hit.match === selected) mark.setAttribute('data-current-match', 'true');
        node.appendChild(mark); at = hit.end;
      });
      if (at < line.length || !hits.length) node.appendChild(element('span', '', line.slice(at)));
      return node;
    }
    async function render() {
      scheduled = false;
      if (disposed || rendered || rendering || !reader || !reader.encoding || reader.closed) return;
      rendering = true; var token = generation, current = reader, top = viewport.scrollTop, currentSection = section;
      heights.count = available();
      var anchor = heights.at(top), anchorOffset = top - heights.offset(anchor);
      // Search navigation owns its source row until measured heights stabilize.
      // Otherwise earlier soft-wrapped rows can move the selected mark several
      // screens after the first estimated scroll has already consumed the hit.
      if (pendingHit && search && selected >= 0 && search.matches[selected]) {
        anchor = search.matches[selected].row % SECTION; anchorOffset = 0;
      }
      var start = Math.max(0, anchor - BUFFER);
      var end = Math.min(SECTION, (pendingHit ? anchor + Math.ceil(viewport.clientHeight / ROW_HEIGHT) : heights.at(top + viewport.clientHeight)) + BUFFER + 1);
      // Before new rows are indexed, use the estimated viewport size to pull the next bounded page.
      end = Math.max(end, Math.min(SECTION, start + Math.ceil(viewport.clientHeight / ROW_HEIGHT) + BUFFER));
      try {
        var content = await current.getRows(currentSection * SECTION + start, end - start);
        if (disposed || token !== generation || currentSection !== section || top !== viewport.scrollTop || rendered) return;
        rows.textContent = ''; rows.style.transform = 'translateY(' + heights.offset(start) + 'px)';
        content.forEach(function (line, i) {
          var row = element('div', 'text-row'), number = element('span', 'text-line-number', String(line.number) + (line.continued ? '↪' : ''));
          if (line.number === jumpedLine && !line.continued) { row.className += ' text-line-target'; row.setAttribute('data-line-target', String(jumpedLine)); }
          number.setAttribute('aria-hidden', 'true'); row.appendChild(number); row.appendChild(highlighted(line.text, currentSection * SECTION + start + i)); rows.appendChild(row);
        });
        var changed = false;
        Array.prototype.forEach.call(rows.children, function (row, i) {
          if (row.getBoundingClientRect) changed = heights.measure(start + i, row.getBoundingClientRect().height) || changed;
        });
        if (changed) {
          fitViewport();
          spacer.style.height = heights.offset(heights.count) + 'px'; rows.style.transform = 'translateY(' + heights.offset(start) + 'px)';
          viewport.scrollTop = heights.offset(anchor) + anchorOffset; dirty = true;
        }
        if (pendingHit && rows.querySelector) {
          var mark = rows.querySelector('[data-current-match]');
          if (mark) { pendingHit = changed; viewport.scrollTop += mark.getBoundingClientRect().top - viewport.getBoundingClientRect().top - viewport.clientHeight / 3; }
        }
        if (pendingLine && rows.querySelector) {
          var lineTarget = rows.querySelector('[data-line-target]');
          if (lineTarget) { pendingLine = false; viewport.scrollTop += lineTarget.getBoundingClientRect().top - viewport.getBoundingClientRect().top - viewport.clientHeight / 3; }
        }
        var target = currentSection * SECTION + Math.min(SECTION, end + BUFFER);
        if (!busy && !failed && !current.eof && current.rows < target) work(function () { return current.ensureRows(target); });
      } catch (error) { showError(error, token); }
      finally {
        rendering = false;
        if (!disposed && (dirty || token !== generation || currentSection !== section || top !== viewport.scrollTop)) { dirty = false; schedule(); }
      }
    }
    function resetLayout() {
      var anchor = heights.at(viewport.scrollTop); heights = new Heights(available()); viewport.scrollTop = heights.offset(anchor); update(); schedule();
    }
    function changeSection(value) { section = value; heights = new Heights(available()); viewport.scrollTop = 0; update(); schedule(); }
    function setView(value) { rendered = value; if(markdown&&markdown.setActive)markdown.setActive(value); viewport.hidden = value; article.hidden = !value; update(); schedule(); }
    async function openMarkdown() {
      if (!root.LegnaMarkdown || !reader || !reader.encoding) return;
      var token = generation, current = reader, intent = ++viewRequest;
      viewButton.disabled = true;
      if (markdown) { setView(true); viewButton.disabled = false; return; }
      markdown = root.LegnaMarkdown.mount({ reader: current, container: article, labels: labels });
      try { await markdown.ready; if (token === generation && !disposed && intent === viewRequest) setView(true); }
      catch (_) { if (token === generation && !disposed) { markdown.close(); markdown = null; hint.textContent = labels.markdownFailed + ' ' + labels.markdownHint; } }
      finally { if (token === generation && !disposed) { viewButton.disabled = false; update(); } }
    }
    function updateSearch(current) {
      if (disposed || search !== current) return;
      if (current.index && !current.running) reader.adopt(current.index);
      hitRows.clear();
      current.matches.forEach(function (match, i) { match.parts.forEach(function (part) {
        if (!hitRows.has(part.row)) hitRows.set(part.row, []);
        hitRows.get(part.row).push({ start: part.start, end: part.end, match: i });
      }); });
      hitRows.forEach(function (parts) { parts.sort(function (a, b) { return a.start - b.start; }); });
      var state = current.error ? labels[current.error.code] || labels.failed : current.running ? labels.searching : current.cancelled ? labels.searchStopped : current.capped ? labels.searchLimit : labels.searchDone;
      searchStatus.textContent = state + ' · ' + labels.matches + ': ' + (selected < 0 ? 0 : selected + 1) + ' / ' + current.matches.length +
        ' · ' + labels.scanned + ': ' + current.scanned.toLocaleString() + ' / ' + current.total.toLocaleString() + ' B' +
        (!current.running && !current.matches.length && !current.error ? ' · ' + labels.noMatches : '');
      update(); schedule();
    }
    function clearResults() {
      searchToken++; clearTimeout(searchTimer); if (search) search.cancel(); search = null; selected = -1; pendingHit = false;
      hitRows.clear(); searchStatus.textContent = ''; update(); schedule();
    }
    async function jump(index) {
      if (!search || !search.matches.length || disposed) return;
      var current = search, token = searchToken;
      selected = (index + current.matches.length) % current.matches.length;
      var match = current.matches[selected];
      if (reader.loading) await reader.loading.catch(function () {});
      if (disposed || current !== search || token !== searchToken) return;
      reader.adopt(current.index); viewRequest++; setView(false);
      var nextSection = Math.floor(match.row / SECTION);
      if (section !== nextSection) changeSection(nextSection);
      viewport.scrollTop = heights.offset(match.row % SECTION); pendingHit = true; updateSearch(current);
    }
    function cancelSeek(clear) {
      if (seek) seek.cancel();
      if (clear) { seek = null; lineStatus.textContent = ''; container.dataset && (container.dataset.textSeekState = 'idle'); }
    }
    function updateSeek(current) {
      if (disposed || seek !== current) return;
      var state = current.error ? 'error' : current.running ? 'running' : current.cancelled ? 'cancelled' : current.row !== null ? 'found' : 'missing';
      if (container.dataset) { container.dataset.textSeekState = state; container.dataset.textSeekBytes = String(current.index ? current.index.offset : 0); }
      lineStatus.textContent = current.error ? labels[current.error.code] || labels.failed : current.running
        ? labels.textJumpIndexing + ' ' + current.target.toLocaleString() + ' · ' + labels.indexed + ': ' + (current.index ? current.index.offset : 0).toLocaleString() + ' / ' + reader.size.toLocaleString() + ' B · ' + labels.lines + ': ' + current.knownLine.toLocaleString()
        : current.cancelled ? labels.textJumpStopped : current.row !== null ? labels.textJumpFound + ' ' + current.target.toLocaleString()
        : labels.textJumpMissing + ': ' + current.knownLine.toLocaleString();
      update();
    }
    async function goToLine() {
      var value = lineInput.value.trim(), target = Number(value);
      if (!/^\d{1,16}$/.test(value) || !Number.isSafeInteger(target) || target < 1) { lineStatus.textContent = labels.textJumpInvalid; return; }
      if (!reader || !reader.encoding || disposed) return;
      cancelSeek(true); clearResults(); viewRequest++;
      var token = generation, source = reader;
      var current = seek = new LineSeek(source, target, {onProgress: updateSeek});
      var task = current.run(); updateSeek(current); await task;
      if (disposed || seek !== current || token !== generation || reader !== source || current.cancelled || source.closed) return;
      if (current.error) {
        if (current.error.code === 'changed') {
          clearResults(); if (markdown) { markdown.close(); markdown = null; }
          source.close(); article.textContent = ''; rows.textContent = '';
          jumpedLine = null; pendingLine = false; failed = true; showError(current.error, token);
        }
        return;
      }
      if (source.loading) await source.loading.catch(function () {});
      if (disposed || seek !== current || token !== generation || current.cancelled) return;
      source.adopt(current.index);
      if (current.row === null) { update(); return; }
      setView(false); jumpedLine = target; pendingLine = true;
      var targetSection = Math.floor(current.row / SECTION);
      if (section !== targetSection) changeSection(targetSection);
      viewport.scrollTop = heights.offset(current.row % SECTION); update(); schedule();
    }
    lineGo.onclick = goToLine;
    lineCancel.onclick = function () { cancelSeek(false); };
    lineInput.onkeydown = function (event) {
      if (event.key === 'Enter') { event.preventDefault(); goToLine(); }
      if (event.key === 'Escape' && seek && seek.running) { event.preventDefault(); event.stopPropagation(); cancelSeek(false); }
    };
    async function findContent() {
      cancelSeek(true); jumpedLine = null; pendingLine = false;
      clearResults();
      if (!query.value || !reader || !reader.encoding || !root.LegnaTextSearch) return;
      var token = searchToken;
      search = new root.LegnaTextSearch.Search(reader, query.value, { full: scope.value === 'full', caseSensitive: sensitive.checked, onProgress: updateSearch });
      var current = search, task = current.run(); updateSearch(current); await task;
      if (!disposed && token === searchToken && search === current && current.matches.length) jump(0);
    }
    function restart() {
      cancelSeek(true); jumpedLine = null; pendingLine = false;
      generation++; viewRequest++; clearResults(); if (reader) reader.close(); if (markdown) markdown.close(); markdown = null;
      busy = false; failed = false; section = 0; heights = new Heights(0); viewport.scrollTop = 0; rows.textContent = ''; setView(false);
      hint.textContent = options.markdown ? labels.markdownHint : labels.hint;
      try { reader = new Reader(options.url, options.size, { encoding: select.value, fetch: options.fetch }); }
      catch (error) { showError(error, generation); return; }
      var current = reader;
      work(async function () { await current.init(); if (current === reader && !disposed && options.markdown) openMarkdown(); });
    }
    previous.onclick = function () { if (!busy && section > 0) changeSection(section - 1); };
    next.onclick = function () { var current = reader, target = (section + 1) * SECTION; work(async function () {
      await current.ensureRows(target + 1); if (current !== reader || disposed) return;
      if (current.rows > target) changeSection(section + 1);
    }); };
    more.onclick = function () { var current = reader; work(function () { return current.ensureRows(current.rows + 1); }); };
    retry.onclick = restart; select.onchange = restart; viewport.onscroll = schedule; wrap.onchange = numbers.onchange = resetLayout;
    viewButton.onclick = function () { if (rendered) setView(false); else openMarkdown(); };
    find.onclick = findContent; scope.onchange = sensitive.onchange = findContent;
    stop.onclick = function () { if (search) { search.cancel(); updateSearch(search); } };
    prevHit.onclick = function () { jump(selected - 1); }; nextHit.onclick = function () { jump(selected + 1); };
    clear.onclick = function () { query.value = ''; clearResults(); query.focus(); };
    query.oninput = function (event) { clearResults(); if (!event || !event.isComposing) searchTimer = setTimeout(findContent, 250); };
    query.oncompositionend = function () { clearTimeout(searchTimer); searchTimer = setTimeout(findContent, 250); };
    query.onkeydown = function (event) {
      if (event.key === 'Enter') { event.preventDefault(); clearTimeout(searchTimer); if (search && search.matches.length) jump(selected + (event.shiftKey ? -1 : 1)); else findContent(); }
      if (event.key === 'Escape' && query.value) { event.preventDefault(); event.stopPropagation(); clear.onclick(); }
    };
    container.onkeydown = function (event) { if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') { event.preventDefault(); query.focus(); query.select(); } };
    var previousWidth = 0;
    if (root.ResizeObserver) { resizeObserver = new root.ResizeObserver(function (entries) { var width = Math.round(entries[0].contentRect.width); if (width !== previousWidth) { previousWidth = width; resetLayout(); } }); resizeObserver.observe(viewport); }
    root.addEventListener('resize', resetLayout); restart();
    return { close: function () { disposed = true; cancelSeek(true); generation++; clearTimeout(searchTimer); if (search) search.cancel(); if (reader) reader.close(); if (markdown) markdown.close();
      if (resizeObserver) resizeObserver.disconnect(); root.removeEventListener('resize', resetLayout); viewport.onscroll = container.onkeydown = null; } };
  }
  var api = { Reader: Reader, LineSeek: LineSeek, parsePage: parsePage, encodingFor: encodingFor, mount: mount, Heights: Heights,
    constants: { chunk: CHUNK, segment: SEGMENT, cache: CACHE, rowHeight: ROW_HEIGHT, section: SECTION } };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.LegnaTextPreview = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
