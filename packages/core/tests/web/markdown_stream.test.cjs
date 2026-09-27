const { test } = require('node:test'),
  assert = require('node:assert/strict');
const { Stream, tokens } = require('../../assets/web/markdown-blocks.js');
const { Source, Index } = require('../../assets/web/markdown-stream.js');
const { Reader } = require('../../assets/web/text-preview.js');
const marked = require('../../assets/web/vendor/marked.umd.js');
const example =
  '# 标题\n\n段落 **强调** [链接][later]\n第二行\n\n标题\n===\n\n- one\n  - nested\n\n  continuation\n- two\n\n> quote\n>\n> paragraph\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```mermaid\nflowchart LR\n A --> B\n```\n\n~~~js\n```\n~~~\n\n\tindented code\n\n<div>literal\n\n[later]: https://example.com\n  "Title"\n\nend';
function streamText(source, step) {
  const stream = new Stream(),
    blocks = [];
  for (let p = 0; p < source.length; p += step) blocks.push(...stream.feed(source.slice(p, p + step), p + step >= source.length).blocks);
  return { stream, blocks };
}
test('complete block ranges match full Marked at every small chunk width', () => {
  const full = new marked.Lexer({ gfm: true })
    .blockTokens(example)
    .filter((t) => !['space', 'def'].includes(t.type))
    .map((t) => ({ type: t.type, raw: t.raw }));
  for (let step = 1; step <= 151; step++) {
    const { stream, blocks } = streamText(example, step);
    assert.deepEqual(
      blocks.map((b) => ({ type: b.type, raw: example.slice(b.start, b.end) })),
      full,
      'chunk ' + step
    );
    assert.equal(stream.links.later.href, 'https://example.com');
    assert.equal(stream.links.later.title, 'Title');
    assert.equal(stream.pending, '');
  }
});
test('reference definitions can cross reads; first definition wins and HTML stays tokenized', () => {
  const { stream } = streamText('[a]: https://example.com\n\n[a]: javascript:bad\n\n', 3);
  const result = tokens('[one][a] <script>bad</script>', stream.links);
  assert.equal(result[0].tokens[0].href, 'https://example.com');
  assert.equal(result[0].tokens[0].type, 'link');
  assert.ok(result[0].tokens.some((t) => t.type === 'html'));
});
test('an incomplete fence is not emitted until its close and following block', () => {
  const s = new Stream();
  assert.deepEqual(s.feed('```md\n# inside\n\n', false).blocks, []);
  assert.deepEqual(s.feed('body\n```\n', false).blocks, []);
  const b = s.feed('\n# outside\n', false).blocks;
  assert.equal(b.length, 1);
  assert.equal(b[0].type, 'code');
  assert.equal(s.feed('', true).blocks[0].type, 'heading');
});
test('large paragraphs remain readable while nested token and standalone reference budgets stay explicit', () => {
  const s = new Stream();
  const windows = [];
  for (let i = 0; i < 5; i++) windows.push(...s.feed('x'.repeat(65536), i === 4).blocks);
  assert.equal(windows.reduce((n,b) => n + b.end - b.start, 0), 5 * 65536);
  assert.ok(windows.every(b => ['paragraph', 'table-header-source'].includes(b.fragment.kind) && b.fragment.literal));
  assert.throws(() => tokens('- a\n'.repeat(8000), {}), /complexity/);
  const refs = new Stream();
  refs.refBytes = 1024 * 1024;
  assert.throws(() => refs.feed('[a]: https://a.test\n', true), /references/);
});
function mockReader(text, encoding = 'utf-8', cacheLimit = 2048) {
  const bytes = encoding === 'utf-16le' ? Buffer.concat([Buffer.from([255, 254]), Buffer.from(text, 'utf16le')]) : Buffer.from(text);
  const ranges = [];
  const fetch = async (_url, opts) => {
    if (opts.method === 'HEAD')
      return new Response(null, { headers: { 'Content-Length': String(bytes.length), 'Accept-Ranges': 'bytes', ETag: '"source"' } });
    const [, start, end] = opts.headers.Range.match(/bytes=(\d+)-(\d+)/).map(Number);
    ranges.push([start, end]);
    assert.equal(opts.headers['If-Match'], '"source"');
    return new Response(bytes.subarray(start, end + 1), {
      status: 206,
      headers: { 'Content-Length': String(end - start + 1), 'Content-Range': `bytes ${start}-${end}/${bytes.length}`, ETag: '"source"' }
    });
  };
  return { reader: new Reader('http://fixture/', bytes.length, { fetch, cacheLimit }), ranges };
}
test('normalized source checkpoints reread CRLF, BOM, surrogate pairs and segmented long lines', async () => {
  for (const encoding of ['utf-8', 'utf-16le']) {
    const original = ('hello 中文🙂\r\n'.repeat(200) + 'long ' + '字🙂'.repeat(25000) + '\r\nend\r\n').repeat(2),
      expected = original.replaceAll('\r\n', '\n');
    const { reader, ranges } = mockReader(original, encoding);
    await reader.init();
    const s = new Source(reader);
    let combined = '';
    while (!s.eof) {
      const c = await s.next();
      assert.ok(c.text.length <= 65536);
      combined += c.text;
    }
    assert.equal(combined, expected);
    for (const [a, b] of [
      [0, 30],
      [65400, 65900],
      [150000, 150400],
      [expected.length - 20, expected.length]
    ])
      assert.equal(await s.read(a, b), expected.slice(a, b));
    assert.ok(reader.cacheBytes < 400000);
    assert.ok(ranges.every(([a, b]) => b - a + 1 <= 65536));
    reader.close();
  }
});
function localWorker() {
  let s = new Stream(),
    r;
  return {
    call: async (m) =>
      m.op === 'feed' ? s.feed(m.text, m.final) : m.op === 'replayStart' ? ((r = new Stream(m.start)), {}) : r.feed(m.text, m.final)
  };
}
test('multi-megabyte section index evicts details and restores exact old ranges', async () => {
  const original = Array.from({ length: 6000 }, (_, i) => `# Title ${i}\n\n${'body long enough '.repeat(16)}${i}\n\n`).join('');
  const { reader } = mockReader(original);
  await reader.init();
  const source = new Source(reader),
    index = new Index(source, localWorker());
  const first = await index.get(0);
  assert.equal(first.length, 100);
  assert.ok(reader.offset < original.length / 10);
  for (let i = 1; !index.done; i++) await index.get(i);
  assert.equal(index.sections.length, 120);
  assert.ok(index.detail.size <= 4);
  assert.ok(source.checkpoints.length < 1000);
  assert.deepEqual(await index.get(0), first);
  assert.ok(index.detail.size <= 4);
  reader.close();
});
