const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Reader, parsePage, encodingFor, constants } = require('../../assets/web/text-preview.js');

function fixture(input, options = {}) {
  const bytes = Buffer.isBuffer(input) ? input : Buffer.from(input);
  const requests = [];
  let etag = '"v1"';
  const fetch = async (_, request) => {
    requests.push(request);
    if (options.fetch) return options.fetch(request, bytes);
    if (request.method === 'HEAD') return new Response(null, { headers: {
      'Content-Length': String(bytes.length), 'Accept-Ranges': options.unseekable ? 'none' : 'bytes', ETag: etag,
    } });
    if (request.headers['If-Match'] !== etag) return new Response(null, { status: 412 });
    const [, a, b] = request.headers.Range.match(/^bytes=(\d+)-(\d+)$/);
    const start = Number(a), end = Number(b), body = bytes.subarray(start, end + 1);
    return new Response(body, { status: 206, headers: {
      'Content-Length': String(body.length), 'Content-Range': `bytes ${start}-${end}/${bytes.length}`, ETag: etag,
    } });
  };
  const reader = new Reader('/download?sessionId=fixture', bytes.length, { ...options, fetch });
  return { reader, requests, bytes, change() { etag = '"v2"'; } };
}

async function readAll(input, encoding = 'auto') {
  const f = fixture(input, { encoding });
  await f.reader.init();
  await f.reader.ensureRows(Number.MAX_SAFE_INTEGER);
  const rows = await f.reader.getRows(0, f.reader.rows);
  f.reader.close();
  return rows;
}

test('mixed newlines, empty lines, final fragments and literal HTML stay plain text', async () => {
  const rows = await readAll('alpha\r\n\rbravo\n<script>alert(1)</script>\rEND');
  assert.deepEqual(rows.map(x => [x.number, x.text]), [[1, 'alpha'], [2, ''], [3, 'bravo'], [4, '<script>alert(1)</script>'], [5, 'END']]);
  assert.deepEqual((await readAll('a\n')).map(x => x.text), ['a', '']);
  assert.deepEqual((await readAll('')).map(x => x.text), ['']);
});

test('BOM selection supports UTF-8 and both UTF-16 orders without stripping mid-file BOMs', async () => {
  const text = '碧绿😀\r\n甲\uFEFF乙';
  const utf8 = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(text)]);
  const le = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]);
  const be = Buffer.from(le); be.swap16();
  for (const input of [utf8, le, be]) assert.deepEqual((await readAll(input)).map(x => x.text), ['碧绿😀', '甲\uFEFF乙']);
  assert.throws(() => encodingFor(Buffer.from([0xff, 0xfe, 0, 0]), 'auto'), { code: 'decode' });
});

test('manual GB18030 decoding preserves two-byte and four-byte characters', async () => {
  const data = Buffer.from([0xd6, 0xd0, 0xce, 0xc4, 13, 10, 0x94, 0x39, 0xfc, 0x36]);
  assert.deepEqual((await readAll(data, 'gb18030')).map(x => x.text), ['中文', '😀']);
  await assert.rejects(readAll(data), { code: 'decode' });
});

test('UTF-8 characters and CRLF crossing range boundaries are re-read without corruption', async () => {
  for (const suffix of ['😀\r\n末行', '\r\n末行', '\r末行']) {
    for (let padding = 0; padding < 4; padding++) {
      const input = 'a\n'.repeat(32765) + 'z'.repeat(padding) + suffix;
      const rows = await readAll(input);
      assert.equal(rows[32765].text, 'z'.repeat(padding) + (suffix.startsWith('😀') ? '😀' : ''));
      assert.equal(rows.at(-1).text, '末行');
      assert.equal(rows.at(-1).number, 32767);
    }
  }
});

test('UTF-16 surrogate and newline boundaries are stable across many pages', async () => {
  const original = '甲😀\r\n'.repeat(12000) + '最后';
  for (const bigEndian of [false, true]) {
    const input = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(original, 'utf16le')]);
    if (bigEndian) input.swap16();
    const rows = await readAll(input);
    assert.equal(rows.length, 12001);
    assert.ok(rows.slice(0, 12000).every(x => x.text === '甲😀'));
    assert.equal(rows.at(-1).text, '最后');
  }
});

test('long lines use bounded continuation rows, preserve text and logical line numbers', async () => {
  const original = '甲😀'.repeat(40000);
  const rows = await readAll(original + '\r\nend');
  assert.equal(rows.filter(x => x.number === 1).map(x => x.text).join(''), original);
  assert.equal(rows[0].continued, false);
  assert.ok(rows.slice(1, -1).every(x => x.number === 1 && x.continued));
  assert.ok(rows.every(x => Buffer.byteLength(x.text) <= constants.segment + 3));
  assert.equal(rows.at(-1).number, 2);
  assert.equal(rows.at(-1).text, 'end');
});

test('initial preview fetches one bounded range instead of the complete large file', async () => {
  const { reader, requests } = fixture('numbered row\n'.repeat(300000));
  await reader.init();
  assert.equal(requests.length, 2);
  assert.equal(requests[0].method, 'HEAD');
  assert.equal(requests[1].headers.Range, 'bytes=0-65535');
  assert.equal(requests[1].headers['If-Match'], '"v1"');
  assert.ok(reader.offset <= constants.chunk);
  assert.ok(reader.offset < reader.size);
  assert.equal(reader.eof, false);
  assert.equal((await reader.getRows(0, 30)).length, 30);
  assert.equal(requests.length, 2);
  reader.close();
});

test('sparse metadata and bounded LRU support re-reading evicted lines exactly', async () => {
  const original = Array.from({ length: 180000 }, (_, i) => `${i + 1}: 碧绿😀\r\n`).join('');
  const f = fixture(original, { cacheLimit: 128 * 1024 });
  await f.reader.init(); await f.reader.ensureRows(180001);
  assert.equal(f.reader.rows, 180001);
  assert.equal(f.reader.eof, true);
  assert.ok(f.reader.pages.every(p => !p.bytes && !p.index && !p.text));
  assert.ok(f.reader.cache.size <= 2);
  for (const row of [0, 170000, 2, 70000, 10]) {
    const [line] = await f.reader.getRows(row, 1);
    assert.equal(line.text, `${row + 1}: 碧绿😀`);
    assert.equal(line.number, row + 1);
  }
  assert.ok(f.reader.cacheBytes <= 128 * 1024);
  f.reader.close(); assert.equal(f.reader.cacheBytes, 0); assert.equal(f.reader.pages.length, 0);
});

test('a CR page boundary is reproducible after cache eviction', async () => {
  const original = 'x\r'.repeat(40000) + 'tail';
  const f = fixture(original, { cacheLimit: 1 });
  await f.reader.init(); await f.reader.ensureRows(40001);
  const rows = await f.reader.getRows(0, 32768);
  assert.ok(rows.every(x => x.text === 'x'));
  f.reader.close();
});

test('resource replacement stops reading rather than concatenating different versions', async () => {
  const f = fixture('one\n'.repeat(40000));
  await f.reader.init(); f.change();
  const previous = f.reader.rows;
  await assert.rejects(f.reader.ensureRows(previous + 1), { code: 'changed' });
  assert.equal(f.reader.rows, previous);
  f.reader.close();
});

test('non-seekable sources stop at HEAD and keep full downloads out of memory', async () => {
  const f = fixture('some text', { unseekable: true });
  await assert.rejects(f.reader.init(), { code: 'range' });
  assert.equal(f.requests.length, 1); f.reader.close();
});

test('invalid and truncated encodings fail explicitly, not as silent replacement characters', async () => {
  for (const value of [Buffer.from([0xc0, 0xaf]), Buffer.from([0xf0, 0x9f]), Buffer.from([0xff, 0xfe, 0x00, 0xd8])]) {
    await assert.rejects(readAll(value), { code: 'decode' });
  }
});

test('unexpected status, range, ETag and body lengths are rejected and streams canceled', async () => {
  for (const fault of ['full', 'offset', 'etag', 'short', 'oversized']) {
    let canceled = false;
    const f = fixture('data', { fetch: async request => {
      if (request.method === 'HEAD') return new Response(null, { headers: { 'Content-Length': '4', 'Accept-Ranges': 'bytes', ETag: '"v1"' } });
      const stream = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(fault === 'short' ? 3 : fault === 'oversized' ? 5 : 4)); if (fault === 'short') c.close(); }, cancel() { canceled = true; } });
      return new Response(stream, { status: fault === 'full' ? 200 : 206, headers: {
        'Content-Length': '4', 'Content-Range': fault === 'offset' ? 'bytes 1-4/4' : 'bytes 0-3/4', ETag: fault === 'etag' ? '"v2"' : '"v1"',
      } });
    } });
    await assert.rejects(f.reader.init(), error => ['range', 'changed', 'failed'].includes(error.code));
    assert.ok(canceled || fault === 'short'); f.reader.close();
  }
});

test('closing aborts in-flight requests and late replies do not mutate indexes', async () => {
  let resolveGet, signal;
  const f = fixture('data', { fetch: request => {
    if (request.method === 'HEAD') return Promise.resolve(new Response(null, { headers: { 'Content-Length': '4', 'Accept-Ranges': 'bytes', ETag: '"v1"' } }));
    signal = request.signal; return new Promise(resolve => { resolveGet = resolve; });
  } });
  const task = f.reader.init();
  while (!resolveGet) await new Promise(resolve => setImmediate(resolve));
  f.reader.close(); assert.equal(signal.aborted, true);
  resolveGet(new Response('data', { status: 206, headers: { 'Content-Length': '4', 'Content-Range': 'bytes 0-3/4', ETag: '"v1"' } }));
  await assert.rejects(task, { name: 'AbortError' });
  assert.equal(f.reader.pages.length, 0); assert.equal(f.reader.rows, 0);
});

test('parallel index requests serialize and never duplicate a page', async () => {
  const f = fixture('line\n'.repeat(100000));
  await f.reader.init();
  await Promise.all([f.reader.ensureRows(30000), f.reader.ensureRows(50000), f.reader.ensureRows(70000)]);
  assert.ok(f.reader.rows >= 70000);
  assert.equal(new Set(f.reader.pages.map(p => p.start)).size, f.reader.pages.length);
  const [row] = await f.reader.getRows(69999, 1); assert.equal(row.number, 70000); f.reader.close();
});

test('dense empty-line files keep only sparse page metadata and at most 4 MiB of cached data', async () => {
  const f = fixture('\n'.repeat(500000));
  await f.reader.init(); await f.reader.ensureRows(500001);
  assert.equal(f.reader.rows, 500001);
  assert.equal(f.reader.pages.length, 8);
  assert.ok(f.reader.cacheBytes <= constants.cache);
  assert.ok(f.reader.cache.size < f.reader.pages.length);
  const [row] = await f.reader.getRows(480000, 1);
  assert.equal(row.number, 480001); assert.equal(row.text, '');
  f.reader.close();
});

test('request timeout aborts the transport and releases the controller', async () => {
  let signal;
  const reader = new Reader('/download', 4, { timeout: 10, fetch: (_, options) => new Promise((_, reject) => {
    signal = options.signal;
    signal.addEventListener('abort', () => { const error = new Error('aborted'); error.name = 'AbortError'; reject(error); });
  }) });
  await assert.rejects(reader.init(), { name: 'AbortError' });
  assert.equal(signal.aborted, true); assert.equal(reader.controllers.size, 0); reader.close();
});
