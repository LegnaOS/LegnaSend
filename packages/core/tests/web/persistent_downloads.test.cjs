const { test } = require('node:test'),
  assert = require('node:assert/strict'),
  { randomUUID, createHash } = require('node:crypto');
const { diskFixture } = require('./disk_fixture.cjs');
global.location = { origin: 'http://fixture' };
global.crypto = global.crypto || { randomUUID };
const { Manager, CHUNK } = require('../../assets/web/persistent-downloads.js');
const wait = async (fn) => {
  for (let i = 0; i < 2000; i++) {
    if (fn()) return;
    await new Promise((r) => setTimeout(r, 3));
  }
  throw new Error('timeout');
};
const hash = (b) => createHash('sha256').update(b).digest('hex');
function setup(options = {}) {
  const f = options.disk || diskFixture(),
    size = options.size ?? 5 * CHUNK + 3,
    source = { kind: 'web', fileId: 'f', name: 'file.bin', size },
    bytes = Buffer.alloc(size),
    requests = [];
  for (let i = 0; i < size; i++) bytes[i] = (i * 13 + Math.floor(i / CHUNK) * 7) & 255;
  let live = 0,
    peak = 0;
  const fetch = async (url, init) => {
    requests.push({ url, ...init });
    const response = await options.respond?.(url, init);
    if (response) return response;
    if (init.method === 'HEAD')
      return new Response(null, { headers: { 'Content-Length': String(size), ETag: '"version"', 'Accept-Ranges': 'bytes' } });
    const [, a, b] = init.headers.Range.match(/bytes=(\d+)-(\d+)/),
      start = Number(a),
      end = Number(b);
    live++;
    peak = Math.max(peak, live);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(resolve, 12);
      init.signal.addEventListener(
        'abort',
        () => {
          clearTimeout(timer);
          reject(Object.assign(new Error(), { name: 'AbortError' }));
        },
        { once: true }
      );
    }).finally(() => live--);
    return new Response(bytes.subarray(start, end + 1), {
      status: 206,
      headers: { 'Content-Length': String(end - start + 1), 'Content-Range': `bytes ${start}-${end}/${size}`, ETag: '"version"' }
    });
  };
  const manager = new Manager({ registry: f.registry, locks: options.locks || f.locks, fetch, timeout: 1000, retryDelay: options.retryDelay || 1000, online: options.online });
  manager.attachSession('session', { f: { fileName: source.name, size } });
  return { ...f, manager, source, bytes, requests, peak: () => peak };
}
test('four actual concurrent ranges checkpoint to .ls and restore original bytes', async () => {
  const f = setup();
  await f.manager.ready;
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state !== 'queued');
  assert.equal(task.state, 'complete', task.error);
  assert.equal(f.peak(), 4);
  assert.equal(hash(task.record.output.bytes), hash(f.bytes));
  assert.equal(task.record.handle, null);
  assert.equal(f.entries.size, 1);
  f.manager.close();
});
test('pause and page reconstruction restore disk ranges without repeating committed requests', async () => {
  let stop = false;
  const f = setup({
    respond: async (_, init) => {
      if (stop && init.headers?.Range) throw Object.assign(new Error(), { code: 'network' });
    }
  });
  await f.manager.ready;
  const task = await f.manager.add(f.source);
  f.manager.onChange = () => {
    if (task.offset + (task.pendingBytes || 0) >= 4 * CHUNK && task.state === 'downloading') {
      stop = true;
      f.manager.pause(task);
    }
  };
  await wait(() => !task.promise && task.state === 'paused');
  assert.equal(task.offset, 4 * CHUNK);
  f.manager.close();
  const second = setup({ disk: f });
  await second.manager.ready;
  const restored = second.manager.tasks[0];
  await second.manager.start(restored);
  await wait(() => !restored.promise && restored.state === 'complete');
  assert.ok(second.requests.filter((r) => r.headers?.Range).every((r) => !r.headers.Range.startsWith('bytes=0-')));
  assert.equal(hash(restored.record.output.bytes), hash(f.bytes));
  second.manager.close();
});
test('a changed source removes only the registered cache, not unrelated .ls files', async () => {
  let changed = false;
  const f = setup({ respond: async (_, init) => (changed && init.method === 'HEAD' ? new Response(null, { status: 412 }) : null) });
  await f.manager.ready;
  f.handle('user.ls').bytes = Buffer.from('user file');
  const task = await f.manager.add(f.source);
  f.manager.onChange = () => {
    if (task.offset + (task.pendingBytes || 0) >= 4 * CHUNK && task.state === 'downloading') {
      changed = true;
      f.manager.pause(task);
    }
  };
  await wait(() => !task.promise && task.state === 'paused');
  await f.manager.start(task);
  await wait(() => !task.promise && task.state === 'blocked');
  assert.equal(task.error, 'sourceChanged');
  assert.equal(f.entries.get('user.ls').bytes.toString(), 'user file');
  assert.equal(task.record.handle, null);
  f.manager.close();
});
for (const deniedStatus of [401, 403]) test(`authorization ${deniedStatus} retains cache and never reconnects automatically`, async () => {
  let denied = false;
  const f = setup({ respond: async (_, init) => (denied && init.method === 'HEAD' ? new Response(null, { status: deniedStatus }) : null) });
  await f.manager.ready;
  await f.manager.configureTransfers({ files: 1, ranges: 1, autoReconnect: true });
  const task = await f.manager.add(f.source);
  f.manager.onChange = () => {
    if (task.offset + (task.pendingBytes || 0) >= 4 * CHUNK && task.state === 'downloading') {
      denied = true;
      f.manager.pause(task);
    }
  };
  await wait(() => !task.promise && task.state === 'paused');
  await f.manager.start(task);
  await wait(() => !task.promise && task.state === 'failed');
  assert.equal(task.error, 'authRequired');
  assert.ok(task.record.handle);
  const retained = task.offset, count = f.requests.length;
  assert.ok(retained > 0);
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(f.requests.length, count); assert.equal(task.state, 'failed');
  const initialRangeCount = f.requests.filter(r => r.headers?.Range?.startsWith('bytes=0-')).length;
  denied = false; f.manager.onChange = () => {};
  await f.manager.start(task); await wait(() => !task.promise && task.state === 'complete');
  assert.equal(hash(task.record.output.bytes), hash(f.bytes));
  assert.equal(f.requests.filter(r => r.headers?.Range?.startsWith('bytes=0-')).length, initialRangeCount);
  f.manager.close();
});
test('local permission denial leaves existing source/cache state unchanged', async () => {
  const f = setup({ size: 3 });
  await f.manager.ready;
  f.directory.permission = 'denied';
  await assert.rejects(f.manager.add(f.source), { code: 'permission' });
  assert.equal(f.requests.length, 0);
  assert.equal(f.entries.size, 0);
  f.manager.close();
});

test('malformed/whole-file/short range replies never become committed cache data', async () => {
  for (const kind of ['whole', 'short', 'tag', 'range', 'large']) {
    const f = setup({
      size: 3,
      respond: async (_, init) => {
        if (!init.headers?.Range) return null;
        const data = kind === 'short' ? 'xx' : kind === 'large' ? 'xxxx' : 'xxx';
        return new Response(data, {
          status: kind === 'whole' ? 200 : 206,
          headers: {
            ETag: kind === 'tag' ? '"other"' : '"version"',
            'Content-Length': '3',
            'Content-Range': kind === 'range' ? 'bytes 1-3/3' : 'bytes 0-2/3'
          }
        });
      }
    });
    await f.manager.ready;
    const task = await f.manager.add(f.source);
    await wait(() => !task.promise && task.state === 'failed');
    assert.equal(task.offset, 0);
    assert.ok(['invalidRange', 'shortResponse'].includes(task.error));
    assert.equal(task.record.output, undefined);
    f.manager.close();
  }
});
test('transient failure preserves complete ranges and retry checks HEAD before GET', async () => {
  let failure = true;
  const f = setup({
    size: 7 * CHUNK,
    respond: async (_, init) => {
      if (failure && init.headers?.Range?.startsWith('bytes=4194304-')) return new Response('', { status: 503 });
    }
  });
  await f.manager.ready;
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state === 'failed');
  assert.ok(task.offset >= 4 * CHUNK);
  const committed = task.offset,
    start = f.requests.length;
  failure = false;
  await f.manager.start(task);
  await wait(() => !task.promise && task.state === 'complete');
  assert.equal(f.requests[start].method, 'HEAD');
  assert.ok(
    f.requests
      .slice(start)
      .filter((r) => r.headers?.Range)
      .every((r) => Number(r.headers.Range.match(/\d+/)[0]) >= 4 * CHUNK)
  );
  assert.equal(hash(task.record.output.bytes), hash(f.bytes));
  assert.ok(committed < task.size);
  f.manager.close();
});
test('zero-byte files do not invent ranges and existing destination names are preserved', async () => {
  const f = setup({ size: 0 });
  await f.manager.ready;
  const original = f.handle('file.bin');
  original.bytes = Buffer.from('user content');
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state === 'complete');
  assert.equal(f.requests.filter((r) => r.headers?.Range).length, 0);
  assert.equal(original.bytes.toString(), 'user content');
  assert.equal(task.record.outputName, 'file (1).bin');
  assert.equal(task.record.output.bytes.length, 0);
  f.manager.close();
});
test('three independent page managers share eight network permits at one origin', async () => {
  const shared = diskFixture().locks;
  let live = 0,
    peak = 0;
  const all = [0, 1, 2].map(() =>
    setup({
      locks: shared,
      respond: async (_, init) => {
        if (init.headers?.Range) {
          live++;
          peak = Math.max(peak, live);
          await new Promise((r) => setTimeout(r, 35));
          live--;
        }
        return null;
      }
    })
  );
  await Promise.all(all.map((f) => f.manager.ready));
  const tasks = await Promise.all(all.map((f) => f.manager.add(f.source)));
  await wait(() => tasks.every((t) => !t.promise && t.state === 'complete'));
  assert.equal(peak, 8);
  all.forEach((f) => f.manager.close());
});
test('task locks prevent duplicate writers before any network or disk access', async () => {
  const f = setup();
  await f.manager.ready;
  f.manager.locks = {
    async request(_, __, callback) {
      return callback(null);
    }
  };
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state === 'failed');
  assert.equal(task.error, 'busy');
  assert.equal(f.requests.length, 0);
  assert.equal(f.entries.size, 0);
  f.manager.close();
});
test('credentials are never copied into task descriptors or the .ls identity', async () => {
  const f = setup({ size: 3 });
  await f.manager.ready;
  const task = await f.manager.add({ ...f.source, sessionId: 'DO-NOT-PERSIST', password: 'SECRET', token: 'TOKEN' });
  await wait(() => !task.promise && task.state === 'complete');
  assert.doesNotMatch(JSON.stringify({ source: task.record.source, identity: task.record.identity }), /DO-NOT-PERSIST|SECRET|TOKEN/);
  f.manager.close();
});
test('completed tasks survive page reconstruction without touching original files', async () => {
  const f = setup({ size: 3 });
  await f.manager.ready;
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state === 'complete');
  const output = task.record.output;
  f.manager.close();
  const next = setup({ disk: f, size: 3 });
  await next.manager.ready;
  assert.equal(next.manager.tasks[0].state, 'complete');
  await next.manager.remove(next.manager.tasks[0]);
  assert.equal(output.bytes.length, 3);
  assert.equal(next.records.size, 0);
  next.manager.close();
});

test('initial registry failure rolls back only its new empty cache and remains retryable', async () => {
  const f = setup({ size: 3 });
  await f.manager.ready;
  const put = f.registry.put;
  let broken = true;
  f.registry.put = async (r) => {
    if (broken) throw new Error('disk full');
    return put(r);
  };
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state === 'failed');
  assert.equal(task.error, 'storage');
  assert.equal(f.entries.size, 0);
  broken = false;
  await f.manager.start(task);
  await wait(() => !task.promise && task.state === 'complete');
  assert.deepEqual(task.record.output.bytes, f.bytes);
  f.manager.close();
});
test('a published receipt recovers after final registry failure even when the sender ended', async () => {
  const f = setup({ size: 3 });
  await f.manager.ready;
  const put = f.registry.put;
  f.registry.put = async (r) => {
    if (r.state === 'complete' || r.state === 'failed') throw Object.assign(new Error(), { code: 'storage' });
    return put(r);
  };
  const task = await f.manager.add(f.source);
  await wait(() => !task.promise && task.state === 'failed');
  assert.deepEqual(task.record.output.bytes, f.bytes);
  assert.equal([...f.records.values()][0].state, 'saving');
  f.manager.close();
  f.registry.put = put;
  const second = setup({ disk: f, size: 3, respond: async () => new Response('', { status: 410 }) });
  await second.manager.ready;
  const restored = second.manager.tasks[0];
  await second.manager.start(restored);
  await wait(() => !restored.promise && restored.state === 'complete');
  assert.equal(second.requests.length, 0);
  assert.equal(f.entries.size, 1);
  assert.deepEqual(restored.record.output.bytes, f.bytes);
  second.manager.close();
});
test('cancel removes its own unpublished empty output but preserves modified output', async () => {
  for (const modified of [false, true]) {
    const f = setup({ size: 3 });
    await f.manager.ready;
    const output = f.manager.output.bind(f.manager);
    f.manager.output = async (task) => {
      await output(task);
      throw Object.assign(new Error(), { code: 'storage' });
    };
    const task = await f.manager.add(f.source);
    await wait(() => !task.promise && task.state === 'failed');
    if (modified) {
      task.record.output.bytes = Buffer.from('user edit');
      task.record.output.stamp++;
    }
    await f.manager.cancel(task);
    assert.equal(task.state, 'cancelled');
    assert.equal(f.entries.size, modified ? 1 : 0);
    if (modified) assert.equal(f.entries.get('file.bin').bytes.toString(), 'user edit');
    f.manager.close();
  }
});

test('source-ended cleanup preserves a cache modified outside the registered writer', async () => {
  let ended = false;
  const f = setup({ respond: async (_, init) => (ended && init.method === 'HEAD' ? new Response('', { status: 410 }) : null) });
  await f.manager.ready;
  const task = await f.manager.add(f.source);
  f.manager.onChange = () => {
    if (task.pendingBytes >= 4 * CHUNK && task.state === 'downloading') f.manager.pause(task);
  };
  await wait(() => !task.promise && task.state === 'paused');
  const cache = task.record.handle;
  cache.stamp++;
  cache.bytes[cache.bytes.length - 60] ^= 1;
  ended = true;
  await f.manager.start(task);
  await wait(() => !task.promise && task.state === 'blocked');
  assert.equal(task.error, 'cleanupPending');
  assert.equal(f.entries.get(cache.name), cache);
  f.manager.close();
});

test('pause while the task lock is pending aborts before starting source I/O', async () => {
  const disk = diskFixture();
  let grant;
  const locks = {
    request: (name, options, fn) =>
      name.startsWith('legnasend-download:')
        ? new Promise((resolve, reject) => {
            grant = () => Promise.resolve(fn({ name })).then(resolve, reject);
          })
        : disk.locks.request(name, options, fn)
  };
  const f = setup({ disk, locks, size: 3 });
  await f.manager.ready;
  const task = await f.manager.add(f.source);
  assert.equal(task.state, 'queued');
  assert.ok(task.promise);
  const paused = f.manager.pause(task);
  grant();
  await paused;
  assert.equal(task.state, 'paused');
  assert.equal(f.requests.length, 0);
  assert.equal(f.entries.size, 0);
  f.manager.close();
});

test('transfer concurrency settings persist and two range lanes respect the selected limit', async () => {
  const f = setup(); let settings;
  f.registry.transferSettings = async function(value) { if(arguments.length) settings={...value}; return settings; };
  await f.manager.ready;
  await f.manager.configureTransfers({files:1,ranges:2,autoReconnect:false});
  const t=await f.manager.add(f.source);await wait(()=>!t.promise&&t.state==='complete');
  assert.equal(f.peak(),2);assert.equal(f.manager.parallelFiles,1);f.manager.close();
  const second=setup({disk:f});await second.manager.ready;
  assert.equal(second.manager.parallelRanges,2);assert.equal(second.manager.parallelFiles,1);
  await assert.rejects(second.manager.configureTransfers({files:100,ranges:4,autoReconnect:true}),{code:'storage'});
  second.manager.close();
});
test('opt-in reconnect rechecks HEAD and only downloads missing committed ranges', async () => {
  let interrupted=false;
  const f=setup({retryDelay:1,respond:async(_,init)=>{
    if(!interrupted && init.headers?.Range?.startsWith('bytes=4194304-')) {interrupted=true;throw {code:'network'};}
  }});
  await f.manager.ready;await f.manager.configureTransfers({files:2,ranges:4,autoReconnect:true});
  const t=await f.manager.add(f.source);await wait(()=>!t.promise&&t.state==='complete');
  assert.equal(t.reconnectAttempts,1);assert.equal(hash(t.record.output.bytes),hash(f.bytes));
  assert.equal(f.requests.filter(r=>r.headers?.Range?.startsWith('bytes=0-')).length,1);
  assert.ok(f.requests.filter(r=>r.method==='HEAD').length>=3);f.manager.close();
});
test('reconnect is bounded and pause/close never restart waiting tasks', async () => {
  const f=setup({retryDelay:1,respond:async()=>{throw {code:'network'};}});
  await f.manager.ready;await f.manager.configureTransfers({files:2,ranges:4,autoReconnect:true});
  const t=await f.manager.add(f.source);await wait(()=>!t.promise&&t.state==='failed');
  assert.equal(t.reconnectAttempts,5);assert.equal(f.requests.length,6);f.manager.close();
  const offline=setup({online:()=>false,respond:async()=>{throw {code:'network'};}});
  await offline.manager.ready;await offline.manager.configureTransfers({files:2,ranges:4,autoReconnect:true});
  const waiting=await offline.manager.add(offline.source);await wait(()=>!waiting.promise&&waiting.state==='waiting');
  await offline.manager.pause(waiting);offline.manager.onlineListener();
  await new Promise(r=>setTimeout(r,10));assert.equal(waiting.state,'paused');assert.equal(offline.requests.length,1);
  offline.manager.close();
});
test('automatic retry never prompts for revoked write permission or restarts restored records', async () => {
  let prompts=0;const f=setup({retryDelay:1,respond:async()=>{f.directory.permission='denied';throw {code:'network'};}});
  await f.manager.ready;await f.manager.configureTransfers({files:1,ranges:1,autoReconnect:true});
  f.directory.requestPermission=async()=>{prompts++;return f.directory.permission;};
  const t=await f.manager.add(f.source);await wait(()=>!t.promise&&t.state==='failed');
  assert.equal(t.error,'permission');assert.equal(prompts,1,'only explicit add requests permission');assert.equal(f.requests.length,1);f.manager.close();
});

test('completed receipt capacity no longer prevents continuous downloads and never deletes saved files', async () => {
  const f=setup({size:8});await f.manager.ready;
  const saved=[];
  for(let i=0;i<23;i++) {
    const source={...f.source,fileId:`f-${i}`,name:`file-${i}.bin`};
    f.manager.files[source.fileId]={fileName:source.name,size:source.size};
    const t=await f.manager.add(source);
    await wait(()=>!t.promise&&t.state==='complete');saved.push(t.record.output);
  }
  assert.equal(f.manager.tasks.length,20);assert.equal(f.records.size,20);
  assert.equal(f.entries.size,23);saved.forEach(file=>assert.equal(file.bytes.length,8));f.manager.close();
});
