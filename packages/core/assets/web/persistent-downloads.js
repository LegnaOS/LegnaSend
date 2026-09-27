/* Authorized-directory downloads. Persistent .ls checkpoints, bounded ranges,
 * exact source validation and Web Locks; original LocalSend endpoints untouched. */
(function (root) {
  'use strict';
  var ls = root.LegnaLsCache || (typeof require === 'function' ? require('./ls-cache.js') : null);
  if (!ls || (!root.LegnaDownloadRegistry && typeof module !== 'object')) return;
  var fail = ls.fail;
  // The legacy setting is retained: -2 is an explicit one-hour code, 0 is
  // manual retention, and positive values keep their original day semantics.
  function retentionPolicy(value) {
    return value === undefined ? -2 : [-2, 0, 1, 7, 30].includes(value) ? value : 0;
  }
  function retentionMilliseconds(value) {
    return value === -2 ? 3600000 : value * 86400000;
  }
  var CHUNK = 1048576,
    MAX_TASKS = 20;
  function aborted(signal) {
    if (signal.aborted) throw fail('aborted');
  }
  function code(error) {
    if (error.name === 'AbortError') return 'aborted';
    return (
      (typeof error.code === 'string' ? error.code : null) ||
      {
        NotAllowedError: 'permission',
        SecurityError: 'permission',
        QuotaExceededError: 'storage',
        NotReadableError: 'storage',
        InvalidStateError: 'storage',
        UnknownError: 'storage',
        TypeMismatchError: 'storage',
        NoModificationAllowedError: 'busy',
        NotFoundError: 'localChanged',
      }[error.name] ||
      'network'
    );
  }
  function sourceUrl(source, session) {
    return source.kind === 'directory'
      ? '/api/legnasend/v1/workspaces/' +
          encodeURIComponent(source.workspaceId) +
          '/files/' +
          encodeURIComponent(source.fileId) +
          '/content?generation=' +
          source.generation
      : '/api/localsend/v2/download?sessionId=' + encodeURIComponent(session || '') + '&fileId=' + encodeURIComponent(source.fileId);
  }
  function validSource(source) {
    if (
      !source ||
      !['web', 'directory'].includes(source.kind) ||
      typeof source.fileId !== 'string' ||
      !source.fileId ||
      typeof source.name !== 'string' ||
      !Number.isSafeInteger(source.size) ||
      source.size < 0 ||
      source.size > ls.MAX * ls.COUNT ||
      (source.kind === 'directory' &&
        (typeof source.workspaceId !== 'string' ||
          !source.workspaceId ||
          !Number.isSafeInteger(source.generation) ||
          source.generation < 1)) ||
      (source.sha256 != null && (typeof source.sha256 !== 'string' || !/^[\da-f]{64}$/i.test(source.sha256)))
    )
      throw fail('sourceChanged');
    // Copy the allowlisted non-secret descriptor, never a caller's credential fields.
    var safe = { kind: source.kind, fileId: source.fileId, name: source.name, size: source.size, sha256: source.sha256 || null };
    if (source.kind === 'directory') {
      safe.workspaceId = source.workspaceId;
      safe.generation = source.generation;
    }
    return safe;
  }
  function Pool(max) {
    this.max = max;
    this.used = 0;
    this.queue = [];
  }
  Pool.prototype.acquire = function (signal) {
    var self = this;
    return new Promise(function (resolve, reject) {
      var entry = { signal: signal, resolve: resolve, reject: reject };
      entry.abort = function () {
        var n = self.queue.indexOf(entry);
        if (n >= 0) self.queue.splice(n, 1);
        reject(fail('aborted'));
      };
      if (signal.aborted) return entry.abort();
      signal.addEventListener('abort', entry.abort, { once: true });
      self.queue.push(entry);
      self.pump();
    });
  };
  Pool.prototype.pump = function () {
    var self = this;
    while (this.used < this.max && this.queue.length) {
      var entry = this.queue.shift();
      entry.signal.removeEventListener('abort', entry.abort);
      if (entry.signal.aborted) {
        entry.reject(fail('aborted'));
        continue;
      }
      this.used++;
      entry.resolve(
        (function () {
          var done = false;
          return function () {
            if (done) return;
            done = true;
            self.used--;
            self.pump();
          };
        })(),
      );
    }
  };
  function supported() {
    return !!(
      root.isSecureContext &&
      root.showDirectoryPicker &&
      root.indexedDB &&
      root.navigator &&
      root.navigator.locks &&
      root.crypto &&
      root.crypto.randomUUID
    );
  }
  async function networkSlot(locks, signal) {
    while (true) {
      aborted(signal);
      for (var i = 0; i < 8; i++) {
        var release = await new Promise(function (resolve, reject) {
          locks
            .request('legnasend-network:' + i, { ifAvailable: true }, function (lock) {
              if (!lock) {
                resolve(null);
                return;
              }
              return new Promise(function (unlock) {
                resolve(unlock);
              });
            })
            .catch(reject);
        });
        if (release) {
          if (signal.aborted) {
            release();
            throw fail('aborted');
          }
          return release;
        }
      }
      await new Promise(function (resolve) {
        setTimeout(resolve, 30);
      });
    }
  }
  function Manager(options) {
    options = options || {};
    this.fetch = options.fetch || root.fetch.bind(root);
    this.registry = options.registry || new root.LegnaDownloadRegistry();
    this.locks = options.locks || root.navigator.locks;
    this.onChange = options.onChange || function () {};
    this.onAuth = options.onAuth || function () {};
    this.now =
      options.now ||
      function () {
        return root.performance.now();
      };
    this.timeout = options.timeout || 30000;
    this.wallNow = options.wallNow || Date.now;
    this.retentionDays = -2;
    this.retentionTimer = null;
    this.cleanupReport = null;
    this.pool = new Pool(8);
    this.parallelFiles = 2;
    this.parallelRanges = 4;
    this.autoReconnect = false;
    this.retryDelay = options.retryDelay || 1000;
    this.online = options.online || function () { return !root.navigator || root.navigator.onLine !== false; };
    var self = this;
    this.onlineListener = function () {
      self.tasks.filter(function (task) { return task.state === 'waiting'; }).forEach(function (task) { self.scheduleReconnect(task, true); });
    };
    if (root.addEventListener) root.addEventListener('online', this.onlineListener);
    this.tasks = [];
    this.directory = null;
    this.active = 0;
    this.closed = false;
    this.session = null;
    this.files = {};
    this.timer = null;
    this.ready = this.restore();
  }
  Manager.prototype.emit = function () {
    if (!this.closed) this.onChange(this.tasks);
  };
  function restoreTask(record) {
    record.source = validSource(record.source);
    if (!record.directory || typeof record.id !== 'string') throw fail('cacheFormat');
    if (record.identity) {
      ls.validate(record.identity);
      if (
        record.id !== record.identity.taskId ||
        (!record.handle && !['complete', 'cancelled', 'blocked'].includes(record.state)) ||
        typeof record.cacheName !== 'string'
      )
        throw fail('cacheFormat');
    } else if (!record.batchId || record.handle || !['ready', 'paused', 'failed'].includes(record.state)) throw fail('cacheFormat');
    return {
      record: record,
      source: record.source,
      id: record.id,
      name: record.source.name,
      size: record.source.size,
      offset:
        record.state === 'complete'
          ? record.source.size
          : Number.isSafeInteger(record.committedBytes) && record.committedBytes >= 0 && record.committedBytes <= record.source.size
            ? record.committedBytes
            : 0,
      restored: record.state !== 'complete',
      state: ['complete', 'cancelled', 'blocked'].includes(record.state) ? record.state : 'paused',
      error: typeof record.error === 'string' ? record.error : null,
      speed: null,
      promise: null,
      stop: null,
    };
  }
  Manager.prototype.restore = async function () {
    var records = await this.registry.all();
    this.directory = await this.registry.directory();
    var self = this;
    records.slice(0, MAX_TASKS).forEach(function (record) {
      try {
        self.tasks.push(restoreTask(record));
      } catch (_) {}
    });
    var policy = this.registry.retention ? await this.registry.retention() : undefined;
    this.retentionDays = retentionPolicy(policy);
    if (this.registry.transferSettings) {
      var settings = await this.registry.transferSettings();
      if (settings) {
        if ([1, 2, 4].includes(settings.files)) this.parallelFiles = settings.files;
        if ([1, 2, 4].includes(settings.ranges)) this.parallelRanges = settings.ranges;
        this.autoReconnect = settings.autoReconnect === true;
      }
    }
    await this.cleanupExpired();
    this.scheduleRetention();
    this.emit();
    return this;
  };
  Manager.prototype.configureTransfers = async function (settings) {
    if (!settings || ![1, 2, 4].includes(settings.files) || ![1, 2, 4].includes(settings.ranges) || typeof settings.autoReconnect !== 'boolean') throw fail('storage');
    if (this.registry.transferSettings) await this.registry.transferSettings(settings);
    this.parallelFiles = settings.files;
    this.parallelRanges = settings.ranges;
    this.autoReconnect = settings.autoReconnect;
    if (!this.autoReconnect) this.tasks.forEach(function (task) {
      clearTimeout(task.retryTimer); task.retryTimer = null;
      if (task.state === 'waiting') { task.stop = 'pause'; task.state = 'paused'; }
    });
    this.emit(); this.pump();
  };
  Manager.prototype.clearReconnect = function (task) {
    clearTimeout(task.retryTimer); task.retryTimer = null; task.retryGeneration = (task.retryGeneration || 0) + 1;
  };
  Manager.prototype.scheduleReconnect = function (task, now) {
    if (this.closed || !this.autoReconnect || task.state !== 'waiting' || task.stop || task.retryTimer) return;
    var self = this, generation = task.retryGeneration || 0;
    if (!this.online()) return; // Explicit online event wakes it; no offline polling.
    // Five automatic attempts per user request. A further manual retry resets it.
    if ((task.reconnectAttempts || 0) >= 5) { task.state = 'failed'; this.emit(); return; }
    task.retryTimer = setTimeout(async function () {
      task.retryTimer = null;
      if (self.closed || generation !== (task.retryGeneration || 0) || task.state !== 'waiting' || task.stop) return;
      if (!self.online()) return;
      try {
        var granted = task.record.directory.queryPermission && await task.record.directory.queryPermission({mode: 'readwrite'});
        if (self.closed || generation !== (task.retryGeneration || 0) || task.state !== 'waiting' || task.stop) return;
        if (granted !== 'granted') { task.state = 'failed'; task.error = 'permission'; self.emit(); return; }
        task.reconnectAttempts = (task.reconnectAttempts || 0) + 1;
        task.state = 'paused'; self.startAuthorized(task, true);
      } catch (error) { if (generation === (task.retryGeneration || 0) && task.state === 'waiting') { task.state = 'failed'; task.error = code(error); self.emit(); } }
    }, Math.max(task.retryAfterMs || 0, now ? 0 : this.retryDelay * Math.pow(2, task.reconnectAttempts || 0)));
    if (task.retryTimer.unref) task.retryTimer.unref();
  };
  Manager.prototype.scheduleRetention = function () {
    if (this.retentionTimer) clearInterval(this.retentionTimer);
    this.retentionTimer = null;
    if (!this.retentionDays || this.closed) return;
    var self = this;
    this.retentionTimer = setInterval(function () { self.cleanupExpired().catch(function () {}); }, 300000);
    if (this.retentionTimer.unref) this.retentionTimer.unref();
  };
  Manager.prototype.setRetention = async function (days) {
    if (![-2, 0, 1, 7, 30].includes(days) || !this.registry.retention) throw fail('storage');
    await this.registry.retention(days);
    this.retentionDays = days;
    this.scheduleRetention();
    await this.cleanupExpired();
    this.emit();
  };
  Manager.prototype.cleanupExpired = function () {
    if (this.cleanupWork) return this.cleanupWork;
    var self = this;
    var operation = Promise.resolve().then(async function () {
      var report = {removed: 0, retained: 0, failed: 0, skipped: 0};
      if (self.registry.retention) {
        try { var latestPolicy=await self.registry.retention(); self.retentionDays=retentionPolicy(latestPolicy); }
        catch (_) { report.failed++; self.cleanupReport=report; self.emit(); return report; }
      }
      if (!self.retentionDays || self.closed) {
        if(!self.closed){self.cleanupReport=null;self.scheduleRetention();self.emit();}
        return report;
      }
      var before = self.wallNow() - retentionMilliseconds(self.retentionDays);
      function eligible(record) {
        var age = record.updatedUnixMs || record.identity && record.identity.createdUnixMs;
        return !record.batchId && !['complete','cancelled','blocked'].includes(record.state) && Number.isSafeInteger(age) && age > 0 && age <= before;
      }
      try {
        var records = await self.registry.all();
        for (var original of records.slice(0, MAX_TASKS)) {
          if (self.closed || !self.retentionDays) break;
          if (!eligible(original)) { report.skipped++; continue; }
          var active = self.tasks.find(function (task) { return task.id === original.id; });
          if (active && active.promise) { report.retained++; continue; }
          try {
            await self.locks.request('legnasend-download:' + original.id, {ifAvailable: true}, async function (lock) {
              if (!lock) { report.retained++; return; }
              // Another tab may have resumed or completed this task since restoration.
              var current = (await self.registry.all()).find(function (record) { return record.id === original.id; });
              if (!current || !eligible(current)) { report.skipped++; return; }
              var latestPolicy=self.registry.retention?await self.registry.retention():self.retentionDays;
              if(retentionPolicy(latestPolicy)!==self.retentionDays){report.retained++;return;}
              var task = restoreTask(current);
              if (!current.directory.queryPermission || await current.directory.queryPermission({mode:'readwrite'}) !== 'granted') {
                report.retained++; return; // Never prompt for authorization during automatic cleanup.
              }
              await self.cleanPlaceholder(task);
              await self.clean(task);
              await self.registry.remove(task.id);
              self.tasks = self.tasks.filter(function (item) { return item.id !== task.id; });
              report.removed++;
            });
          } catch (_) { report.failed++; }
        }
      } catch (_) { report.failed++; }
      if (self.batchCleanup && !self.closed) {
        try { await self.batchCleanup(self.retentionDays, report); }
        catch (_) { report.failed++; }
      }
      self.cleanupReport = report;
      self.emit();
      return report;
    });
    this.cleanupWork = operation.finally(function () { self.cleanupWork = null; });
    return this.cleanupWork;
  };
  // The batch lock is held here. Other tabs may have advanced the journal.
  Manager.prototype.refreshBatch = async function (id) {
    var records = await this.registry.all(),
      self = this;
    if (
      this.tasks.some(function (t) {
        return t.record.batchId === id && t.promise;
      })
    )
      throw fail('busy');
    this.tasks = this.tasks.filter(function (t) {
      return t.record.batchId !== id;
    });
    records
      .filter(function (r) {
        return r.batchId === id;
      })
      .forEach(function (record) {
        self.tasks.push(restoreTask(record));
      });
    this.emit();
  };
  // Bounded recent receipts must not prevent the next normal download. Only
  // retire confirmed, cache-free records; never delete a destination file.
  Manager.prototype.makeRoom = async function () {
    if (this.tasks.length < MAX_TASKS) return;
    var self=this;
    for (var task of this.tasks.slice()) {
      if (this.tasks.length < MAX_TASKS) break;
      if (task.promise || task.record.batchId || task.state !== 'complete' || task.record.handle) continue;
      await this.locks.request('legnasend-download:' + task.id, {ifAvailable:true}, async function(lock) {
        if(!lock || task.promise || task.state!=='complete')return;
        var current=(await self.registry.all()).find(function(record){return record.id===task.id;});
        if(current && (current.state!=='complete'||current.handle||current.batchId))return;
        await self.registry.remove(task.id);
        self.tasks=self.tasks.filter(function(item){return item!==task;});
      });
    }
  };
  Manager.prototype.addBatch = async function (source, directory, id, batchId, index) {
    source = validSource(source);
    var task = this.tasks.find(function (t) {
      return t.id === id;
    });
    if (!task) {
      await this.makeRoom();
      if (this.tasks.length >= MAX_TASKS) throw fail('taskLimit');
      var record = { id: id, source: source, directory: directory, batchId: batchId, batchIndex: index, state: 'ready' };
      task = {
        id: id,
        source: source,
        name: source.name,
        size: source.size,
        offset: 0,
        state: 'ready',
        error: null,
        speed: null,
        promise: null,
        stop: null,
        record: record,
      };
      this.tasks.push(task);
      try {
        await this.registry.put(record);
      } catch (e) {
        this.tasks = this.tasks.filter(function (t) {
          return t !== task;
        });
        throw e;
      }
    }
    if (task.record.batchId !== batchId || task.record.batchIndex !== index) throw fail('cacheFormat');
    this.startAuthorized(task);
    return task;
  };
  Manager.prototype.attachSession = function (session, files) {
    this.session = session;
    this.files = files || {};
  };
  Manager.prototype.save = function (task) {
    task.record.state = task.state;
    task.record.error = task.error;
    task.record.committedBytes = task.offset;
    task.record.updatedUnixMs = this.wallNow();
    return task.record.identity || task.record.batchId ? this.registry.put(task.record) : Promise.resolve();
  };
  Manager.prototype.permission = function (directory) {
    return directory.requestPermission({ mode: 'readwrite' }).then(function (result) {
      if (result !== 'granted') throw fail('permission');
      return directory;
    });
  };
  Manager.prototype.choose = function () {
    var self = this;
    var chosen = this.directory
      ? this.permission(this.directory)
      : root.showDirectoryPicker({ id: 'legnasend-downloads', startIn: 'downloads', mode: 'readwrite' });
    return chosen.then(async function (directory) {
      self.directory = directory;
      await self.registry.directory(directory);
      return directory;
    });
  };
  Manager.prototype.add = async function (source) {
    source = validSource(source);
    var choosing = this.choose();
    var prepared = await Promise.all([this.ready, choosing]);
    var directory = prepared[1];
    if (this.closed) throw fail('aborted');
    var old = this.tasks.find(function (t) {
      return (
        t.source.kind === source.kind &&
        t.source.fileId === source.fileId &&
        t.source.workspaceId === source.workspaceId &&
        t.source.generation === source.generation &&
        !['complete', 'cancelled', 'blocked'].includes(t.state)
      );
    });
    if (old) {
      await this.permission(old.record.directory);
      this.startAuthorized(old);
      return old;
    }
    await this.makeRoom();
    if (this.tasks.length >= MAX_TASKS) throw fail('taskLimit');
    var id = root.crypto.randomUUID(),
      task = {
        id: id,
        source: source,
        name: source.name,
        size: source.size,
        offset: 0,
        state: 'ready',
        error: null,
        speed: null,
        promise: null,
        stop: null,
        record: { id: id, source: source, directory: directory },
      };
    this.tasks.push(task);
    this.emit();
    this.startAuthorized(task);
    return task;
  };
  Manager.prototype.start = async function (task) {
    if (task.promise || !['ready', 'paused', 'failed'].includes(task.state)) return;
    try {
      await this.permission(task.record.directory);
      this.startAuthorized(task);
    } catch (e) {
      task.error = code(e);
      task.state = 'failed';
      this.emit();
    }
  };
  Manager.prototype.startAuthorized = function (task, reconnect) {
    if (this.closed || task.promise || !this.tasks.includes(task) || !['ready', 'paused', 'failed'].includes(task.state)) return;
    this.clearReconnect(task);
    if (!reconnect) task.reconnectAttempts = 0;
    task.stop = null;
    task.error = null;
    task.state = 'queued';
    this.emit();
    this.pump();
  };
  Manager.prototype.pump = function () {
    var self = this;
    if (this.closed || this.holdScheduling) return;
    while (this.active < this.parallelFiles) {
      var task = this.tasks.find(function (t) {
        return t.state === 'queued' && !t.promise;
      });
      if (!task) break;
      this.active++;
      task.controller = new AbortController();
      task.wire = 0;
      task.samples = [{ time: this.now(), bytes: 0 }];
      task.speed = null;
      (function (task) {
        task.promise = self.locks
          .request('legnasend-download:' + task.id, { ifAvailable: true }, async function (lock) {
            if (!lock) throw fail('busy');
            await self.run(task);
          })
          .catch(function (e) {
            task.error = code(e);
            task.state = 'failed';
          })
          .finally(function () {
            task.promise = null;
            task.controller = null;
            task.speed = null;
            self.active--;
            if (task.state === 'waiting') self.scheduleReconnect(task);
            self.emit();
            self.pump();
          });
      })(task);
    }
    if (this.active && !this.timer)
      this.timer = setInterval(function () {
        var now = self.now();
        self.tasks.forEach(function (t) {
          if (!t.promise) return;
          t.samples.push({ time: now, bytes: t.wire });
          while (t.samples.length > 2 && t.samples[1].time <= now - 3000) t.samples.shift();
          var elapsed = now - t.samples[0].time;
          t.speed = t.state === 'downloading' && elapsed >= 250 ? ((t.wire - t.samples[0].bytes) * 1000) / elapsed : null;
        });
        self.emit();
      }, 500);
    if (!this.active && this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  };
  Manager.prototype.request = async function (task, init, consume, signal) {
    signal = signal || task.controller.signal;
    aborted(signal);
    var release = await networkSlot(this.locks, signal),
      controller = new AbortController(),
      expired = false,
      response;
    function abort() {
      controller.abort();
    }
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    var timer = setTimeout(function () {
      expired = true;
      controller.abort();
    }, this.timeout);
    try {
      if (task.source.kind === 'web' && !this.session) throw fail('authRequired');
      response = await this.fetch(
        sourceUrl(task.source, this.session),
        Object.assign({ credentials: 'same-origin', cache: 'no-store', redirect: 'error' }, init, { signal: controller.signal }),
      );
      aborted(signal);
      if ([401, 403].includes(response.status)) throw fail('authRequired');
      if ([404, 410].includes(response.status)) throw fail('sourceEnded');
      if ([409, 412].includes(response.status)) throw fail('sourceChanged');
      if (response.status === 429) throw fail('busy');
      if (!response.ok) {
        var delay = response.headers.get('Retry-After');
        var waitMs = delay ? (/^\d+$/.test(delay) ? Number(delay) * 1000 : Date.parse(delay) - this.wallNow()) : 0;
        if(Number.isFinite(waitMs) && waitMs>300000) throw fail('busy');
        task.retryAfterMs = Number.isFinite(waitMs) ? Math.max(0, waitMs) : 0;
        throw fail('network');
      }
      task.retryAfterMs = 0;
      return await consume(response, controller.signal);
    } catch (e) {
      if (expired && !signal.aborted) throw fail('timeout');
      throw e;
    } finally {
      clearTimeout(timer);
      signal.removeEventListener('abort', abort);
      if (response && response.body && !response.body.locked)
        try {
          await response.body.cancel();
        } catch (_) {}
      release();
    }
  };
  Manager.prototype.inspect = async function (task) {
    var identity = task.record.identity;
    if (task.source.kind === 'web') {
      if (!this.session) throw fail('authRequired');
      var current = this.files[task.source.fileId];
      if (!current) throw fail('sourceEnded');
      if (current.size !== task.size || current.fileName !== task.name) throw fail('sourceChanged');
    }
    return this.request(task, { method: 'HEAD', headers: identity ? { 'If-Match': identity.version } : {} }, async function (response) {
      var tag = response.headers.get('ETag');
      if (response.status !== 200 || response.headers.get('Content-Length') !== String(task.size)) throw fail('sourceChanged');
      if (response.headers.get('Accept-Ranges') !== 'bytes' || !tag || !/^"[^"\r\n]+"$/.test(tag)) throw fail('rangeUnsupported');
      if (identity && tag !== identity.version) throw fail('sourceChanged');
      return tag;
    });
  };
  Manager.prototype.range = async function (task, index, signal) {
    var id = task.record.identity,
      start = index * id.chunkSize,
      end = Math.min(task.size, start + id.chunkSize) - 1;
    return this.request(
      task,
      { headers: { Range: 'bytes=' + start + '-' + end, 'If-Match': id.version } },
      async function (response, requestSignal) {
        var count = end - start + 1;
        if (
          response.status !== 206 ||
          response.headers.get('Content-Length') !== String(count) ||
          response.headers.get('Content-Range') !== 'bytes ' + start + '-' + end + '/' + task.size ||
          response.headers.get('ETag') !== id.version
        )
          throw fail('invalidRange');
        var reader = response.body.getReader(),
          data = new Uint8Array(count),
          offset = 0;
        try {
          while (true) {
            aborted(requestSignal);
            var next = await reader.read();
            aborted(requestSignal);
            if (next.done) break;
            if (offset + next.value.length > count) throw fail('invalidRange');
            data.set(next.value, offset);
            offset += next.value.length;
            task.wire += next.value.length;
          }
          if (offset !== count) throw fail('shortResponse');
          return { index: index, bytes: data };
        } finally {
          try {
            await reader.cancel();
          } catch (_) {}
          reader.releaseLock();
        }
      },
      signal,
    );
  };
  Manager.prototype.wave = async function (task, indices) {
    var self = this,
      controller = new AbortController(),
      signal = task.controller.signal,
      parts = [],
      releases = [],
      problem;
    function abort() {
      controller.abort();
    }
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    try {
      await Promise.all(
        indices.map(async function (index) {
          try {
            var release = await self.pool.acquire(controller.signal);
            releases.push(release);
            parts.push(await self.range(task, index, controller.signal));
          } catch (e) {
            if (!problem || code(problem) === 'aborted' || problem.name === 'AbortError') problem = e;
            controller.abort();
          }
        }),
      );
      if (parts.length) {
        await task.cache.stage(parts);
        task.pendingBytes = task.cache.stagedBytes;
        this.emit();
      }
      if (task.cache.stagedBytes >= 16 * CHUNK || this.now() - task.checkpointTime >= 5000 || problem || signal.aborted) {
        if (task.stop === 'cancel' || (problem && ['sourceChanged', 'sourceEnded'].includes(code(problem)))) await task.cache.abortStaged();
        else await this.checkpoint(task);
      }
      if (problem) throw problem;
      aborted(signal);
    } finally {
      releases.forEach(function (release) {
        release();
      });
      signal.removeEventListener('abort', abort);
    }
  };
  Manager.prototype.checkpoint = async function (task) {
    if (!task.cache.stagedBytes) return;
    task.state = 'checkpointing';
    this.emit();
    task.offset = await task.cache.checkpoint();
    task.record.cacheMark = task.cache.stamp;
    task.pendingBytes = 0;
    task.checkpointTime = this.now();
    task.state = task.stop === 'pause' ? 'pausing' : task.stop === 'cancel' ? 'cancelling' : 'downloading';
    await this.save(task);
    this.emit();
  };
  Manager.prototype.clean = async function (task) {
    var r = task.record;
    if (!r.handle || !r.identity) return;
    var file;
    try {
      file = await r.handle.getFile();
    } catch (e) {
      if (e.name !== 'NotFoundError') throw e;
      r.handle = null;
      task.cache = null;
      return;
    }
    if (r.initialized === false && file.size === 0 && file.lastModified === r.cacheStamp) {
      // A failed initial registry/header write may leave our own empty file.
    } else {
      if (!r.cacheMark || file.size !== r.cacheMark.size || file.lastModified !== r.cacheMark.modified) throw fail('localChanged');
      var meta = await ls.header(file);
      if (!ls.same(meta.id, r.identity)) throw fail('localChanged');
    }
    var current = await r.directory.getFileHandle(r.cacheName);
    if (!(await current.isSameEntry(r.handle))) throw fail('localChanged');
    var latest = await current.getFile();
    if (latest.size !== file.size || latest.lastModified !== file.lastModified) throw fail('localChanged');
    await r.directory.removeEntry(r.cacheName);
    r.handle = null;
    task.cache = null;
    if (task.state !== 'complete') task.offset = 0;
  };
  Manager.prototype.cleanPlaceholder = async function (task) {
    var r = task.record;
    if (!r.output || task.state === 'complete') return;
    var file = await r.output.getFile();
    // Never remove published bytes or a replacement entry, even during cancel.
    if (file.size || file.lastModified !== r.outputStamp) return;
    var current = await r.directory.getFileHandle(r.outputName);
    if (!(await current.isSameEntry(r.output))) throw fail('localChanged');
    await r.directory.removeEntry(r.outputName);
    r.output = null;
    r.receipt = null;
  };
  Manager.prototype.finish = async function (task) {
    task.offset = task.size;
    task.restored = false;
    task.state = 'complete';
    await this.save(task);
    try {
      await this.clean(task);
      await this.save(task);
    } catch (_) {
      task.error = 'cleanupPending';
      try {
        await this.save(task);
      } catch (_) {}
    }
    this.emit();
  };
  Manager.prototype.output = async function (task) {
    var r = task.record;
    if (r.output) {
      if (r.receipt && (await ls.matchesOutput(r.output, r.receipt, task.controller.signal))) return true;
      var file = await r.output.getFile();
      if (file.size !== 0 || file.lastModified !== r.outputStamp) throw fail('localChanged');
      return false;
    }
    var name = r.batchId ? task.name.split('/').pop() : ls.safeName(task.name),
      dot = name.lastIndexOf('.'),
      base = dot > 0 ? name.slice(0, dot) : name,
      extension = dot > 0 ? name.slice(dot) : '';
    for (var index = 0; index < 1000; index++) {
      var candidate = base + (index ? ' (' + index + ')' : '') + extension;
      try {
        r.output = await ls.fresh(r.directory, candidate);
        r.outputName = candidate;
        r.outputStamp = (await r.output.getFile()).lastModified;
        await this.save(task);
        return false;
      } catch (e) {
        if (e.code !== 'localChanged') throw e;
      }
    }
    throw fail('storage');
  };
  Manager.prototype.run = async function (task) {
    var self = this,
      r = task.record;
    try {
      task.state = 'checking';
      this.emit();
      // The output receipt is persisted before close. Recover a published file
      // even if the source stopped or saving the final registry state failed.
      if (r.output && r.receipt && (await ls.matchesOutput(r.output, r.receipt, task.controller.signal))) {
        await this.finish(task);
        return;
      }
      var tag = await this.inspect(task);
      aborted(task.controller.signal);
      if (!r.identity) {
        r.identity = {
          taskId: task.id,
          sourceId: root.location.origin + '/' + task.source.kind + '/' + (task.source.workspaceId || 'temporary'),
          resourceId: task.source.fileId,
          version: tag,
          fileName: task.name,
          size: task.size,
          chunkSize: Math.max(CHUNK, Math.ceil(task.size / ls.COUNT)),
          createdUnixMs: Date.now(),
          sha256: task.source.sha256 || null,
        };
        r.cacheName = r.batchId ? '.legnasend-' + task.id + '.ls' : ls.safeName(task.name) + '.' + task.id + '.ls';
        r.handle = await ls.fresh(r.directory, r.cacheName);
        r.state = 'creating';
        r.initialized = false;
        r.cacheStamp = (await r.handle.getFile()).lastModified;
        try {
          await this.registry.put(r);
        } catch (_) {
          try {
            await this.clean(task);
            r.identity = null;
          } catch (_) {}
          throw fail('storage');
        }
      }
      task.cache = new ls.Cache(r.handle, r.identity);
      if (!r.initialized && (await r.handle.getFile()).size === 0) await task.cache.initialize();
      else
        await task.cache.recover(task.controller.signal, function (bytes) {
          task.offset = bytes;
          self.emit();
        });
      r.initialized = true;
      r.cacheMark = task.cache.stamp;
      task.restored = false;
      task.offset = task.cache.bytes;
      aborted(task.controller.signal);
      task.state = 'downloading';
      task.checkpointTime = this.now();
      await this.save(task);
      this.emit();
      var missing = task.cache.missing(),
        lanes = task.size < 4 * CHUNK ? 1 : this.parallelRanges;
      for (var offset = 0; offset < missing.length; offset += lanes) await this.wave(task, missing.slice(offset, offset + lanes));
      await this.checkpoint(task);
      await this.inspect(task);
      aborted(task.controller.signal);
      task.state = 'saving';
      this.emit();
      await this.save(task);
      if (!(await this.output(task))) {
        r.receipt = await task.cache.export(r.output, {
          signal: task.controller.signal,
          onProgress: function (bytes) {
            task.savingBytes = bytes;
            self.emit();
          },
          beforePublish: async function (receipt) {
            r.receipt = receipt;
            await self.save(task);
          },
        });
      }
      await this.finish(task);
    } catch (e) {
      // Release the browser swap writer before deleting the named cache.
      if (task.cache && task.cache.writer) await task.cache.abortStaged();
      var issue = code(e);
      if (task.stop === 'cancel') {
        task.state = 'cancelled';
        try {
          await this.cleanPlaceholder(task);
          await this.clean(task);
        } catch (_) {
          issue = 'cleanupPending';
        }
      } else if (['sourceEnded', 'sourceChanged', 'rangeUnsupported'].includes(issue)) {
        if (r.batchId && ['sourceEnded', 'sourceChanged'].includes(issue)) r.sourceInvalidated = issue;
        task.state = 'blocked';
        try {
          await this.cleanPlaceholder(task);
          await this.clean(task);
        } catch (_) {
          issue = 'cleanupPending';
        }
      } else task.state = task.stop === 'pause' && ['aborted', 'network'].includes(issue) ? 'paused' : 'failed';
      task.error = task.state === 'paused' ? null : issue;
      if (task.state === 'failed' && !task.stop && this.autoReconnect && ['network', 'timeout'].includes(issue)) task.state = 'waiting';
      if (issue === 'authRequired') this.onAuth(task);
      try {
        if (r.identity) await this.save(task);
      } catch (_) {
        task.error = 'storage';
      }
      this.emit();
    } finally {
      if (task.cache && task.cache.writer) await task.cache.abortStaged();
      task.pendingBytes = 0;
    }
  };
  Manager.prototype.pause = async function (task) {
    this.clearReconnect(task);
    if (!task.promise && ['ready', 'queued', 'waiting'].includes(task.state)) {
      task.state = 'paused';
      this.emit();
      return;
    }
    if (!task.promise) return;
    task.stop = 'pause';
    task.state = 'pausing';
    task.controller.abort();
    this.emit();
    await task.promise;
  };
  Manager.prototype.cancel = async function (task) {
    this.clearReconnect(task);
    if (task.state === 'complete') return;
    task.stop = 'cancel';
    if (task.promise) {
      task.state = 'cancelling';
      task.controller.abort();
      this.emit();
      await task.promise;
    } else {
      await this.locks.request(
        'legnasend-download:' + task.id,
        { ifAvailable: true },
        async function (lock) {
          if (!lock) throw fail('busy');
          await this.cleanPlaceholder(task);
          await this.clean(task);
        }.bind(this),
      );
      task.state = 'cancelled';
      await this.save(task);
      this.emit();
    }
  };
  Manager.prototype.remove = async function (task) {
    if (task.state !== 'complete') await this.cancel(task);
    if (task.record.handle)
      await this.locks.request(
        'legnasend-download:' + task.id,
        { ifAvailable: true },
        async function (lock) {
          if (!lock) throw fail('busy');
          await this.cleanPlaceholder(task);
          await this.clean(task);
        }.bind(this),
      );
    await this.registry.remove(task.id);
    this.tasks = this.tasks.filter(function (t) {
      return t !== task;
    });
    this.emit();
  };
  Manager.prototype.close = function () {
    this.closed = true;
    if (root.removeEventListener) root.removeEventListener('online', this.onlineListener);
    this.tasks.forEach(this.clearReconnect.bind(this));
    if (this.retentionTimer) clearInterval(this.retentionTimer);
    this.retentionTimer = null;
    this.tasks.forEach(function (t) {
      if (t.controller) {
        t.stop = 'pause';
        t.controller.abort();
      }
    });
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  };
  var api = {
    Manager: Manager,
    retentionPolicy: retentionPolicy,
    retentionMilliseconds: retentionMilliseconds,
    Pool: Pool,
    supported: supported,
    sourceUrl: sourceUrl,
    code: code,
    validSource: validSource,
    CHUNK: CHUNK,
  };
  if (typeof module === 'object') module.exports = api;
  root.LegnaPersistentDownloads = api;
})(typeof globalThis === 'object' ? globalThis : this);
