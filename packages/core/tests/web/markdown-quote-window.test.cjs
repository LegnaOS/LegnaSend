'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Stream, tokens, windowLimit, limit } = require('../../assets/web/markdown-blocks.js');
const { Source, Index } = require('../../assets/web/markdown-stream.js');

const KIND = 'quote-child-source';
const words = 'body 中文🙂 &amp; <script> **cross-window** '.repeat(18000);
function collect(source, sizes = [65536], base = 0) {
  const stream = new Stream(base), blocks = [];
  let offset = 0, calls = 0, peak = 0;
  while (offset < source.length) {
    const end = Math.min(source.length, offset + sizes[calls++ % sizes.length]);
    blocks.push(...stream.feed(source.slice(offset, end), end === source.length).blocks);
    peak = Math.max(peak, stream.pending.length);
    offset = end;
  }
  assert.equal(stream.pending, '');
  assert.equal(stream.offset, base + source.length);
  // The parser's general retention contract is limit (256 Ki UTF-16 units), not feed size.
  // These quote fixtures additionally allow one segmented physical row (8192 units)
  // beyond the 64 Ki threshold for quote markers and an incomplete final line.
  assert.ok(peak <= limit, `retained source ${peak} exceeds the parser budget`);
  assert.ok(peak <= 65536 + 8192, `retained quote source ${peak} exceeds bounded marker/partial-line lookahead`);
  return blocks;
}
function windows(blocks) { return blocks.filter(block => block.fragment?.kind === KIND); }
function assertExact(actual, expected) {
  if (actual === expected) return;
  let offset = 0;
  while (offset < Math.min(actual.length, expected.length) && actual[offset] === expected[offset]) offset++;
  assert.fail(`source differs at UTF-16 offset ${offset}; lengths ${actual.length}/${expected.length}; ` +
    `actual ${JSON.stringify(actual.slice(Math.max(0, offset - 40), offset + 80))}; ` +
    `expected ${JSON.stringify(expected.slice(Math.max(0, offset - 40), offset + 80))}`);
}
function sourceText(source, blocks, base = 0) {
  return windows(blocks).map(block => {
    const raw = source.slice(block.start - base, block.end - base);
    assert.ok(raw.length > 0 && raw.length <= windowLimit);
    assert.ok(raw.split('\n').length <= 257);
    const literal = tokens(raw, {}, block.fragment).at(-1).tokens[0];
    assert.equal(literal.type, 'literal');
    assert.equal(literal.text, raw, 'source fragment must not lose markers or decode entities');
    assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(raw), 'window split a surrogate pair');
    return literal.text;
  }).join('');
}
function semanticQuotes(source, blocks) {
  return blocks.filter(block => block.type === 'blockquote' && block.fragment?.kind !== KIND)
    .flatMap(block => tokens(source.slice(block.start, block.end), {}, block.fragment))
    .filter(token => token.type === 'blockquote');
}
function assertHeading(source, blocks) {
  assert.equal(blocks.at(-1).type, 'heading');
  assert.equal(source.slice(blocks.at(-1).start, blocks.at(-1).end), '# after\n');
}

test('oversized quote single physical line stays fully readable at EOF and before a top-level heading', () => {
  for (const suffix of ['', '\n# after\n', '\n\n# after\n']) {
    const body = '> **' + words + '**';
    const source = body + suffix;
    for (const sizes of [[16384], [39173], [65536]]) {
      const blocks = collect(source, sizes);
      assert.ok(windows(blocks).length > 20);
      assertExact(sourceText(source, blocks).trimEnd(), body);
      assert.equal(windows(blocks).filter(block => block.fragment.first).length, 1);
      if (suffix) assertHeading(source, blocks);
    }
  }
});

test('one huge quote paragraph preserves explicit markers and lazy continuation physical lines', () => {
  const body = '> **start\n' + ('> quoted 中文🙂 &amp;\nlazy continuation <img>\n').repeat(18000) + '> end**\n';
  const source = body + '>\n> **normal**\n>\n> another *paragraph*\n\n# after\n';
  for (const sizes of [[39173], [65536, 1, 8191]]) {
    const blocks = collect(source, sizes);
    assertExact(sourceText(source, blocks).trimEnd(), body.trimEnd());
    const paragraphs = semanticQuotes(source, blocks).flatMap(quote => quote.tokens).filter(token => token.type === 'paragraph');
    assert.equal(paragraphs.length, 2);
    assert.equal(paragraphs[0].tokens[0].type, 'strong');
    assert.equal(paragraphs[0].tokens[0].text, 'normal');
    assert.ok(paragraphs[1].tokens.some(token => token.type === 'em' && token.text === 'paragraph'));
    assertHeading(source, blocks);
  }
});

test('ordinary quote paragraphs around a giant child retain their own semantic formatting', () => {
  const body = '> ' + words + '\n';
  const source = '> **before**\n>\n' + body + '>\n> **after**\n\n# after\n';
  const blocks = collect(source, [16384, 32767, 65536]);
  assertExact(sourceText(source, blocks).trimEnd(), body.trimEnd());
  const paragraphs = semanticQuotes(source, blocks).flatMap(quote => quote.tokens).filter(token => token.type === 'paragraph');
  assert.deepEqual(paragraphs.map(token => [token.tokens[0].type, token.tokens[0].text]), [['strong', 'before'], ['strong', 'after']]);
  assertHeading(source, blocks);
});

test('quote fallback survives fragmented threshold, marker, line ending and surrogate boundaries', () => {
  const body = '> ' + 'a'.repeat(16381) + '🙂' + words + '\n';
  const source = body + '>\n> **normal**\n\n# after\n';
  const stream = new Stream(), blocks = [];
  // Cross the large-block threshold by one unit before supplying the next read.
  const breaks = [1, 2, 65536, 65537];
  let start = 0;
  for (const end of breaks) { blocks.push(...stream.feed(source.slice(start, end), false).blocks); start = end; }
  while (start < source.length) {
    const end = Math.min(start + 32767, source.length);
    blocks.push(...stream.feed(source.slice(start, end), end === source.length).blocks);
    assert.ok(stream.pending.length <= 65536);
    start = end;
  }
  assert.equal(stream.pending, '');
  assertExact(sourceText(source, blocks).trimEnd(), body.trimEnd());
  assertHeading(source, blocks);
});

test('literal quote ranges retain exact absolute UTF-16 offsets for source search mapping', () => {
  const body = '> **' + words + 'UNIQUE_TAIL_🙂**';
  const base = 911, blocks = collect(body, [32767], base), fragments = windows(blocks);
  assert.equal(fragments[0].start, base);
  assert.equal(fragments.at(-1).end, base + body.length);
  for (let n = 1; n < fragments.length; n++) assert.equal(fragments[n].start, fragments[n - 1].end);
  assertExact(sourceText(body, blocks, base), body);
  const found = base + body.indexOf('UNIQUE_TAIL_🙂');
  const owner = fragments.find(block => block.start <= found && found < block.end);
  assert.ok(owner);
  assert.equal(body.slice(found - base, found - base + 'UNIQUE_TAIL_🙂'.length), 'UNIQUE_TAIL_🙂');
  assert.ok(owner.replay, 'source lookup must replay the original quote state');
});

test('evicted giant quote sections replay exact mid-child ranges and restore later semantic paragraphs', async () => {
  const source = '> ' + words.repeat(14) + '\n>\n> **after**\n\n# after\n';
  const rows = [];
  source.split('\n').forEach((line, index) => {
    for (let start = 0; start < line.length || start === 0; start += 8192)
      rows.push({ text: line.slice(start, start + 8192), number: index + 1 });
  });
  const reader = { rows: rows.length, eof: true, ensureRows: async () => {}, getRows: async (start, count) => rows.slice(start, start + count) };
  const stream = new Stream();
  let replay;
  const worker = { call: async message => message.op === 'feed' ? stream.feed(message.text, message.final)
    : message.op === 'replayStart' ? (replay = new Stream(message.start, message.context), {}) : replay.feed(message.text, message.final) };
  const index = new Index(new Source(reader), worker);
  const first = await index.get(0), second = await index.get(1);
  for (let number = 2; !index.done; number++) await index.get(number);
  assert.ok(index.sections.length > 5);
  assert.ok(index.detail.size <= 4);
  assert.equal(index.detail.has(0), false);
  assert.deepEqual(await index.get(0), first);
  assert.deepEqual(await index.get(1), second);
  for (const block of second) assert.equal(await index.source.read(block.start, block.end), source.slice(block.start, block.end));
  const last = await index.get(index.sections.length - 1);
  assertHeading(source, last);
  const paragraphs = semanticQuotes(source, last).flatMap(quote => quote.tokens).filter(token => token.type === 'paragraph');
  assert.equal(paragraphs.at(-1).tokens[0].type, 'strong');
  assert.equal(paragraphs.at(-1).tokens[0].text, 'after');
});

test('moderately large quote children preserve semantics rather than entering literal fallback', () => {
  const item = '> **' + 'body '.repeat(5000) + 'end**\n>\n';
  const source = item.repeat(5) + '\n# after\n';
  const blocks = collect(source);
  assert.equal(windows(blocks).length, 0);
  const paragraphs = semanticQuotes(source, blocks).flatMap(quote => quote.tokens).filter(token => token.type === 'paragraph');
  assert.equal(paragraphs.length, 5);
  assert.ok(paragraphs.every(token => token.tokens[0].type === 'strong'));
  assertHeading(source, blocks);
});

test('giant quoted fence keeps internal quote headings literal and restores the following paragraph', () => {
  const body = '> ```md\n' + ('> # fake heading\n>\n> 中文🙂 <img> &amp; literal\n').repeat(18000) + '> ```\n';
  const source = body + '>\n> **normal after fence**\n\n# after\n';
  for (const sizes of [[65536], [32767, 1, 16384]]) {
    const blocks = collect(source, sizes);
    assertExact(sourceText(source, blocks).trimEnd(), body.trimEnd());
    assert.equal(blocks.filter(block => block.type === 'heading').length, 1);
    const paragraphs = semanticQuotes(source, blocks).flatMap(quote => quote.tokens).filter(token => token.type === 'paragraph');
    assert.equal(paragraphs.length, 1);
    assert.equal(paragraphs[0].tokens[0].type, 'strong');
    assert.equal(paragraphs[0].tokens[0].text, 'normal after fence');
    assertHeading(source, blocks);
  }
});
