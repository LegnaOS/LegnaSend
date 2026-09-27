const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Reader, Heights } = require('../../assets/web/text-preview.js');
const { Search, expression } = require('../../assets/web/text-search.js');
function fixture(input, options = {}) {
  const data = Buffer.isBuffer(input) ? input : Buffer.from(input), requests = [];
  let etag = '"v1"';
  const reader = new Reader('/source', data.length, { encoding: options.encoding, fetch: async (_, request) => {
    requests.push(request);
    if (request.signal.aborted) throw Object.assign(new Error('cancelled'), { name: 'AbortError' });
    if (request.method === 'HEAD') return new Response(null, { headers: { ETag: etag, 'Accept-Ranges': 'bytes', 'Content-Length': String(data.length) } });
    if (request.headers['If-Match'] !== etag) return new Response(null, { status: 412 });
    if (options.pause && requests.length > 3) await options.pause(request.signal);
    const [, a, b] = request.headers.Range.match(/bytes=(\d+)-(\d+)/), start = +a, end = +b;
    return new Response(data.subarray(start, end + 1), { status: 206, headers: { ETag: etag, 'Content-Length': String(end - start + 1), 'Content-Range': `bytes ${start}-${end}/${data.length}` } });
  } });
  return { reader, requests, change: () => etag = '"v2"' };
}
test('literal search supports Chinese, Markdown body, metacharacters and case selection', async () => {
  const f = fixture('# 碧绿\n**needle** and NEEDLE\n[.*](link)\nİ needle'); await f.reader.init();
  const result = await new Search(f.reader, 'needle').run();
  assert.deepEqual(result.matches.map(x => x.line), [2, 2, 4]); assert.equal(result.complete, true);
  assert.equal((await new Search(f.reader, 'NEEDLE', { caseSensitive: true }).run()).matches.length, 1);
  assert.equal((await new Search(f.reader, '碧绿').run()).matches.length, 1);
  assert.equal((await new Search(f.reader, '[.*]').run()).matches.length, 1);
  assert.equal(expression('a+b', false).test('A+B'), true); f.reader.close();
});
test('indexed-only search never claims unread content; full search finds a distant result and exports seek metadata', async () => {
  const f = fixture('row without match\n'.repeat(12000) + '结尾目标\n'); await f.reader.init();
  const before = f.reader.offset;
  const loaded = await new Search(f.reader, '结尾目标').run();
  assert.equal(loaded.total, before); assert.equal(loaded.scanned, before); assert.equal(loaded.complete, true); assert.equal(loaded.matches.length, 0);
  const full = await new Search(f.reader, '结尾目标', { full: true }).run();
  assert.equal(full.scanned, f.reader.size); assert.equal(full.matches[0].line, 12001);
  assert.equal(f.reader.offset, before); f.reader.adopt(full.index); assert.equal(f.reader.eof, true);
  const requests = f.requests.length; assert.equal((await f.reader.getRows(full.matches[0].row, 1))[0].text, '结尾目标');
  assert.ok(f.requests.length - requests <= 1); f.reader.close();
});
test('matches straddling long-line segments and byte pages are found once, with split highlights', async () => {
  for (const padding of [16382, 65534]) {
    const f = fixture('x'.repeat(padding) + '目标needle😀' + 'x'.repeat(10000)); await f.reader.init();
    const result = await new Search(f.reader, '目标needle😀', { full: true }).run();
    assert.equal(result.matches.length, 1); assert.equal(result.matches[0].line, 1);
    assert.equal(result.matches[0].parts.length, 2); assert.equal(result.complete, true); f.reader.close();
  }
  const f = fixture('ab\ncd'); await f.reader.init(); assert.equal((await new Search(f.reader, 'abcd').run()).matches.length, 0); f.reader.close();
});
test('UTF-16 and GB18030 use decoded positions for highlights', async () => {
  for (const [data, encoding, query] of [[Buffer.from('\ufeff甲😀乙\r\n甲😀', 'utf16le'), 'auto', '😀'], [Buffer.from([0xd6,0xd0,0xce,0xc4,10,0xd6,0xd0]), 'gb18030', '中']]) {
    const f = fixture(data, { encoding }); await f.reader.init(); const result = await new Search(f.reader, query).run();
    assert.equal(result.matches.length, 2); assert.equal(result.error, null); f.reader.close();
  }
});
test('result cap is explicit and does not claim a complete scan; results contain no document strings', async () => {
  const f = fixture('a '.repeat(10000)); await f.reader.init();
  const result = await new Search(f.reader, 'a', { full: true }).run();
  assert.equal(result.matches.length, 1000); assert.equal(result.capped, true); assert.equal(result.complete, false);
  assert.equal(JSON.stringify(result.matches).includes('text'), false); assert.equal(result.reader.cacheBytes, 0); f.reader.close();
});
test('changed resources reject search; cancelling aborts the independent request without closing the viewport', async () => {
  const changed = fixture('hello'); await changed.reader.init(); changed.change();
  assert.equal((await new Search(changed.reader, 'hello').run()).error.code, 'changed'); changed.reader.close();
  let waiting, signal;
  const blocked = new Promise(r => waiting = r);
  const f = fixture('long document\n'.repeat(20000), { pause: async s => {
    signal = s; waiting(); await new Promise((_, reject) => s.addEventListener('abort', () => reject(Object.assign(new Error('closed'), { name: 'AbortError' })), { once: true }));
  } });
  await f.reader.init(); const search = new Search(f.reader, 'missing', { full: true }), run = search.run();
  await blocked; search.cancel(); await run;
  assert.equal(signal.aborted, true); assert.equal(search.cancelled, true); assert.equal(search.error, null); assert.equal(search.complete, false);
  assert.equal(f.reader.closed, false); assert.equal((await f.reader.getRows(0, 1))[0].text, 'long document'); f.reader.close();
});
test('height index keeps exact prefix offsets and binary row lookup after measurement', () => {
  const heights = new Heights(1000);
  assert.equal(heights.offset(500), 14000); assert.equal(heights.at(14005), 500);
  assert.equal(heights.measure(0, 100.2), true); assert.equal(heights.measure(0, 100.2), false);
  assert.equal(heights.offset(1), 100.2); assert.equal(heights.at(100), 0); assert.equal(heights.at(101), 1);
  assert.equal(heights.at(1e8), 999); heights.count = 2; assert.equal(heights.at(999), 1);
});

test('progress snapshots pin the indexed page count even if the scanner appends later', async () => {
  const f = fixture('line\n'.repeat(30000)); await f.reader.init();
  const snapshot = f.reader.snapshot(false), originalPages = snapshot.pageCount;
  await f.reader.ensureRows(f.reader.rows + 1); assert.ok(snapshot.pages.length > originalPages);
  const copy = new Reader(f.reader.url, f.reader.size, { fetch: f.reader.fetch }); await copy.request('HEAD'); copy.encoding = f.reader.encoding;
  copy.adopt(snapshot); assert.equal(copy.pages.length, originalPages); assert.equal(copy.offset, snapshot.offset);
  await copy.ensureRows(copy.rows + 1); assert.equal(copy.pages.length, originalPages + 1);
  copy.close(); f.reader.close();
});
