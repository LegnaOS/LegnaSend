/* Single-lane, session-bound downloads. Never changes the LocalSend wire contract. */
(function (root) {
  'use strict';
  var CHUNK = 1024 * 1024, BUFFER_LIMIT = 32 * 1024 * 1024, TOTAL_BUFFER_LIMIT = 64 * 1024 * 1024;
  function fail(code) { return Object.assign(new Error(code), { code: code }); }
  function abortCheck(signal) { if (signal.aborted) throw fail('aborted'); }
  function status(response) {
    // An authorization failure does not establish that the approved source ended.
    // Keep the checkpoint; only an explicit retry may revalidate the old session.
    if ([401, 403].indexOf(response.status) >= 0) throw fail('authRequired');
    if ([404, 410].indexOf(response.status) >= 0) throw fail('sourceEnded');
    if ([409, 412].indexOf(response.status) >= 0) throw fail('sourceChanged');
    if (response.status === 429) throw fail('busy');
    if (!response.ok) throw fail('network');
  }
  function sourceUrl(task) {
    return '/api/localsend/v2/download?sessionId=' + encodeURIComponent(task.sessionId) + '&fileId=' + encodeURIComponent(task.fileId);
  }
  function MemorySink(size) {
    if (!Number.isSafeInteger(size) || size < 0 || size > BUFFER_LIMIT) throw fail('storageUnsupported');
    this.kind = 'memory'; this.offset = 0; this.chunks = []; this.size = size;
  }
  MemorySink.prototype.open = async function () {};
  MemorySink.prototype.write = async function (bytes, offset) {
    if (offset !== this.offset || offset + bytes.length > this.size) throw fail('storage');
    this.chunks.push(bytes); this.offset += bytes.length;
  };
  MemorySink.prototype.checkpoint = async function () { return this.offset; };
  MemorySink.prototype.discard = async function () { this.chunks = []; this.offset = 0; };
  MemorySink.prototype.blob = function () {
    if (this.offset !== this.size) throw fail('incomplete');
    return new Blob(this.chunks, { type: 'application/octet-stream' });
  };
  // The chosen file is committed on pause/failure/completion, not on each range.
  // Cancellation never deletes a user-owned file; a previous checkpoint stays intact.
  function DiskSink(handle) { this.kind = 'disk'; this.handle = handle; this.writer = null; this.offset = 0; this.committed = 0; this.stamp = null; }
  DiskSink.prototype.open = async function () {
    var file; try { file = await this.handle.getFile(); } catch (_) { throw fail('storage'); }
    if (this.stamp !== null && (file.size !== this.committed || file.lastModified !== this.stamp)) throw fail('localChanged');
    try {
      this.writer = await this.handle.createWritable({ keepExistingData: this.stamp !== null });
      await this.writer.truncate(this.committed); this.offset = this.committed;
    } catch (error) { await this.discard(); throw fail('storage'); }
  };
  DiskSink.prototype.write = async function (bytes, offset) {
    if (!this.writer || offset !== this.offset) throw fail('storage');
    try { await this.writer.write({ type: 'write', position: offset, data: bytes }); this.offset += bytes.length; }
    catch (_) { await this.discard(); throw fail('storage'); }
  };
  DiskSink.prototype.checkpoint = async function () {
    if (!this.writer) return this.committed;
    var writer = this.writer; this.writer = null;
    try {
      await writer.close();
      var file = await this.handle.getFile();
      if (file.size !== this.offset) throw fail('storage');
      this.committed = file.size; this.stamp = file.lastModified; return this.committed;
    } catch (error) {
      try { await writer.abort(); } catch (_) {}
      this.offset = this.committed; throw fail('storage');
    }
  };
  DiskSink.prototype.discard = async function () {
    if (this.writer) { var writer = this.writer; this.writer = null; try { await writer.abort(); } catch (_) {} }
    this.offset = this.committed;
  };
  function Manager(options) {
    options = options || {}; this.fetch = options.fetch || root.fetch.bind(root); this.onChange = options.onChange || function () {};
    this.now = options.now || function () { return root.performance.now(); }; this.timeout = options.timeout || 30000;
    this.chunkSize = Math.min(CHUNK, options.chunkSize || CHUNK); this.tasks = []; this.active = null; this.closed = false; this.timer = null;
  }
  Manager.prototype.emit = function () { if (!this.closed) this.onChange(this.tasks); };
  Manager.prototype.add = function (source, sink) {
    if (this.closed || this.tasks.length >= 20) throw fail('taskLimit');
    if (!source.sessionId || !source.fileId || !Number.isSafeInteger(source.size) || source.size < 0) throw fail('sourceChanged');
    var reserved = this.tasks.reduce(function (sum, task) { return sum + (task.sink.kind === 'memory' && task.state !== 'cancelled' ? task.size : 0); }, 0);
    if (sink.kind === 'memory' && reserved + source.size > TOTAL_BUFFER_LIMIT) throw fail('memoryBudget');
    var task = { sessionId: source.sessionId, fileId: source.fileId, name: String(source.name), size: source.size,
      sink: sink, offset: 0, etag: null, state: 'ready', error: null, speed: null, samples: [], wireBytes: 0, stop: null, promise: null };
    this.tasks.push(task); this.emit(); return task;
  };
  Manager.prototype.start = function (task) {
    if (this.closed || !this.tasks.includes(task) || task.promise || ['ready', 'paused', 'failed'].indexOf(task.state) < 0) return;
    task.stop = null; task.error = null; task.state = 'queued'; this.emit(); this.pump();
  };
  Manager.prototype.pump = function () {
    if (this.closed || this.active) return;
    var task = this.tasks.find(function (t) { return t.state === 'queued'; }); if (!task) return;
    this.active = task; task.controller = new AbortController(); task.samples = []; task.speed = null; task.wireBytes = 0;
    var self = this;
    this.timer = setInterval(function () {
      var now = self.now(), points = task.samples; points.push({ time: now, bytes: task.wireBytes });
      while (points.length > 2 && points[1].time <= now - 3000) points.shift();
      while (points.length > 32) points.splice(1, 1);
      var elapsed = now - points[0].time;
      task.speed = task.state === 'downloading' && elapsed >= 250 ? Math.round((task.wireBytes - points[0].bytes) * 1000 / elapsed) : null;
      self.emit();
    }, 500);
    task.promise = this.run(task).finally(function () {
      clearInterval(self.timer); self.timer = null; task.promise = null; task.controller = null; task.speed = null;
      self.active = null; self.emit(); self.pump();
    });
  };
  Manager.prototype.request = async function (task, url, options, consume) {
    var controller = new AbortController(), signal = task.controller.signal, expired = false;
    function abort() { controller.abort(); }
    signal.addEventListener('abort', abort, { once: true });
    var timer = setTimeout(function () { expired = true; controller.abort(); }, this.timeout), response;
    try {
      abortCheck(signal);
      response = await this.fetch(url, Object.assign({ cache: 'no-store', credentials: 'same-origin', redirect: 'error' }, options, { signal: controller.signal }));
      abortCheck(signal); status(response); return await consume(response, controller.signal);
    } catch (error) { if (expired && !signal.aborted) throw fail('timeout'); throw error; }
    finally {
      // Also cancel rejected 200/oversized/malformed bodies instead of downloading them in the background.
      if (response && response.body && !response.body.locked) try { await response.body.cancel(); } catch (_) {}
      clearTimeout(timer); signal.removeEventListener('abort', abort);
    }
  };
  Manager.prototype.inspect = async function (task) {
    await this.request(task, sourceUrl(task), { method: 'HEAD', headers: task.etag ? { 'If-Match': task.etag } : {} }, async function (response) {
      var tag = response.headers.get('ETag'), length = response.headers.get('Content-Length');
      if (response.status !== 200 || length !== String(task.size)) throw fail('sourceChanged');
      if (response.headers.get('Accept-Ranges') !== 'bytes' || !tag || !/^"[^"\r\n]+"$/.test(tag)) throw fail('rangeUnsupported');
      if (task.etag && task.etag !== tag) throw fail('sourceChanged'); task.etag = tag;
    });
  };
  Manager.prototype.revalidate = async function (task) {
    // HEAD authenticates the *old* session first, avoiding a new approval dialog after it expires.
    await this.inspect(task);
    await this.request(task, '/api/localsend/v2/prepare-download?sessionId=' + encodeURIComponent(task.sessionId), { method: 'POST' }, async function (response) {
      var data = await response.json(), file = data.files && data.files[task.fileId];
      if (data.sessionId !== task.sessionId || !file || file.fileName !== task.name || file.size !== task.size) throw fail('sourceChanged');
    });
  };
  Manager.prototype.range = async function (task, start, end) {
    return this.request(task, sourceUrl(task), { headers: { Range: 'bytes=' + start + '-' + end, 'If-Match': task.etag } }, async function (response, signal) {
      var expected = end - start + 1;
      if (response.status !== 206 || response.headers.get('Content-Range') !== 'bytes ' + start + '-' + end + '/' + task.size ||
          response.headers.get('Content-Length') !== String(expected) || response.headers.get('ETag') !== task.etag) throw fail('invalidRange');
      if (!response.body || !response.body.getReader) throw fail('rangeUnsupported');
      var reader = response.body.getReader(), buffer = new Uint8Array(expected), length = 0;
      try {
        while (true) {
          abortCheck(signal); var part = await reader.read(); abortCheck(signal); if (part.done) break;
          if (length + part.value.length > expected) throw fail('invalidRange');
          buffer.set(part.value, length); length += part.value.length; task.wireBytes += part.value.length;
        }
        if (length !== expected) throw fail('shortResponse'); return buffer;
      } finally { try { await reader.cancel(); } catch (_) {} reader.releaseLock(); }
    });
  };
  Manager.prototype.run = async function (task) {
    try {
      task.state = 'checking'; this.emit(); await this.revalidate(task); abortCheck(task.controller.signal);
      await task.sink.open(); abortCheck(task.controller.signal); task.state = 'downloading'; this.emit();
      while (task.offset < task.size) {
        var bytes = await this.range(task, task.offset, Math.min(task.size, task.offset + this.chunkSize) - 1);
        abortCheck(task.controller.signal);
        try { await task.sink.write(bytes, task.offset); } catch (error) { throw fail(error.code || 'storage'); }
        task.offset = task.sink.offset; this.emit(); abortCheck(task.controller.signal);
      }
      // Recheck source even for zero-byte files and after the final chunk.
      await this.inspect(task); abortCheck(task.controller.signal);
      task.state = 'saving'; this.emit(); task.offset = await task.sink.checkpoint();
      if (task.offset !== task.size) throw fail('incomplete');
      task.state = task.stop === 'cancel' ? 'cancelled' : 'complete';
    } catch (error) {
      if (task.stop === 'cancel') { await task.sink.discard(); task.offset = task.sink.offset; task.state = 'cancelled'; }
      else {
        var code = error.code || (error.name === 'QuotaExceededError' ? 'storage' : 'network');
        try { task.offset = await task.sink.checkpoint(); } catch (_) { code = 'storage'; task.offset = task.sink.offset; }
        task.error = code;
        var terminal = ['sourceEnded', 'sourceChanged', 'localChanged', 'rangeUnsupported'].includes(code);
        task.state = terminal ? 'blocked' : task.stop === 'pause' && code !== 'storage' ? 'paused' : 'failed';
        if (task.state === 'paused') task.error = null;
      }
    } finally {
      if (task.stop === 'cancel') { await task.sink.discard(); task.offset = task.sink.offset; task.state = 'cancelled'; }
    }
  };
  Manager.prototype.pause = async function (task) {
    if (!this.tasks.includes(task)) return;
    if (task.state === 'queued' || task.state === 'ready') { task.state = 'paused'; this.emit(); return; }
    if (!task.promise || task.state === 'saving') return;
    task.stop = 'pause'; task.state = 'pausing'; task.controller.abort(); this.emit(); await task.promise;
  };
  Manager.prototype.cancel = async function (task) {
    if (!this.tasks.includes(task)) return;
    task.stop = 'cancel';
    if (task.promise) { task.state = 'cancelling'; task.controller.abort(); this.emit(); await task.promise; }
    else { await task.sink.discard(); task.offset = task.sink.offset; task.state = 'cancelled'; this.emit(); }
  };
  Manager.prototype.remove = async function (task) {
    await this.cancel(task); this.tasks = this.tasks.filter(function (t) { return t !== task; }); this.emit();
  };
  Manager.prototype.close = function () {
    this.closed = true; this.tasks.forEach(function (task) { if (task.controller) { task.stop = 'pause'; task.controller.abort(); } });
    if (this.timer) clearInterval(this.timer);
  };
  var api = { Manager: Manager, MemorySink: MemorySink, DiskSink: DiskSink, sourceUrl: sourceUrl,
    CHUNK: CHUNK, BUFFER_LIMIT: BUFFER_LIMIT, TOTAL_BUFFER_LIMIT: TOTAL_BUFFER_LIMIT };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.LegnaDownloads = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
