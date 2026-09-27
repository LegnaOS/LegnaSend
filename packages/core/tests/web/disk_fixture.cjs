// Copy-on-write file handles for storage contracts; browser/disk QA is separate.
const { File } = require('node:buffer');
function diskFixture() {
  const entries = new Map();
  let tick = 1000;
  function handle(name) {
    const h = {
      name,
      bytes: Buffer.alloc(0),
      stamp: ++tick,
      writing: false,
      permission: 'granted',
      failClose: false,
      writes: 0,
      async getFile() {
        if (!entries.has(name)) throw Object.assign(new Error(), { name: 'NotFoundError' });
        return new File([h.bytes], name, { lastModified: h.stamp });
      },
      async isSameEntry(other) {
        return h === other;
      },
      async createWritable(options = {}) {
        if (h.writing) throw Object.assign(new Error(), { name: 'NoModificationAllowedError' });
        h.writing = true;
        let data = options.keepExistingData ? Buffer.from(h.bytes) : Buffer.alloc(0),
          position = 0,
          done = false;
        const w = {
          async seek(n) {
            position = n;
          },
          async truncate(n) {
            const next = Buffer.alloc(n);
            data.copy(next);
            data = next;
          },
          async write(input) {
            if (done) throw new Error('closed');
            let bytes = input;
            if (input.type === 'write') {
              position = input.position;
              bytes = input.data;
            }
            bytes = Buffer.from(bytes);
            if (position + bytes.length > data.length) {
              const next = Buffer.alloc(position + bytes.length);
              data.copy(next);
              data = next;
            }
            bytes.copy(data, position);
            position += bytes.length;
          },
          async close() {
            if (h.failClose) {
              h.failClose = false;
              throw Object.assign(new Error(), { name: 'QuotaExceededError' });
            }
            h.bytes = data;
            h.stamp = ++tick;
            h.writing = false;
            h.writes++;
            done = true;
          },
          async abort() {
            h.writing = false;
            done = true;
          }
        };
        return w;
      }
    };
    entries.set(name, h);
    return h;
  }
  const directory = {
    name: 'Downloads', entries, subdirs: new Map(),
    async getDirectoryHandle(name,options={}) {
      if(entries.has(name))throw Object.assign(new Error(),{name:'TypeMismatchError'});
      if(this.subdirs.has(name))return this.subdirs.get(name);
      if(!options.create)throw Object.assign(new Error(),{name:'NotFoundError'});
      const child=diskFixture().directory;child.name=name;this.subdirs.set(name,child);return child;
    },
    permission: 'granted',
    async requestPermission() {
      return this.permission;
    },
    async queryPermission() {
      return this.permission;
    },
    async getFileHandle(name, options = {}) {
      if (entries.has(name)) return entries.get(name);
      if (options.create) return handle(name);
      throw Object.assign(new Error(), { name: 'NotFoundError' });
    },
    async removeEntry(name) {
      if (!entries.delete(name)) throw Object.assign(new Error(), { name: 'NotFoundError' });
    }
  };
  const records = new Map(), batchRecords=new Map(), batchItems=new Map();
  const copyBatch=r=>({...r,source:structuredClone(r.source),active:r.active.map(x=>({...x}))});
  let selected = directory;
  const registry = {
    async batches(){return [...batchRecords.values()].map(copyBatch);},
    async batch(id){const r=batchRecords.get(id);return r&&copyBatch(r);},
    async putBatch(r){batchRecords.set(r.id,copyBatch(r));},
    async batchItem(id,index){return batchItems.get(id+":"+index);},
    async putBatchItems(items){items.forEach(item=>batchItems.set(item.batchId+":"+item.index,structuredClone(item)));},
    async clearBatchItems(id){for(const [key,value] of batchItems)if(value.batchId===id)batchItems.delete(key);},
    async removeBatch(id){await this.clearBatchItems(id);batchRecords.delete(id);},
    async all() {
      return [...records.values()];
    },
    async directory(value) {
      if (arguments.length) selected = value;
      return selected;
    },
    async put(r) {
      records.set(r.id, { ...r, source: { ...r.source }, identity: r.identity && { ...r.identity } });
    },
    async remove(id) {
      records.delete(id);
    }
  };
  const held = new Set();
  const locks = {
    async request(name, _, callback) {
      if (held.has(name)) return callback(null);
      held.add(name);
      try {
        return await callback({ name });
      } finally {
        held.delete(name);
      }
    }
  };
  return { handle, entries, directory, registry, records, batchRecords, batchItems, locks, held };
}
module.exports = { diskFixture };
