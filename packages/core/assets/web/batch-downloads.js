/* Persistent original-file batches: two live file jobs and paged metadata.
 * File writers, source validators and the network budget are shared. */
(function (root) {
  'use strict';
  var engine = root.LegnaPersistentDownloads || (typeof require === 'function' ? require('./persistent-downloads.js') : null);
  var MAX = 100000,
    NAME_BYTES = 16 * 1024 * 1024,
    META_BYTES = 32 * 1024 * 1024;
  function fail(code) {
    return Object.assign(new Error(code), { code: code });
  }
  function alive(signal) {
    if (signal.aborted) throw fail('aborted');
  }
  function pathParts(path) {
    if (typeof path !== 'string' || !path || path.length > 4096 || /[\\:<>\x00-\x1f\x7f"|?*]/.test(path)) throw fail('archiveConflict');
    var parts = path.split('/');
    if (parts.length > 64) throw fail('archiveLimit');
    parts.forEach(function (p) {
      if (new TextEncoder().encode(p).length > 255) throw fail('archiveConflict');
      if (!p || p === '.' || p === '..' || /[. ]$/.test(p) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(p))
        throw fail('archiveConflict');
    });
    return parts;
  }
  function Planner(id, registry, signal) {
    this.id = id;
    this.registry = registry;
    this.signal = signal;
    this.names = new Map();
    this.explicit = new Set();
    this.buffer = [];
    this.count = 0;
    this.files = 0;
    this.bytes = 0;
    this.nameBytes = 0;
    this.metaBytes = 0;
    this.treeBytes = 0;
  }
  Planner.prototype.add = async function (path, source) {
    alive(this.signal);
    var parts = pathParts(path),
      self = this;
    this.nameBytes += new TextEncoder().encode(path).length;
    if (++this.count > MAX || this.nameBytes > NAME_BYTES) throw fail('archiveLimit');
    parts.forEach(function (_, i) {
      var spelling = parts.slice(0, i + 1).join('/'),
        key = spelling.normalize('NFC').toLowerCase(),
        directory = i < parts.length - 1 || !source,
        old = self.names.get(key);
      if (old && (old.spelling !== spelling || old.directory !== directory)) throw fail('archiveConflict');
      if (!old) {
        self.treeBytes += new TextEncoder().encode(spelling).length;
        if (self.treeBytes > NAME_BYTES || self.names.size >= MAX * 2) throw fail('archiveLimit');
      }
      self.names.set(key, { spelling: spelling, directory: directory });
    });
    var key = path.normalize('NFC').toLowerCase();
    if (this.explicit.has(key)) throw fail('archiveConflict');
    this.explicit.add(key);
    var item = { batchId: this.id, index: this.count - 1, path: path, source: source ? engine.validSource(source) : null };
    this.metaBytes += new TextEncoder().encode(JSON.stringify(item)).length;
    if (this.metaBytes > META_BYTES) throw fail('archiveLimit');
    if (source) {
      this.files++;
      this.bytes += source.size;
      if (!Number.isSafeInteger(this.bytes)) throw fail('archiveLimit');
    }
    this.buffer.push(item);
    if (this.buffer.length >= 100) await this.flush();
  };
  Planner.prototype.flush = async function () {
    alive(this.signal);
    if (this.buffer.length) {
      await this.registry.putBatchItems(this.buffer);
      this.buffer = [];
    }
    await new Promise(function (r) {
      setTimeout(r, 0);
    });
  };
  function Manager(options) {
    this.manager = options.manager;
    this.registry = this.manager.registry;
    this.locks = this.manager.locks;
    this.fetch = this.manager.fetch;
    this.onChange = options.onChange || function () {};
    this.onInvalidated = options.onInvalidated || function () {};
    this.batches = [];
    this.closed = false;
    this.running = null;
    this.serial = Promise.resolve();
    this.ready = this.restore();
  }
  Manager.prototype.emit = function () {
    if (!this.closed) this.onChange();
  };
  Manager.prototype.object = function (record) {
    return {
      isBatch: true,
      id: record.id,
      name: record.name,
      record: record,
      state: ['complete', 'cancelled'].includes(record.state) ? record.state : 'paused',
      error: record.error || null,
      promise: null,
      controller: null,
      wireBytes: 0,
      wireRetired: new WeakSet(),
      rateSamples: [],
    };
  };
  Manager.prototype.restore = async function () {
    await this.manager.ready;
    var self = this;
    (await this.registry.batches()).slice(0, 8).forEach(function (r) {
      if (r && r.version === 1 && r.directory && r.source && Number.isSafeInteger(r.cursor)) self.batches.push(self.object(r));
    });
    // Older journals receive a grace period, never an invented historical age.
    for (var b of this.batches) {
      await this.locks.request('legnasend-batch:' + b.id, { ifAvailable: true }, async function (lock) {
        if (!lock) return;
        var latest = await self.registry.batch(b.id);
        if (latest && !Number.isSafeInteger(latest.updatedUnixMs)) {
          latest.updatedUnixMs = self.manager.wallNow();
          await self.registry.putBatch(latest);
          b.record = latest;
        }
      });
    }
    this.cleanupHook = this.cleanupExpired.bind(this);
    this.manager.batchCleanup = this.cleanupHook;
    await this.manager.cleanupExpired();
    this.emit();
  };
  Manager.prototype.list = function () {
    var self = this;
    return this.batches.map(function (b) {
      var tasks = self.manager.tasks.filter(function (t) {
        return (
          t.record.batchId === b.id &&
          !b.record.active.some(function (a) {
            return a.id === t.id && a.complete;
          })
        );
      });
      b.size = b.record.bytes || 0;
      b.offset = Math.min(
        b.size,
        (b.record.savedBytes || 0) +
          tasks.reduce(function (n, t) {
            return n + t.offset;
          }, 0),
      );
      b.speed = self.speed(b);
      b.pendingBytes = tasks.reduce(function (n, t) {
        return n + (t.pendingBytes || 0);
      }, 0);
      return b;
    });
  };
  // Measure the whole batch, not just whichever tiny files happen to be live.
  // Only HTTP body bytes count: recovered checkpoints and published receipts do not.
  Manager.prototype.speed = function (b) {
    if (b.state !== 'downloading') {
      b.rateSamples = [];
      return null;
    }
    var now = this.manager.now(),
      wire = b.wireBytes + this.manager.tasks.reduce(function (sum, task) {
        return sum + (task.record.batchId === b.id && !b.wireRetired.has(task) ? task.wire || 0 : 0);
      }, 0),
      samples = b.rateSamples;
    if (!samples.length || now - samples[samples.length - 1].time >= 250) samples.push({ time: now, bytes: wire });
    while (samples.length > 2 && samples[1].time <= now - 3000) samples.shift();
    var elapsed = now - samples[0].time;
    return elapsed >= 250 ? Math.max(0, wire - samples[0].bytes) * 1000 / elapsed : null;
  };
  Manager.prototype.save = function (b) {
    b.record.state = b.state;
    b.record.error = b.error;
    b.record.updatedUnixMs = this.manager.wallNow();
    return this.registry.putBatch(b.record);
  };
  Manager.prototype.transaction = function (operation) {
    var next = this.serial.then(operation);
    this.serial = next.catch(function () {});
    return next;
  };
  // Called with the batch lock held. Never request permissions or recurse through
  // the user's directory: only journal-owned cache/empty placeholder handles qualify.
  Manager.prototype.cleanRecords = async function (id) {
    await this.manager.refreshBatch(id);
    var tasks = this.manager.tasks.filter(function (task) { return task.record.batchId === id; });
    for (var task of tasks) {
      var directory = task.record.directory;
      if (!directory.queryPermission || await directory.queryPermission({ mode: 'readwrite' }) !== 'granted') throw fail('permission');
    }
    for (var task of tasks) await this.manager.remove(task);
    await this.registry.removeBatch(id);
    this.batches = this.batches.filter(function (b) { return b.id !== id; });
    this.emit();
  };
  Manager.prototype.cleanupExpired = async function (days, report) {
    if (this.closed || !days) return;
    var self = this, before = this.manager.wallNow() - days * 86400000;
    function eligible(record) {
      return record && !['complete', 'cancelled'].includes(record.state) &&
        Number.isSafeInteger(record.updatedUnixMs) && record.updatedUnixMs > 0 && record.updatedUnixMs <= before;
    }
    var records = await this.registry.batches();
    for (var original of records.slice(0, 8)) {
      if (this.closed || this.manager.closed) break;
      if (!eligible(original)) { report.skipped++; continue; }
      var local = this.batches.find(function (b) { return b.id === original.id; });
      if (local && (local.promise || local.wantsRun)) { report.retained++; continue; }
      try {
        await this.locks.request('legnasend-batch:' + original.id, { ifAvailable: true }, async function (lock) {
          if (!lock) { report.retained++; return; }
          var latest = await self.registry.batch(original.id);
          if (!eligible(latest)) { report.skipped++; return; }
          if (self.registry.retention && await self.registry.retention() !== days) { report.retained++; return; }
          if (!latest.directory.queryPermission || await latest.directory.queryPermission({ mode: 'readwrite' }) !== 'granted') {
            report.retained++; return;
          }
          // A child checkpoint can be newer than its parent journal after a crash.
          var children = (await self.registry.all()).filter(function (r) { return r.batchId === original.id; });
          if (children.some(function (r) { return r.updatedUnixMs > before; })) { report.retained++; return; }
          await self.cleanRecords(original.id);
          report.removed++;
        });
      } catch (e) {
        if (['permission', 'busy'].includes(engine.code(e))) report.retained++;
        else report.failed++;
      }
    }
  };
  Manager.prototype.create = async function (spec) {
    // Acquire permission in the user gesture, not later in a worker.
    var chosen = this.manager.choose();
    await this.ready;
    var directory = await chosen;
    if (this.closed) throw fail('aborted');
    var source;
    if (spec.kind === 'web') {
      if (
        !Array.isArray(spec.ids) ||
        !spec.ids.length ||
        spec.ids.length > MAX ||
        spec.ids.some(function (id) {
          return typeof id !== 'string' || id.length > 4096;
        })
      )
        throw fail('archiveLimit');
      source = { kind: 'web', ids: Array.from(new Set(spec.ids)) };
      if (new TextEncoder().encode(JSON.stringify(source)).length > NAME_BYTES) throw fail('archiveLimit');
    } else if (
      spec.kind === 'directory' &&
      typeof spec.workspaceId === 'string' &&
      Number.isSafeInteger(spec.generation) &&
      spec.generation > 0
    ) {
      if (spec.path) pathParts(spec.path);
      source = { kind: 'directory', workspaceId: spec.workspaceId, generation: spec.generation, path: spec.path || '' };
    } else throw fail('sourceChanged');
    var r = {
      version: 1,
      updatedUnixMs: this.manager.wallNow(),
      id: root.crypto.randomUUID(),
      name: String(spec.name || 'LegnaSend').slice(0, 180),
      source: source,
      directory: directory,
      state: 'paused',
      error: null,
      planned: false,
      cursor: 0,
      count: 0,
      files: 0,
      bytes: 0,
      savedFiles: 0,
      savedBytes: 0,
      active: [],
    };
    var self = this;
    await this.locks.request('legnasend-batch-registry', {}, async function () {
      var known=await self.registry.batches();
      for(var old of known) {
        if(known.length<8)break;
        if(old.state!=='complete')continue;
        var live=self.batches.find(function(item){return item.id===old.id;});
        if(live&&live.promise)continue;
        await self.locks.request('legnasend-batch:'+old.id,{ifAvailable:true},async function(lock){
          if(!lock)return;
          var current=await self.registry.batch(old.id);
          if(!current||current.state!=='complete'||(await self.registry.all()).some(function(t){return t.batchId===old.id;}))return;
          await self.registry.removeBatch(old.id); // Receipts only; preserve the directory and all completed files.
          self.batches=self.batches.filter(function(item){return item.id!==old.id;});
          known=known.filter(function(item){return item.id!==old.id;});
        });
      }
      if (known.length >= 8) throw fail('taskLimit');
      await self.registry.putBatch(r);
    });
    var b = this.object(r);
    this.batches.push(b);
    this.emit();
    this.run(b);
    return b;
  };
  Manager.prototype.start = async function (b) {
    if (b.promise || b.state === 'complete' || this.closed) return;
    try {
      await this.manager.permission(b.record.directory);
      var self = this;
      await this.locks.request('legnasend-batch:' + b.id, { ifAvailable: true }, async function (lock) {
        if (!lock) throw fail('busy');
        var latest = await self.registry.batch(b.id);
        if (!latest) throw fail('sourceEnded');
        // Persist the user action before queuing: another tab must not expire an
        // old journal while this page waits for its earlier batch to finish.
        latest.updatedUnixMs = self.manager.wallNow();
        await self.registry.putBatch(latest);
        b.record = latest;
      });
      this.run(b);
    } catch (e) {
      b.state = 'failed';
      b.error = engine.code(e);
      this.emit();
    }
  };
  Manager.prototype.readPage = async function (url, signal) {
    var controller = new AbortController(),
      timer = setTimeout(function () {
        controller.abort();
      }, 30000),
      reader;
    function stop() {
      controller.abort();
    }
    signal.addEventListener('abort', stop, { once: true });
    if (signal.aborted) stop();
    try {
      var response = await this.fetch(url, { credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: controller.signal });
      if ([401, 403].includes(response.status)) throw fail('authRequired');
      if ([404, 410].includes(response.status)) throw fail('sourceEnded');
      if ([409, 412].includes(response.status)) throw fail('sourceChanged');
      if (!response.ok) throw fail('network');
      reader = response.body.getReader();
      var chunks = [],
        length = 0;
      while (true) {
        alive(signal);
        var next = await reader.read();
        if (next.done) break;
        length += next.value.length;
        if (length > 1024 * 1024) throw fail('archiveLimit');
        chunks.push(next.value);
      }
      var bytes = new Uint8Array(length),
        offset = 0;
      chunks.forEach(function (c) {
        bytes.set(c, offset);
        offset += c.length;
      });
      return JSON.parse(new TextDecoder().decode(bytes));
    } finally {
      clearTimeout(timer);
      signal.removeEventListener('abort', stop);
      if (reader) {
        await reader.cancel().catch(function () {});
        reader.releaseLock();
      }
    }
  };
  Manager.prototype.plan = async function (b) {
    var requests = 0,
      deadline = Date.now() + 300000,
      r = b.record,
      signal = b.controller.signal,
      self = this,
      p = new Planner(b.id, this.registry, signal);
    b.state = 'planning';
    this.emit();
    await this.registry.clearBatchItems(b.id);
    if (r.source.kind === 'web') {
      if (!this.manager.session) throw fail('authRequired');
      for (var id of r.source.ids) {
        var file = this.manager.files[id];
        if (!file) throw fail('sourceEnded');
        await p.add(file.fileName, { kind: 'web', fileId: id, name: file.fileName, size: file.size, sha256: file.sha256 || null });
      }
    } else {
      async function walk(path, relative, depth) {
        if (depth > 64) throw fail('archiveLimit');
        var cursor = null,
          stamp = null,
          seen = new Set();
        do {
          alive(signal);
          if (++requests > 10000 || Date.now() > deadline) throw fail('archiveLimit');
          var page = await self.readPage(
            '/api/legnasend/v1/workspaces/' +
              encodeURIComponent(r.source.workspaceId) +
              '/files?generation=' +
              r.source.generation +
              '&path=' +
              encodeURIComponent(path) +
              (cursor ? '&cursor=' + encodeURIComponent(cursor) : ''),
            signal,
          );
          if (
            page.generation !== r.source.generation ||
            page.path !== path ||
            !Array.isArray(page.entries) ||
            page.entries.length > 100 ||
            (stamp && stamp !== page.stamp)
          )
            throw fail('sourceChanged');
          stamp = page.stamp;
          cursor = page.cursor;
          if (cursor && (typeof cursor !== 'string' || cursor.length > 8192 || seen.has(cursor))) throw fail('sourceChanged');
          if (cursor) seen.add(cursor);
          for (var item of page.entries) {
            if (typeof item.name !== 'string' || item.name.includes('/')) throw fail('archiveConflict');
            pathParts(item.name);
            var next = relative ? relative + '/' + item.name : item.name,
              remote = path ? path + '/' + item.name : item.name;
            if (item.directory) {
              await p.add(next, null);
              await walk(remote, next, depth + 1);
            } else
              await p.add(next, {
                kind: 'directory',
                workspaceId: r.source.workspaceId,
                generation: r.source.generation,
                fileId: item.id,
                name: item.name,
                size: item.size,
              });
          }
        } while (cursor);
      }
      await walk(r.source.path, '', 0);
    }
    await p.flush();
    alive(signal);
    r.count = p.count;
    r.files = p.files;
    r.bytes = p.bytes;
    r.planned = true;
    delete r.source.ids;
    await this.save(b);
  };
  Manager.prototype.target = async function (b) {
    var r = b.record;
    if (r.target) return;
    var self = this;
    await this.locks.request('legnasend-batch-destination', {}, async function () {
      var name = r.name.replace(/[\\/:<>"|?*\x00-\x1f\x7f]/g, '_').replace(/[. ]+$/, '') || 'LegnaSend';
      try {
        pathParts(name);
      } catch (_) {
        name = 'LegnaSend';
      }
      for (var i = 0; i < 1000; i++) {
        alive(b.controller.signal);
        var candidate = name + (i ? ' (' + i + ')' : '');
        try {
          await r.directory.getDirectoryHandle(candidate);
          continue;
        } catch (e) {
          if (e.name === 'TypeMismatchError') continue;
          if (e.name !== 'NotFoundError') throw e;
        }
        r.target = await r.directory.getDirectoryHandle(candidate, { create: true });
        r.outputName = candidate;
        await self.save(b);
        return;
      }
      throw fail('storage');
    });
  };
  Manager.prototype.parent = async function (b, path, directory) {
    var parts = pathParts(path),
      handle = b.record.target;
    if (!directory) parts.pop();
    for (var part of parts) {
      alive(b.controller.signal);
      handle = await handle.getDirectoryHandle(part, { create: true });
    }
    return handle;
  };
  Manager.prototype.file = async function (b, entry) {
    var r = b.record,
      self = this;
    if (entry.complete) return;
    var item = await this.registry.batchItem(b.id, entry.index);
    if (!item) throw fail('cacheFormat');
    alive(b.controller.signal);
    var directory = await this.parent(b, item.path, !item.source);
    if (item.source) {
      var task = await this.manager.addBatch(item.source, directory, entry.id, b.id, entry.index);
      function stop() {
        self.manager.pause(task).catch(function () {});
      }
      b.controller.signal.addEventListener('abort', stop, { once: true });
      if (b.controller.signal.aborted) stop();
      try {
        while (task.promise || ['queued', 'ready', 'waiting'].includes(task.state)) {
          b.state = task.state === 'waiting' ? 'waiting' : 'downloading';
          self.emit();
          if (b.controller.signal.aborted) {
            await self.manager.pause(task);
            break;
          }
          if (task.promise) await task.promise;
          else
            await new Promise(function (resolve) {
              setTimeout(resolve, 20);
            });
        }
      } finally {
        b.controller.signal.removeEventListener('abort', stop);
        if (!b.wireRetired.has(task)) {
          b.wireBytes += task.wire || 0;
          b.wireRetired.add(task);
        }
      }
      alive(b.controller.signal);
      if (task.state !== 'complete') throw fail(task.record.sourceInvalidated || task.error || 'network');
    }
    await this.transaction(async function () {
      entry.complete = true;
      if (item.source) {
        r.savedFiles++;
        r.savedBytes += item.source.size;
      }
      await self.save(b);
    });
    this.emit();
  };
  Manager.prototype.run = function (b) {
    if (this.closed || b.promise) return;
    if (this.running) {
      b.state = 'queued';
      b.wantsRun = true;
      this.emit();
      return;
    }
    b.wantsRun = false;
    var self = this;
    this.running = b;
    b.controller = new AbortController();
    b.error = null;
    b.wireBytes = 0;
    b.wireRetired = new WeakSet();
    b.rateSamples = [];
    b.state = 'checking';
    this.emit();
    b.promise = this.locks
      .request('legnasend-batch:' + b.id, { ifAvailable: true }, async function (lock) {
        if (!lock) {
          b.state = 'failed';
          b.error = 'busy';
          return;
        }
        try {
          var latest = await self.registry.batch(b.id);
          if (!latest) throw fail('sourceEnded');
          b.record = latest;
          if (latest.state === 'complete') {
            b.state = 'complete';
            return;
          }
          if (latest.sourceInvalidated) {
            await self.cleanRecords(b.id);
            self.onInvalidated(latest.sourceInvalidated);
            return;
          }
          await self.manager.refreshBatch(b.id);
          if (!latest.planned) await self.plan(b);
          await self.target(b);
          var r = b.record;
          for (var stale of self.manager.tasks.filter(function (t) {
            return t.record.batchId === b.id && t.record.batchIndex < r.cursor;
          }))
            await self.manager.remove(stale);
          while (r.cursor < r.count) {
            alive(b.controller.signal);
            b.state = 'downloading';
            if (!r.active.length) {
              for (var i = r.cursor; i < Math.min(r.cursor + (self.manager.parallelFiles || 2), r.count); i++)
                r.active.push({ index: i, id: root.crypto.randomUUID(), complete: false });
              await self.save(b);
            }
            var problem = null;
            await Promise.all(
              r.active.map(async function (entry) {
                try {
                  await self.file(b, entry);
                } catch (e) {
                  problem = problem || e;
                  b.controller.abort();
                }
              }),
            );
            if (problem) throw problem;
            alive(b.controller.signal);
            // Advance the durable cursor before retiring individual receipts.
            r.cursor += r.active.length;
            r.active = [];
            await self.save(b);
            for (var done of self.manager.tasks.filter(function (t) {
              return t.record.batchId === b.id && t.record.batchIndex < r.cursor;
            }))
              await self.manager.remove(done);
          }
          b.state = 'complete';
          b.error = null;
          await self.save(b);
        } catch (e) {
          b.state = b.stopping === 'pause' ? 'paused' : 'failed';
          b.error = b.state === 'paused' ? null : engine.code(e);
          if (['sourceEnded', 'sourceChanged'].includes(b.error)) {
            b.record.sourceInvalidated = b.error;
            try {
              await self.cleanRecords(b.id);
              self.onInvalidated(b.record.sourceInvalidated);
              return;
            } catch (_) {
              // Retain the journal if a permission/ownership/lock check failed.
              b.error = 'cleanupPending';
            }
          }
          try {
            await self.save(b);
          } catch (_) {
            b.error = 'storage';
          }
        }
      })
      .catch(function (e) {
        b.state = 'failed';
        b.error = engine.code(e);
      })
      .finally(function () {
        b.promise = null;
        b.controller = null;
        b.stopping = null;
        self.running = null;
        self.emit();
        var next = self.batches.find(function (x) {
          return x.wantsRun;
        });
        if (next && !self.closed && !self.holdScheduling) self.run(next);
      });
  };
  Manager.prototype.pause = async function (b) {
    b.wantsRun = false;
    if (!b.promise) {
      if (b.state === 'queued') {
        b.state = 'paused';
        this.emit();
      }
      return;
    }
    b.stopping = 'pause';
    b.controller.abort();
    await Promise.all(
      this.manager.tasks
        .filter(function (t) {
          return t.record.batchId === b.id;
        })
        .map(this.manager.pause.bind(this.manager)),
    );
    await b.promise;
  };
  Manager.prototype.remove = async function (b) {
    await this.pause(b);
    var self = this;
    await this.locks.request('legnasend-batch:' + b.id, { ifAvailable: true }, async function (lock) {
      if (!lock) throw fail('busy');
      await self.manager.refreshBatch(b.id);
      for (var t of self.manager.tasks.filter(function (t) {
        return t.record.batchId === b.id;
      }))
        await self.manager.remove(t);
      await self.registry.removeBatch(b.id);
      self.batches = self.batches.filter(function (x) {
        return x !== b;
      });
      self.emit();
    });
  };
  Manager.prototype.close = function () {
    this.closed = true;
    if (this.manager.batchCleanup === this.cleanupHook) this.manager.batchCleanup = null;
    this.batches.forEach(function (b) {
      if (b.controller) {
        b.stopping = 'pause';
        b.controller.abort();
      }
    });
  };
  var api = { Manager: Manager, Planner: Planner, pathParts: pathParts };
  if (typeof module === 'object') module.exports = api;
  root.LegnaBatchDownloads = api;
})(typeof globalThis === 'object' ? globalThis : this);
