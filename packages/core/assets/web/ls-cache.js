/* Browser adapter for docs/LS_CACHE_FORMAT.md. Call under a task Web Lock.
 * createWritable is copy-on-write; close is a checkpoint, not native fsync.
 * No file-size-dependent in-memory sink and no OPFS substitution for Downloads.
 */
(function (root) {
  'use strict';
  var sha = root.LegnaSha256 || (typeof require === 'function' ? require('./sha256.js') : null);
  if (!sha || typeof TextEncoder !== 'function' || typeof TextDecoder !== 'function') return;
  var encode = new TextEncoder(),
    decode = new TextDecoder('utf-8', { fatal: true });
  var MAGIC = encode.encode('LEGNALS\0'),
    RECORD = encode.encode('LSCHUNK1'),
    COMMIT = encode.encode('LSDONE1\0'),
    MIN = 65536,
    MAX = 8388608,
    COUNT = 1048576;
  function fail(code) {
    return Object.assign(new Error(code), { code: code });
  }
  function equal(a, b) {
    return (
      a.length === b.length &&
      a.every(function (v, i) {
        return v === b[i];
      })
    );
  }
  function cancel(signal) {
    if (signal && signal.aborted) throw fail('aborted');
  }
  function text(s, max) {
    return typeof s === 'string' && s.length > 0 && encode.encode(s).length <= max && !/[\u0000-\u001f\u007f-\u009f]/.test(s);
  }
  var fields = ['taskId', 'sourceId', 'resourceId', 'version', 'fileName', 'size', 'chunkSize', 'createdUnixMs', 'sha256'];
  function validate(id) {
    if (
      !id ||
      Object.keys(id).length !== fields.length ||
      !fields.every(function (k) {
        return Object.prototype.hasOwnProperty.call(id, k);
      }) ||
      !/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(id.taskId) ||
      !text(id.sourceId, 2048) ||
      !text(id.resourceId, 4096) ||
      !text(id.version, 1024) ||
      typeof id.fileName !== 'string' ||
      !id.fileName.length ||
      encode.encode(id.fileName).length > 4096 ||
      id.fileName.includes('\0') ||
      !Number.isSafeInteger(id.size) ||
      id.size < 0 ||
      !Number.isInteger(id.chunkSize) ||
      id.chunkSize < MIN ||
      id.chunkSize > MAX ||
      Math.ceil(id.size / id.chunkSize) > COUNT ||
      !Number.isSafeInteger(id.createdUnixMs) ||
      id.createdUnixMs < 0 ||
      (id.sha256 !== null && !/^[\da-f]{64}$/i.test(id.sha256))
    )
      throw fail('cacheFormat');
    return id;
  }
  function same(a, b) {
    return fields.every(function (k) {
      return a[k] === b[k];
    });
  }
  function length(id, index) {
    if (!Number.isInteger(index) || index < 0 || index >= Math.ceil(id.size / id.chunkSize)) throw fail('cacheFormat');
    return Math.min(id.chunkSize, id.size - index * id.chunkSize);
  }
  async function read(file, start, size) {
    var b = new Uint8Array(await file.slice(start, start + size).arrayBuffer());
    if (b.length !== size) throw fail('cacheFormat');
    return b;
  }
  async function header(file) {
    if (file.size < 48) throw fail('cacheFormat');
    var prefix = await read(file, 0, 16),
      view = new DataView(prefix.buffer),
      n = view.getUint32(12, true);
    if (!equal(prefix.subarray(0, 8), MAGIC) || view.getUint32(8, true) !== 1 || !n || n > 16384 || file.size < 48 + n)
      throw fail('cacheFormat');
    var json = await read(file, 16, n),
      hash = sha.digest(concat(prefix, json));
    if (!equal(hash, await read(file, 16 + n, 32))) throw fail('cacheFormat');
    var id;
    try {
      id = JSON.parse(decode.decode(json));
    } catch (_) {
      throw fail('cacheFormat');
    }
    return { id: validate(id), end: 48 + n };
  }
  function concat(a, b) {
    var out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
  }
  function stamp(file) {
    return { size: file.size, modified: file.lastModified };
  }
  function unchanged(file, mark) {
    return file.size === mark.size && file.lastModified === mark.modified;
  }
  function Cache(handle, id) {
    this.handle = handle;
    this.id = validate(id);
    this.offsets = new Float64Array(Math.ceil(id.size / id.chunkSize));
    this.bytes = 0;
    this.end = 0;
    this.stamp = null;
    this.busy = false;
    this.healthy = false;
    this.writer = null;
    this.pending = [];
    this.stagedBytes = 0;
  }
  Cache.prototype.check = function () {
    if (this.busy || !this.healthy) throw fail('localChanged');
  };
  Cache.prototype.current = async function () {
    var file = await this.handle.getFile();
    if (!this.stamp || !unchanged(file, this.stamp)) throw fail('localChanged');
    return file;
  };
  Cache.prototype.initialize = async function () {
    var old = await this.handle.getFile();
    if (old.size) throw fail('localChanged');
    var json = encode.encode(JSON.stringify(this.id));
    if (json.length > 16384) throw fail('cacheFormat');
    var prefix = new Uint8Array(16),
      view = new DataView(prefix.buffer);
    prefix.set(MAGIC);
    view.setUint32(8, 1, true);
    view.setUint32(12, json.length, true);
    var bytes = concat(prefix, json),
      writer;
    try {
      writer = await this.handle.createWritable({ mode: 'exclusive' });
      if ((await this.handle.getFile()).size) throw fail('localChanged');
      await writer.write(bytes);
      await writer.write(sha.digest(bytes));
      await writer.close();
      writer = null;
      var file = await this.handle.getFile();
      this.end = file.size;
      if (this.end !== bytes.length + 32) throw fail('storage');
      this.stamp = stamp(file);
      this.healthy = true;
    } finally {
      if (writer)
        try {
          await writer.abort();
        } catch (_) {}
    }
    return this;
  };
  Cache.prototype.record = async function (file, position, output, whole, signal) {
    cancel(signal);
    var h = await read(file, position, 16),
      v = new DataView(h.buffer),
      index = v.getUint32(8, true),
      size = v.getUint32(12, true);
    if (!equal(h.subarray(0, 8), RECORD) || length(this.id, index) !== size) throw fail('cacheFormat');
    if (file.size - position < 56 + size) return { incomplete: true, index: index, size: size };
    var hash = new sha.Hash().update(h);
    for (var n = 0; n < size; n += 65536) {
      cancel(signal);
      var b = await read(file, position + 16 + n, Math.min(65536, size - n));
      hash.update(b);
      if (whole) whole.update(b);
      if (output) await output.write(b);
    }
    if (!equal(hash.digest(), await read(file, position + 16 + size, 32)) || !equal(COMMIT, await read(file, position + 48 + size, 8)))
      throw fail('cacheFormat');
    return { index: index, size: size, end: position + 56 + size };
  };
  Cache.prototype.recover = async function (signal, onProgress) {
    if (this.busy || this.writer) throw fail('busy');
    this.busy = true;
    this.healthy = false;
    try {
      var file = await this.handle.getFile(),
        meta = await header(file);
      if (!same(meta.id, this.id)) throw fail('localChanged');
      this.offsets.fill(0);
      this.bytes = 0;
      this.end = meta.end;
      while (this.end < file.size) {
        cancel(signal);
        if (file.size - this.end < 16) break;
        var rec = await this.record(file, this.end, null, null, signal);
        if (this.offsets[rec.index]) throw fail('cacheFormat');
        if (rec.incomplete) break;
        this.offsets[rec.index] = this.end;
        this.end = rec.end;
        this.bytes += rec.size;
        if (onProgress) onProgress(this.bytes);
      }
      cancel(signal);
      var discarded = file.size - this.end;
      if (discarded) {
        var writer;
        try {
          writer = await this.handle.createWritable({ keepExistingData: true, mode: 'exclusive' });
          if (!unchanged(await this.handle.getFile(), stamp(file))) throw fail('localChanged');
          await writer.truncate(this.end);
          await writer.close();
          writer = null;
        } finally {
          if (writer)
            try {
              await writer.abort();
            } catch (_) {}
        }
        file = await this.handle.getFile();
      }
      this.stamp = stamp(file);
      this.healthy = true;
      return { bytes: this.bytes, discarded: discarded };
    } finally {
      this.busy = false;
    }
  };
  Cache.prototype.missing = function () {
    var out = [];
    for (var i = 0; i < this.offsets.length; i++) if (!this.offsets[i]) out.push(i);
    return out;
  };
  Cache.prototype.abortStaged = async function () {
    var writer = this.writer;
    this.writer = null;
    this.pending = [];
    this.stagedBytes = 0;
    if (writer)
      try {
        await writer.abort();
      } catch (_) {}
  };
  Cache.prototype.stage = async function (chunks) {
    this.check();
    this.busy = true;
    this.healthy = false;
    try {
      await this.current();
      var seen = new Set(
        this.pending.map(function (p) {
          return p.index;
        })
      );
      for (var chunk of chunks) {
        if (
          !(chunk.bytes instanceof Uint8Array) ||
          chunk.bytes.length !== length(this.id, chunk.index) ||
          seen.has(chunk.index) ||
          this.offsets[chunk.index]
        )
          throw fail('cacheFormat');
        seen.add(chunk.index);
      }
      if (chunks.length && !this.writer) {
        this.writer = await this.handle.createWritable({ keepExistingData: true, mode: 'exclusive' });
        await this.current();
        await this.writer.seek(this.end);
        this.writeEnd = this.end;
      }
      for (var part of chunks) {
        var record = new Uint8Array(16),
          view = new DataView(record.buffer);
        record.set(RECORD);
        view.setUint32(8, part.index, true);
        view.setUint32(12, part.bytes.length, true);
        var digest = new sha.Hash().update(record).update(part.bytes).digest();
        await this.writer.write(record);
        await this.writer.write(part.bytes);
        await this.writer.write(digest);
        await this.writer.write(COMMIT);
        this.pending.push({ index: part.index, offset: this.writeEnd, size: part.bytes.length });
        this.writeEnd += 56 + part.bytes.length;
        this.stagedBytes += part.bytes.length;
      }
      this.healthy = true;
    } catch (error) {
      await this.abortStaged();
      throw error;
    } finally {
      this.busy = false;
    }
  };
  Cache.prototype.checkpoint = async function () {
    this.check();
    if (!this.writer) return this.bytes;
    this.busy = true;
    this.healthy = false;
    try {
      await this.current();
      await this.writer.close();
      this.writer = null;
      var file = await this.handle.getFile();
      if (file.size !== this.writeEnd) throw fail('storage');
      this.pending.forEach(function (p) {
        this.offsets[p.index] = p.offset;
        this.bytes += p.size;
      }, this);
      this.end = this.writeEnd;
      this.stamp = stamp(file);
      this.pending = [];
      this.stagedBytes = 0;
      this.healthy = true;
      return this.bytes;
    } catch (error) {
      await this.abortStaged();
      throw error;
    } finally {
      this.busy = false;
    }
  };
  Cache.prototype.commit = async function (chunks) {
    await this.stage(chunks);
    return this.checkpoint();
  };
  Cache.prototype.export = async function (output, options) {
    options = options || {};
    this.check();
    if (this.bytes !== this.id.size) throw fail('incomplete');
    this.busy = true;
    var writer;
    try {
      cancel(options.signal);
      var file = await this.current(),
        old = await output.getFile();
      if (old.size) throw fail('localChanged');
      writer = await output.createWritable({ mode: 'exclusive' });
      if ((await output.getFile()).size) throw fail('localChanged');
      var hash = new sha.Hash(),
        bytes = 0;
      for (var i = 0; i < this.offsets.length; i++) {
        var rec = await this.record(file, this.offsets[i], writer, hash, options.signal);
        if (rec.incomplete || rec.index !== i) throw fail('cacheFormat');
        bytes += rec.size;
        if (options.onProgress) options.onProgress(bytes);
      }
      cancel(options.signal);
      var receipt = { bytes: bytes, sha256: sha.hex(hash.digest()) };
      if (this.id.sha256 && receipt.sha256 !== this.id.sha256.toLowerCase()) throw fail('checksum');
      if (options.beforePublish) await options.beforePublish(receipt);
      cancel(options.signal);
      await writer.close();
      writer = null;
      if ((await output.getFile()).size !== bytes) throw fail('storage');
      return receipt;
    } finally {
      if (writer)
        try {
          await writer.abort();
        } catch (_) {}
      this.busy = false;
    }
  };
  async function matchesOutput(handle, receipt, signal) {
    var file = await handle.getFile();
    if (file.size !== receipt.bytes) return false;
    var hash = new sha.Hash();
    for (var p = 0; p < file.size; p += 65536) {
      cancel(signal);
      hash.update(await read(file, p, Math.min(65536, file.size - p)));
    }
    return sha.hex(hash.digest()) === receipt.sha256;
  }
  function safeName(name) {
    var base = String(name)
      .split(/[\\/]/)
      .pop()
      .replace(/[<>:"|?*\u0000-\u001f]/g, '-')
      .replace(/[ .]+$/g, '');
    while (encode.encode(base).length > 140) base = Array.from(base).slice(0, -1).join('');
    base = base.replace(/[ .]+$/g, '');
    return !base || /^\.+$/.test(base) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(base) ? 'download-' + base : base;
  }
  async function fresh(directory, name) {
    try {
      await directory.getFileHandle(name);
      throw fail('localChanged');
    } catch (e) {
      if (e.name === 'TypeMismatchError') throw fail('localChanged');
      if (e.name !== 'NotFoundError') throw e;
    }
    var handle = await directory.getFileHandle(name, { create: true });
    if ((await handle.getFile()).size) throw fail('localChanged');
    return handle;
  }
  var api = {
    Cache: Cache,
    header: header,
    validate: validate,
    same: same,
    read: read,
    matchesOutput: matchesOutput,
    safeName: safeName,
    fresh: fresh,
    fail: fail,
    MIN: MIN,
    MAX: MAX,
    COUNT: COUNT
  };
  if (typeof module === 'object') module.exports = api;
  root.LegnaLsCache = api;
})(typeof globalThis === 'object' ? globalThis : this);
