const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { Manager, MemorySink, DiskSink, BUFFER_LIMIT, sourceUrl } = require('../../assets/web/download-engine.js');
const source = { sessionId: 'session old', fileId: 'f/1', name: 'folder/demo.bin', size: 17 };
const data = Uint8Array.from({ length: source.size }, (_, i) => i * 7);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(fn) { for (let i = 0; i < 500; i++) { if (fn()) return; await sleep(2); } throw new Error('condition timed out'); }
async function settled(task) { await waitFor(() => !task.promise && !['queued', 'ready'].includes(task.state)); }
function fixture(options = {}) {
  const requests = []; let tag = '"version-1"';
  const fetch = async (url, init) => {
    requests.push({ url, ...init });
    const custom = await options.respond?.(url, init, requests); if (custom) return custom;
    if (init.method === 'POST') return Response.json({ sessionId: source.sessionId, files: { [source.fileId]: { fileName: source.name, size: source.size } } });
    const headers = { ETag: tag, 'Content-Length': String(source.size), 'Accept-Ranges': 'bytes' };
    if (init.method === 'HEAD') return new Response(null, { headers });
    const [, a, b] = init.headers.Range.match(/bytes=(\d+)-(\d+)/), start = +a, end = +b;
    return new Response(data.slice(start, end + 1), { status: 206, headers: { ...headers, 'Content-Length': String(end - start + 1), 'Content-Range': `bytes ${start}-${end}/${source.size}` } });
  };
  const manager = new Manager({ fetch, chunkSize: 4, onChange: options.onChange, timeout: options.timeout || 1000 });
  const task = manager.add(source, options.sink || new MemorySink(source.size));
  return { manager, task, requests, setTag(value) { tag = value; } };
}
test('bounded ranges preserve raw bytes and verify session, length and ETag through completion', async () => {
  const f = fixture(); f.manager.start(f.task); await settled(f.task);
  assert.equal(f.task.state, 'complete'); assert.equal(f.task.offset, source.size);
  assert.equal(hash(Buffer.from(await f.task.sink.blob().arrayBuffer())), hash(data));
  const ranges = f.requests.filter(r => r.headers?.Range);
  assert.deepEqual(ranges.map(r => r.headers.Range), ['bytes=0-3', 'bytes=4-7', 'bytes=8-11', 'bytes=12-15', 'bytes=16-16']);
  assert.ok(ranges.every(r => r.headers['If-Match'] === '"version-1"' && r.url === sourceUrl(f.task)));
  assert.equal(f.requests.filter(r => r.method === 'HEAD').length, 2); assert.equal(f.requests.filter(r => r.method === 'POST').length, 1);
});
test('pause drains a pending range, preserves complete chunks, and resume re-fetches source metadata without duplicating bytes', async () => {
  let hanging = true, pendingSignal;
  const f = fixture({ respond: async (_, init) => {
    if (hanging && init.headers?.Range === 'bytes=4-7') { pendingSignal = init.signal; await new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))); }
  } });
  f.manager.start(f.task); await waitFor(() => pendingSignal); const count = f.requests.length;
  await f.manager.pause(f.task); assert.equal(pendingSignal.aborted, true); assert.equal(f.task.state, 'paused'); assert.equal(f.task.error, null); assert.equal(f.task.offset, 4);
  await sleep(20); assert.equal(f.requests.length, count);
  hanging = false; f.manager.start(f.task); await settled(f.task);
  assert.equal(f.task.state, 'complete'); assert.equal(hash(Buffer.from(await f.task.sink.blob().arrayBuffer())), hash(data));
  assert.equal(f.requests.filter(r => r.method === 'POST').length, 2);
  assert.equal(f.requests.filter(r => r.headers?.Range === 'bytes=0-3').length, 1);
});
test('short response is never committed; retry revalidates then fetches only the uncommitted range', async () => {
  let broken = true;
  const f = fixture({ respond: (_, init) => broken && init.headers?.Range === 'bytes=4-7' ? new Response(new Uint8Array(2), { status: 206,
    headers: { ETag: '"version-1"', 'Content-Length': '4', 'Content-Range': 'bytes 4-7/17' } }) : null });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.state, 'failed'); assert.equal(f.task.error, 'shortResponse'); assert.equal(f.task.offset, 4);
  broken = false; f.manager.start(f.task); await settled(f.task); assert.equal(f.task.state, 'complete');
  assert.equal(f.requests.filter(r => r.headers?.Range === 'bytes=0-3').length, 1);
});
for (const [name, headers, status] of [
  ['wrong range', { ETag: '"version-1"', 'Content-Length': '4', 'Content-Range': 'bytes 1-4/17' }, 206],
  ['wrong length', { ETag: '"version-1"', 'Content-Length': '2', 'Content-Range': 'bytes 0-3/17' }, 206],
  ['wrong version', { ETag: '"version-2"', 'Content-Length': '4', 'Content-Range': 'bytes 0-3/17' }, 206],
  ['whole-file response', { ETag: '"version-1"', 'Content-Length': '17' }, 200],
]) test(`${name} is rejected without committing bytes`, async () => {
  const f = fixture({ respond: (_, init) => init.headers?.Range ? new Response(new Uint8Array(4), { status, headers }) : null });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.error, 'invalidRange'); assert.equal(f.task.offset, 0); assert.notEqual(f.task.state, 'complete');
});
test('oversized response with a false Content-Length is aborted within one range budget', async () => {
  const f = fixture({ respond: (_, init) => init.headers?.Range ? new Response(new Uint8Array(5), { status: 206,
    headers: { ETag: '"version-1"', 'Content-Length': '4', 'Content-Range': 'bytes 0-3/17' } }) : null });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.error, 'invalidRange'); assert.equal(f.task.offset, 0);
});
test('confirmed ended sessions never request new approval or silently migrate to another sharing session', async () => {
  const f = fixture({ respond: (_, init) => init.method === 'HEAD' ? new Response(null, { status: 410 }) : null });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.state, 'blocked'); assert.equal(f.task.error, 'sourceEnded');
  assert.equal(f.requests.length, 1); f.manager.start(f.task); assert.equal(f.requests.length, 1);
});
test('a changed manifest session or file cannot mix content from a new share', async () => {
  const f = fixture({ respond: (_, init) => init.method === 'POST' ? Response.json({ sessionId: 'new-session', files: {} }) : null });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.state, 'blocked'); assert.equal(f.task.error, 'sourceChanged'); assert.equal(f.task.offset, 0);
});
test('non-seekable and weak-validator sources retain only the ordinary download path', async () => {
  for (const headers of [{ 'Content-Length': '17', ETag: '"v"', 'Accept-Ranges': 'none' }, { 'Content-Length': '17', ETag: 'W/"v"', 'Accept-Ranges': 'bytes' }]) {
    const f = fixture({ respond: () => new Response(null, { headers }) }); f.manager.start(f.task); await settled(f.task);
    assert.equal(f.task.state, 'blocked'); assert.equal(f.task.error, 'rangeUnsupported');
  }
});
test('pause and immediate continue cannot start a second writer while the old request drains', async () => {
  let release, stale;
  const f = fixture({ respond: async (_, init) => { if (init.headers?.Range === 'bytes=0-3') { stale = init.signal; return await new Promise(resolve => release = resolve); } } });
  f.manager.start(f.task); await waitFor(() => release); const pending = f.manager.pause(f.task); f.manager.start(f.task);
  assert.equal(stale.aborted, true); assert.equal(f.requests.filter(r => r.headers?.Range).length, 1);
  release(new Response(new Uint8Array(4), { status: 206 })); await pending; assert.equal(f.task.state, 'paused'); assert.equal(f.task.offset, 0);
});
test('cancellation drains a pending operation and does not run a queued cancelled task', async () => {
  let pendingSignal;
  const f = fixture({ respond: async (_, init) => { if (init.headers?.Range) { pendingSignal = init.signal; await new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted')))); } } });
  f.manager.start(f.task); await waitFor(() => pendingSignal);
  const queued = f.manager.add(source, new MemorySink(source.size)); f.manager.start(queued); assert.equal(queued.state, 'queued');
  await f.manager.cancel(queued); await f.manager.cancel(f.task); assert.equal(f.task.state, 'cancelled'); assert.equal(f.task.offset, 0); assert.equal(queued.state, 'cancelled');
});
test('request timeout is recoverable and removes the active slot', async () => {
  const f = fixture({ timeout: 10, respond: async (_, init) => { await new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted')))); } });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.error, 'timeout'); assert.equal(f.task.state, 'failed'); assert.equal(f.manager.active, null);
});
function fakeHandle() {
  let bytes = new Uint8Array(0), stamp = 1;
  const handle = { failWrite: false, failClose: false, getFile: async () => ({ size: bytes.length, lastModified: stamp }),
    mutate() { stamp++; }, read: () => bytes,
    createWritable: async ({ keepExistingData }) => {
      let tmp = keepExistingData ? bytes.slice() : new Uint8Array(0), aborted = false;
      return { async truncate(n) { tmp = tmp.slice(0, n); },
        async write({ position, data }) { assert.equal(aborted, false); const next = new Uint8Array(Math.max(tmp.length, position + data.length)); next.set(tmp); next.set(data, position); tmp = next; if (handle.failWrite) throw new Error('disk full'); },
        async close() { if (handle.failClose) throw new Error('close failed'); assert.equal(aborted, false); bytes = tmp; stamp++; },
        async abort() { aborted = true; } };
    } };
  return handle;
}
test('disk checkpoints commit partial bytes and resume by offset; local changes stop recovery', async () => {
  const h = fakeHandle(), sink = new DiskSink(h); await sink.open(); await sink.write(data.slice(0, 4), 0);
  assert.equal(h.read().length, 0); assert.equal(await sink.checkpoint(), 4); assert.deepEqual(h.read(), data.slice(0, 4));
  await sink.open(); await sink.write(data.slice(4), 4); await sink.checkpoint(); assert.equal(hash(h.read()), hash(data));
  h.mutate(); await assert.rejects(sink.open(), { code: 'localChanged' });
});
test('write failure rolls back the whole uncommitted writer, not a partially written chunk', async () => {
  const h = fakeHandle(), sink = new DiskSink(h); await sink.open(); await sink.write(data.slice(0, 4), 0); await sink.checkpoint();
  await sink.open(); h.failWrite = true; await assert.rejects(sink.write(data.slice(4, 8), 4), { code: 'storage' });
  assert.equal(sink.offset, 4); assert.equal(await sink.checkpoint(), 4); assert.deepEqual(h.read(), data.slice(0, 4));
});
test('cancelling disk writes preserves the last user-file checkpoint without deleting it', async () => {
  const h = fakeHandle(), sink = new DiskSink(h); await sink.open(); await sink.write(data.slice(0, 4), 0); await sink.checkpoint();
  await sink.open(); await sink.write(data.slice(4), 4); await sink.discard(); assert.equal(sink.offset, 4); assert.equal(h.read().length, 4);
});
test('failed disk close cannot be reported as complete', async () => {
  const h = fakeHandle(); h.failClose = true; const f = fixture({ sink: new DiskSink(h) });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.state, 'failed'); assert.equal(f.task.offset, 0); assert.equal(h.read().length, 0);
});
test('file buffers, total reservations and task count are explicitly bounded', async () => {
  assert.throws(() => new MemorySink(BUFFER_LIMIT + 1), { code: 'storageUnsupported' });
  const manager = new Manager({ fetch: async () => {} });
  for (let i = 0; i < 2; i++) manager.add({ ...source, size: BUFFER_LIMIT }, new MemorySink(BUFFER_LIMIT));
  assert.throws(() => manager.add(source, new MemorySink(source.size)), { code: 'memoryBudget' });
  await manager.remove(manager.tasks[0]); assert.doesNotThrow(() => manager.add(source, new MemorySink(source.size))); manager.close();
  const m = new Manager({ fetch: async () => {} }); for (let i = 0; i < 20; i++) m.add(source, new MemorySink(source.size));
  assert.throws(() => m.add(source, new MemorySink(source.size)), { code: 'taskLimit' }); m.close();
});
test('zero-byte file completes only after source validation with no invalid byte range', async () => {
  const calls = [], m = new Manager({ fetch: async (_, init) => { calls.push(init); return init.method === 'POST' ? Response.json({ sessionId: 's', files: { f: { fileName: 'empty', size: 0 } } }) : new Response(null, { headers: { ETag: '"zero"', 'Content-Length': '0', 'Accept-Ranges': 'bytes' } }); } });
  const task = m.add({ sessionId: 's', fileId: 'f', name: 'empty', size: 0 }, new MemorySink(0)); m.start(task); await settled(task);
  assert.equal(task.state, 'complete'); assert.equal(task.sink.blob().size, 0); assert.equal(calls.some(r => r.headers?.Range), false);
});

test('source changes after the final chunk are blocked before offering a saved result', async () => {
  const f = fixture({ onChange: tasks => { if (tasks[0]?.offset === source.size) f.setTag('"version-2"'); } });
  f.manager.start(f.task); await settled(f.task); assert.equal(f.task.state, 'blocked'); assert.equal(f.task.error, 'sourceChanged');
});
test('resumed tasks reject a different ETag before sending another byte range', async () => {
  let hold = true;
  const f = fixture({ respond: async (_, init) => { if (hold && init.headers?.Range === 'bytes=4-7') await new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted')))); } });
  f.manager.start(f.task); await waitFor(() => f.task.offset === 4); await f.manager.pause(f.task); const ranges = f.requests.filter(r => r.headers?.Range).length;
  hold = false; f.setTag('"version-2"'); f.manager.start(f.task); await settled(f.task);
  assert.equal(f.task.state, 'blocked'); assert.equal(f.task.error, 'sourceChanged'); assert.equal(f.requests.filter(r => r.headers?.Range).length, ranges);
});
test('single-lane queue starts the next task only after the current one has settled', async () => {
  const f = fixture(); f.manager.start(f.task); const second = f.manager.add(source, new MemorySink(source.size)); f.manager.start(second);
  assert.equal(second.state, 'queued'); await settled(second); assert.equal(f.task.state, 'complete'); assert.equal(second.state, 'complete');
  const firstLastHead = f.requests.findIndex((r, i) => i > 1 && r.method === 'HEAD');
  assert.equal(f.requests[firstLastHead + 1].method, 'HEAD'); assert.equal(f.manager.active, null);
});
