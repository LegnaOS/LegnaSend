/* Persist handles and non-secret task metadata. Session approvals stay in memory /
 * sessionStorage and are rebound only from the current approved file listing. */
(function (root) {
  'use strict';
  function Registry() {
    this.database = null;
  }
  Registry.prototype.open = function () {
    if (this.database) return this.database;
    var self = this;
    this.database = new Promise(function (resolve, reject) {
      var failed = false;
      function error() {
        failed = true;
        reject(Object.assign(new Error('registry storage failed'), { code: 'storage' }));
      }
      var request = root.indexedDB.open('legnasend-downloads-v1', 2);
      request.onupgradeneeded = function () {
        var db = request.result;
        if (!db.objectStoreNames.contains('tasks')) db.createObjectStore('tasks', { keyPath: 'id' });
        if (!db.objectStoreNames.contains('settings')) db.createObjectStore('settings');
        if (!db.objectStoreNames.contains('batches')) db.createObjectStore('batches', { keyPath: 'id' });
        if (!db.objectStoreNames.contains('batchItems')) db.createObjectStore('batchItems', { keyPath: ['batchId', 'index'] });
      };
      request.onerror = request.onblocked = error;
      request.onsuccess = function () {
        var db = request.result;
        if (failed) {
          db.close();
          return;
        }
        db.onversionchange = function () {
          db.close();
          self.database = null;
        };
        resolve(db);
      };
    }).catch(function (error) {
      self.database = null;
      throw error;
    });
    return this.database;
  };
  Registry.prototype.run = async function (store, mode, operation) {
    var db = await this.open();
    return new Promise(function (resolve, reject) {
      var transaction = db.transaction(store, mode),
        result;
      transaction.oncomplete = function () {
        resolve(result);
      };
      transaction.onerror = transaction.onabort = function () {
        reject(Object.assign(new Error('registry storage failed'), { code: 'storage' }));
      };
      var request = operation(transaction.objectStore(store));
      request.onsuccess = function () {
        result = request.result;
      };
    }).catch(function () {
      throw Object.assign(new Error('registry storage failed'), { code: 'storage' });
    });
  };
  Registry.prototype.all = function () {
    return this.run('tasks', 'readonly', function (s) {
      return s.getAll();
    });
  };
  Registry.prototype.put = function (record) {
    return this.run('tasks', 'readwrite', function (s) {
      return s.put(record);
    });
  };
  Registry.prototype.remove = function (id) {
    return this.run('tasks', 'readwrite', function (s) {
      return s.delete(id);
    });
  };
  Registry.prototype.directory = function (value) {
    return arguments.length
      ? this.run('settings', 'readwrite', function (s) {
          return s.put(value, 'directory');
        })
      : this.run('settings', 'readonly', function (s) {
          return s.get('directory');
        });
  };
  Registry.prototype.retention = function (value) {
    return arguments.length
      ? this.run('settings', 'readwrite', function (store) { return store.put(value, 'partialRetentionDays'); })
      : this.run('settings', 'readonly', function (store) { return store.get('partialRetentionDays'); });
  };
  Registry.prototype.transferSettings = function (value) {
    return arguments.length
      ? this.run('settings', 'readwrite', function (s) { return s.put(value, 'transferSettings'); })
      : this.run('settings', 'readonly', function (s) { return s.get('transferSettings'); });
  };
  Registry.prototype.batches = function () {
    return this.run('batches', 'readonly', function (s) {
      return s.getAll();
    });
  };
  Registry.prototype.batch = function (id) {
    return this.run('batches', 'readonly', function (s) {
      return s.get(id);
    });
  };
  Registry.prototype.putBatch = function (record) {
    return this.run('batches', 'readwrite', function (s) {
      return s.put(record);
    });
  };
  Registry.prototype.batchItem = function (id, index) {
    return this.run('batchItems', 'readonly', function (s) {
      return s.get([id, index]);
    });
  };
  Registry.prototype.putBatchItems = async function (items) {
    var db = await this.open();
    return new Promise(function (resolve, reject) {
      var tx = db.transaction('batchItems', 'readwrite');
      tx.oncomplete = resolve;
      tx.onerror = tx.onabort = function () {
        reject(Object.assign(new Error('registry storage failed'), { code: 'storage' }));
      };
      var store = tx.objectStore('batchItems');
      items.forEach(function (item) {
        store.put(item);
      });
    });
  };
  Registry.prototype.clearBatchItems = function (id) {
    return this.run('batchItems', 'readwrite', function (s) {
      return s.delete(root.IDBKeyRange.bound([id, 0], [id, Number.MAX_SAFE_INTEGER]));
    });
  };
  Registry.prototype.removeBatch = async function (id) {
    var db = await this.open();
    return new Promise(function (resolve, reject) {
      var tx = db.transaction(['batches', 'batchItems'], 'readwrite');
      tx.oncomplete = resolve;
      tx.onerror = tx.onabort = function () {
        reject(Object.assign(new Error('registry storage failed'), { code: 'storage' }));
      };
      tx.objectStore('batchItems').delete(root.IDBKeyRange.bound([id, 0], [id, Number.MAX_SAFE_INTEGER]));
      tx.objectStore('batches').delete(id);
    });
  };
  if (typeof module === 'object') module.exports = Registry;
  root.LegnaDownloadRegistry = Registry;
})(typeof globalThis === 'object' ? globalThis : this);
