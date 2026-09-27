const { test } = require('node:test'),
  assert = require('node:assert/strict'),
  { createHash, randomUUID } = require('node:crypto');
const sha = require('../../assets/web/sha256.js'),
  ls = require('../../assets/web/ls-cache.js'),
  { diskFixture } = require('./disk_fixture.cjs');
const identity = (size) => ({
  taskId: randomUUID(),
  sourceId: 'source',
  resourceId: 'file',
  version: '"version"',
  fileName: ' 目录/碧绿\\demo\n.txt ',
  size,
  chunkSize: 65536,
  createdUnixMs: 1790100000000,
  sha256: null
});
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
test('incremental SHA-256 matches independent vectors at every padding boundary', () => {
  for (const size of [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 1024, 1000000]) {
    const bytes = Buffer.alloc(size, 97),
      h = new sha.Hash();
    for (let i = 0; i < size; i += 17) h.update(bytes.subarray(i, i + 17));
    assert.equal(sha.hex(h.digest()), hash(bytes));
  }
});
test('browser container supports reordered checkpoints, recovery and original bytes', async () => {
  const f = diskFixture(),
    id = identity(65539),
    a = Buffer.alloc(65536, 17),
    b = Buffer.from('end');
  id.sha256 = hash(Buffer.concat([a, b]));
  const handle = f.handle('owned.ls');
  let cache = await new ls.Cache(handle, id).initialize();
  await cache.commit([{ index: 1, bytes: b }]);
  cache = new ls.Cache(handle, id);
  const recovered = await cache.recover();
  assert.equal(recovered.bytes, 3);
  assert.deepEqual(cache.missing(), [0]);
  await cache.commit([{ index: 0, bytes: a }]);
  const output = f.handle('original'),
    receipt = await cache.export(output);
  assert.equal(receipt.sha256, id.sha256);
  assert.deepEqual(output.bytes, Buffer.concat([a, b]));
  assert.equal((await ls.header(await handle.getFile())).id.fileName, id.fileName);
});
test('failed browser close acknowledges no bytes and recovery retains the previous checkpoint', async () => {
  const f = diskFixture(),
    id = identity(65537),
    handle = f.handle('owned.ls'),
    cache = await new ls.Cache(handle, id).initialize();
  await cache.commit([{ index: 1, bytes: Buffer.from('x') }]);
  const before = Buffer.from(handle.bytes);
  handle.failClose = true;
  await assert.rejects(cache.commit([{ index: 0, bytes: Buffer.alloc(65536) }]));
  assert.equal(cache.bytes, 1);
  assert.deepEqual(handle.bytes, before);
  await cache.recover();
  assert.deepEqual(cache.missing(), [0]);
});
test('incomplete tail recovery, identity mismatch and corruption do not mix ranges', async () => {
  const f = diskFixture(),
    id = identity(3),
    h = f.handle('owned.ls');
  await new ls.Cache(h, id).initialize();
  const baseline = Buffer.from(h.bytes);
  h.bytes = Buffer.concat([h.bytes, Buffer.from('LSCHUNK1')]);
  await assert.rejects(new ls.Cache(h, { ...id, version: 'other' }).recover(), { code: 'localChanged' });
  assert.equal(h.bytes.length, baseline.length + 8);
  const cache = new ls.Cache(h, id);
  assert.equal((await cache.recover()).discarded, 8);
  await cache.commit([{ index: 0, bytes: Buffer.from('abc') }]);
  h.bytes[h.bytes.length - 41] ^= 1;
  const broken = Buffer.from(h.bytes);
  await assert.rejects(new ls.Cache(h, id).recover(), { code: 'cacheFormat' });
  assert.deepEqual(h.bytes, broken);
});
test('empty sources, cancellation and existing output files retain data', async () => {
  const f = diskFixture(),
    empty = await new ls.Cache(f.handle('empty.ls'), identity(0)).initialize(),
    out = f.handle('empty');
  assert.equal((await empty.export(out)).sha256, hash(Buffer.alloc(0)));
  const cache = await new ls.Cache(f.handle('a.ls'), identity(3)).initialize();
  await cache.commit([{ index: 0, bytes: Buffer.from('abc') }]);
  out.bytes = Buffer.from('existing');
  await assert.rejects(cache.export(out), { code: 'localChanged' });
  assert.equal(out.bytes.toString(), 'existing');
  const stop = new AbortController();
  stop.abort();
  await assert.rejects(cache.recover(stop.signal), { code: 'aborted' });
});
test('names stay bounded by UTF-8 bytes, preserve Unicode and avoid cross-platform device names', () => {
  for (const name of ['CON', 'nul.txt', 'a/CON', 'a\\NUL', '..', '']) assert.match(ls.safeName(name), /^download-/);
  const name = ls.safeName('😀'.repeat(100) + '.txt');
  assert.ok(Buffer.byteLength(name) <= 140);
  assert.ok(!name.includes('\uFFFD'));
  assert.equal(ls.safeName('目录/碧绿 %.txt'), '碧绿 %.txt');
});

test('staging amortizes browser closes without reporting uncommitted bytes', async () => {
  const f = diskFixture(),
    id = identity(65537),
    handle = f.handle('owned.ls'),
    cache = await new ls.Cache(handle, id).initialize();
  const header = Buffer.from(handle.bytes);
  await cache.stage([{ index: 1, bytes: Buffer.from('x') }]);
  await cache.stage([{ index: 0, bytes: Buffer.alloc(65536, 9) }]);
  assert.equal(cache.bytes, 0);
  assert.equal(cache.stagedBytes, 65537);
  assert.equal(handle.writes, 1);
  assert.deepEqual(handle.bytes, header);
  await cache.checkpoint();
  assert.equal(cache.bytes, 65537);
  assert.equal(cache.stagedBytes, 0);
  assert.equal(handle.writes, 2);
});
test('discarding an open staging transaction keeps the previous complete container', async () => {
  const f = diskFixture(),
    id = identity(65537),
    h = f.handle('owned.ls'),
    cache = await new ls.Cache(h, id).initialize();
  await cache.commit([{ index: 1, bytes: Buffer.from('x') }]);
  const before = Buffer.from(h.bytes);
  await cache.stage([{ index: 0, bytes: Buffer.alloc(65536) }]);
  await cache.abortStaged();
  assert.equal(cache.bytes, 1);
  assert.equal(cache.stagedBytes, 0);
  assert.deepEqual(h.bytes, before);
  await cache.recover();
  assert.deepEqual(cache.missing(), [0]);
});
test('every field and record length is bounded before allocation', async () => {
  for (const change of [
    { size: Number.MAX_SAFE_INTEGER },
    { chunkSize: 0 },
    { chunkSize: ls.MAX + 1 },
    { taskId: 'bad' },
    { version: 'x\r\ny' },
    { sha256: 'bad' }
  ])
    assert.throws(() => new ls.Cache({}, { ...identity(1), ...change }), { code: 'cacheFormat' });
  const f = diskFixture(),
    id = identity(1),
    h = f.handle('owned.ls'),
    cache = await new ls.Cache(h, id).initialize();
  await assert.rejects(cache.commit([{ index: 0, bytes: Buffer.from('xx') }]), { code: 'cacheFormat' });
});
