'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Stream, tokens, windowLimit, limit } = require('../../assets/web/markdown-blocks.js');
const { Source, Index } = require('../../assets/web/markdown-stream.js');
const marked = require('../../assets/web/vendor/marked.umd.js');

function collect(source, step = 65536) {
  const stream = new Stream(), blocks = [];
  let peak = 0;
  for (let offset = 0; offset < source.length; offset += step) {
    blocks.push(...stream.feed(source.slice(offset, offset + step), offset + step >= source.length).blocks);
    peak = Math.max(peak, stream.pending.length);
  }
  assert.equal(stream.pending, '');
  assert.equal(stream.offset, source.length);
  assert.ok(peak <= limit, `parser pending ${peak}`);
  return blocks;
}
function treeTokens(source, blocks) {
  return blocks.flatMap(block => tokens(source.slice(block.start, block.end), {}, block.fragment));
}
function headings(parsed) {
  const found = [];
  function visit(token) {
    if (token.type === 'heading') found.push(token.text);
    [...(token.tokens || []), ...(token.items || [])].forEach(visit);
  }
  parsed.forEach(visit);
  return found;
}
function assertCoverage(source, blocks) {
  let end = 0, literalUnits = 0;
  for (const block of blocks) {
    assert.ok(block.start >= end && block.end > block.start && block.end <= source.length);
    assert.equal(source.slice(end, block.start).trim(), '', 'only whitespace may fall between indexed blocks');
    end = block.end;
    if (!block.fragment?.literal) continue;
    const raw = source.slice(block.start, block.end);
    assert.ok(raw.length <= windowLimit, `oversized literal window ${raw.length}`);
    assert.ok(raw.split('\n').length <= 257, 'source-window physical height must stay bounded');
    assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(raw), 'split surrogate');
    const literal = tokens(raw, {}, block.fragment).at(-1).tokens[0];
    assert.equal(literal.type, 'literal');
    assert.ok(literal.text === raw, 'source window must preserve every literal UTF-16 unit');
    literalUnits += raw.length;
  }
  assert.equal(source.slice(end).trim(), '');
  assert.ok(literalUnits > 65536, 'the oversized source must actually remain available through windows');
}
const huge = 'word 中文🙂 &amp; '.repeat(20000);

test('a false huge table-header candidate never consumes a following heading, list or fence opener', () => {
  const first = '| ' + huge + '\n';
  for (const tail of ['# unrelated\n\nordinary **after**\n', '- **unrelated item**\n\n# after\n', '```js\nconst marker=1;\n```\n\n# after\n']) {
    const source = first + tail;
    const expected = new marked.Lexer({ gfm: true }).blockTokens(source).filter(token => token.type !== 'space').slice(1);
    for (const step of [16383, 39173, 65536]) {
      const blocks = collect(source, step);
      assertCoverage(source, blocks);
      const following = blocks.filter(block => block.start >= first.length);
      assert.deepEqual(following.map(block => ({ type: block.type, raw: source.slice(block.start, block.end) })),
        expected.map(token => ({ type: token.type, raw: token.raw })));
      assert.deepEqual(headings(treeTokens(source, blocks)), headings(expected));
      if (tail.startsWith('```')) {
        const code = treeTokens(source, following).find(token => token.type === 'code');
        assert.equal(code.text, 'const marker=1;');
      }
      if (tail.startsWith('-')) assert.equal(treeTokens(source, following)[0].items[0].tokens[0].tokens[0].type, 'strong');
    }
  }
});

function nestedFence(kind, count) {
  return kind === 'quote'
    ? '> > ```md\n' + ('> > # fake\n> >\n> > literal 中文🙂 **text**\n').repeat(count) + '> > ```\n>\n> **after**\n'
    : '> - ```md\n' + ('>   # fake\n>\n>   literal 中文🙂 **text**\n').repeat(count) + '>   ```\n>\n> **after**\n';
}
for (const kind of ['quote', 'list']) {
  test(`a giant fence inside a quoted ${kind} never creates fake headings or oversized semantic blocks`, () => {
    const body = nestedFence(kind, 15000), source = body + '\n# end\n';
    const expected = headings(new marked.Lexer({ gfm: true }).blockTokens(source));
    assert.deepEqual(expected, ['end']);
    for (const step of [39173, 65536]) {
      const blocks = collect(source, step);
      assertCoverage(source, blocks);
      // Rendering every indexed block must succeed, not silently catch complexity
      // and replace a 5000-line semantic block with an unbounded preformatted node.
      assert.deepEqual(headings(treeTokens(source, blocks)), expected);
      const quoted = blocks.filter(block => block.type === 'blockquote');
      assert.ok(quoted.every(block => block.fragment?.literal), 'unsupported giant nested child stays explicitly in source mode');
      const raw = quoted.map(block => source.slice(block.start, block.end)).join('');
      assert.ok(raw.trimEnd() === body.trimEnd(), 'nested-container source must not be truncated');
      assert.equal(blocks.at(-1).type, 'heading');
    }
  });
}

test('a preceding heading does not stall an unfinished giant physical line or change later block boundaries', () => {
  for (const opening of ['', '> ', '| ']) {
    const source = '# before\n\n' + opening + huge + '\n\n# after\n';
    for (const step of [16384, 39173, 65536]) {
      const blocks = collect(source, step);
      assertCoverage(source, blocks);
      assert.equal(blocks[0].type, 'heading');
      assert.equal(blocks.at(-1).type, 'heading');
      assert.deepEqual(headings(treeTokens(source, blocks)), ['before', 'after']);
    }
  }
});

test('nested quote-source state and provisional header state replay exactly after section eviction', async () => {
  for (const source of [nestedFence('quote', 60000) + '\n# end\n', '| ' + huge.repeat(35) + '\n```js\nvalue();\n```\n\n# end\n']) {
    const rows = [];
    source.split('\n').forEach((text, index) => {
      for (let start = 0; start < text.length || start === 0; start += 8192)
        rows.push({ text: text.slice(start, start + 8192), number: index + 1 });
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
    assert.ok(index.sections.every(section => JSON.stringify(section.context).length < 16384));
    for (const block of second) assert.ok(await index.source.read(block.start, block.end) === source.slice(block.start, block.end));
    const last = await index.get(index.sections.length - 1);
    assert.deepEqual(headings(treeTokens(source, last)), ['end']);
  }
});


test('a surrogate pair split exactly at an input and source-window boundary stays in one rendered fragment', () => {
  for (const opening of ['> ', '| ', '']) {
    const parts = [opening + 'x'.repeat(65536 - opening.length), 'x'.repeat(16383) + '\ud83d', '\ude42\n\n# end\n'];
    const source = parts.join(''), stream = new Stream(), blocks = [];
    parts.forEach((part, index) => blocks.push(...stream.feed(part, index === parts.length - 1).blocks));
    assert.equal(stream.pending, '');
    assertCoverage(source, blocks);
    for (const block of blocks) {
      const raw = source.slice(block.start, block.end);
      assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(raw), 'rendered fragment bisected a split-input surrogate pair');
    }
    assert.equal(blocks.at(-1).type, 'heading');
  }
});
