const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createHash } = require('node:crypto');
const { Manager, MemorySink } = require('../../assets/web/download-engine.js');
const bytes = Buffer.from('confirmed-ranges-survive-auth');
const digest = value => createHash('sha256').update(value).digest('hex');
async function settled(task) {
  for (let n = 0; n < 1000; n++) {
    if (!task.promise && !['queued', 'ready'].includes(task.state)) return;
    await new Promise(resolve => setTimeout(resolve, 3));
  }
  throw Error('download did not settle');
}
async function fixture(t) {
  const requests = [], state = { deny: 0, phase: 'range', etag: '"v1"', changedManifest: false };
  const source = { sessionId: 'approved-session', fileId: 'first', name: 'fixture.bin', size: bytes.length };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://fixture');
    const file = url.searchParams.get('fileId');
    const phase = req.method === 'HEAD' ? 'head' : req.method === 'POST' ? 'manifest' : 'range';
    requests.push({ url, method: req.method, range: req.headers.range, match: req.headers['if-match'] });
    // Only the original approved session is accepted; no implicit approval/migration.
    if (url.searchParams.get('sessionId') !== source.sessionId) { res.writeHead(403).end(); return; }
    if (state.deny && phase === state.phase && file !== 'sibling' && (phase !== 'range' || req.headers.range !== 'bytes=0-3')) {
      res.writeHead(state.deny).end(); return;
    }
    if (phase === 'manifest') {
      res.setHeader('Content-Type', 'application/json');
      const metadata = { fileName: source.name, size: state.changedManifest ? bytes.length + 1 : bytes.length };
      res.end(JSON.stringify({ sessionId: source.sessionId, files: { first: metadata, sibling: metadata } })); return;
    }
    res.setHeader('ETag', state.etag); res.setHeader('Accept-Ranges', 'bytes');
    if (phase === 'head') { res.setHeader('Content-Length', bytes.length); res.end(); return; }
    const [, a, b] = req.headers.range.match(/^bytes=(\d+)-(\d+)$/), start = +a, end = +b;
    res.writeHead(206, { 'Content-Length': end - start + 1, 'Content-Range': `bytes ${start}-${end}/${bytes.length}` });
    res.end(bytes.subarray(start, end + 1));
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const manager = new Manager({ fetch: (url, options) => fetch(base + url, options), chunkSize: 4, timeout: 1000 });
  const task = manager.add(source, new MemorySink(bytes.length));
  t.after(() => { manager.close(); server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); });
  return { manager, task, state, requests, source };
}
for (const status of [401, 403]) test(`HTTP ${status} retains confirmed ranges, never auto-retries, and revalidates before explicit recovery`, async t => {
  const f = await fixture(t); f.state.deny = status;
  f.manager.start(f.task);
  const sibling = f.manager.add({ ...f.source, fileId: 'sibling' }, new MemorySink(bytes.length)); f.manager.start(sibling);
  await settled(sibling);
  assert.equal(f.task.error, 'authRequired'); assert.equal(f.task.state, 'failed'); assert.equal(f.task.offset, 4);
  assert.equal(sibling.state, 'complete'); assert.equal(digest(Buffer.from(await sibling.sink.blob().arrayBuffer())), digest(bytes));
  const count = f.requests.length; await new Promise(resolve => setTimeout(resolve, 30)); assert.equal(f.requests.length, count);
  // Both revalidation phases classify auth identically and retain the exact prefix.
  for (const phase of ['head', 'manifest']) {
    f.state.phase = phase; const before = f.requests.length;
    f.manager.start(f.task); await settled(f.task);
    assert.equal(f.task.error, 'authRequired'); assert.equal(f.task.offset, 4);
    assert.ok(f.requests.slice(before).every(r => !r.range));
  }
  f.state.deny = 0; const before = f.requests.length;
  f.manager.start(f.task); await settled(f.task);
  assert.equal(f.task.state, 'complete');
  assert.deepEqual(f.requests.slice(before, before + 2).map(r => r.method), ['HEAD', 'POST']);
  assert.equal(f.requests[before].match, '"v1"'); assert.equal(f.requests[before + 2].range, 'bytes=4-7');
  assert.equal(digest(Buffer.from(await f.task.sink.blob().arrayBuffer())), digest(bytes));
  assert.equal(f.requests.filter(r => r.url.searchParams.get('fileId') === 'first' && r.range === 'bytes=0-3').length, 1);
});
for (const change of ['etag', 'manifest']) test(`authorization renewal cannot reuse a prefix after ${change} changed`, async t => {
  const f = await fixture(t); f.state.deny = 401; f.manager.start(f.task); await settled(f.task);
  f.state.deny = 0; if (change === 'etag') f.state.etag = '"v2"'; else f.state.changedManifest = true;
  const before = f.requests.length; f.manager.start(f.task); await settled(f.task);
  assert.equal(f.task.error, 'sourceChanged'); assert.equal(f.task.state, 'blocked');
  assert.ok(f.requests.slice(before).every(r => !r.range));
});
for (const status of [404, 410, 429, 503]) test(`HTTP ${status} remains distinct from authorization`, async t => {
  const f = await fixture(t); f.state.deny = status; f.manager.start(f.task); await settled(f.task);
  assert.equal(f.task.error, status === 429 ? 'busy' : status === 503 ? 'network' : 'sourceEnded');
  assert.equal(f.task.state, status < 429 ? 'blocked' : 'failed'); assert.equal(f.task.offset, 4);
});
