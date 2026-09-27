const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Stream, tokens, windowLimit } = require('../../assets/web/markdown-blocks.js');
const { render } = require('../../assets/web/markdown-preview.js');
const { domFixture } = require('./dom_fixture.cjs');
const { Source, Index } = require('../../assets/web/markdown-stream.js');
function collect(source, step = 65536) {
  const stream = new Stream(), blocks = [];
  let retained = 0;
  for (let p = 0; p < source.length; p += step) {
    blocks.push(...stream.feed(source.slice(p, p + step), p + step >= source.length).blocks);
    retained = Math.max(retained, stream.pending.length);
  }
  assert.equal(stream.pending, '');
  return { stream, blocks, retained };
}
test('multi-megabyte fence keeps exact source text in bounded code windows and closes at the real marker', () => {
  const body = ('``` too short\n' + '<img src=x onerror=alert(1)> 中文🙂\n').repeat(40000);
  for (const step of [16384, 65536, 39173]) {
    const source = '````javascript\n' + body + '`````\n# after\n';
    const { blocks, retained } = collect(source, step);
    const fragments = blocks.filter(b => b.fragment);
    assert.ok(fragments.length > 100);
    assert.ok(retained <= 65536);
    assert.ok(fragments.every(b => b.end - b.start <= windowLimit + 4096));
    assert.equal(fragments.map(b => tokens(source.slice(b.start, b.end), {}, b.fragment)[0].text).join(''), body);
    assert.equal(blocks.at(-1).type, 'heading');
    assert.equal(source.slice(blocks.at(-1).start), '# after\n');
  }
});
test('one enormous physical code line handles surrogate pairs and fake mid-line fences', () => {
  const body = 'a🙂'.repeat(200000) + '```\nnot a closing marker\n';
  const source = '```\n' + body;
  const { blocks } = collect(source);
  assert.equal(blocks.map(b => tokens(source.slice(b.start, b.end), {}, b.fragment)[0].text).join(''), body);
  for (const b of blocks) {
    const text = tokens(source.slice(b.start, b.end), {}, b.fragment)[0].text;
    assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(text));
  }
});
test('fence indentation is removed only at physical line starts; diagram windows never execute partial diagrams', () => {
  const body = ('  data\n x\n    nested\n').repeat(30000);
  const source = '  ~~~mermaid\n' + body + '  ~~~\n';
  const { blocks } = collect(source);
  assert.equal(blocks.map(b => tokens(source.slice(b.start, b.end), {}, b.fragment)[0].text).join(''), body.replace(/^ {0,2}/gm, ''));
  const fixture = domFixture();
  const first = blocks[0];
  fixture.document.body.appendChild(render(tokens(source.slice(first.start, first.end), {}, first.fragment), fixture.document));
  assert.equal(fixture.descendants().filter(n => n.tag === 'pre').length, 1);
  assert.equal(fixture.descendants().filter(n => ['script', 'img', 'iframe'].includes(n.tag)).length, 0);
});
test('huge GFM table renders all rows, alignment, inline emphasis and references in bounded row windows', () => {
  const header = '| Key | Value |\n|:---|---:|\n';
  const body = Array.from({length: 30000}, (_, i) => `| **${i}** | [value][later] |\n`).join('');
  const source = header + body + '\n# after\n';
  const { blocks, retained } = collect(source);
  const fragments = blocks.filter(b => b.fragment);
  const rendered = fragments.map(b => tokens(source.slice(b.start, b.end), {later: {href:'https://example.com'}}, b.fragment)[0]);
  assert.equal(rendered.reduce((n,t) => n + t.rows.length, 0), 30000);
  assert.ok(rendered.every(t => t.rows.length <= 16));
  assert.ok(rendered.every(t => t.align.join(',') === 'left,right'));
  assert.equal(rendered[0].rows[0][0].tokens[0].type, 'strong');
  assert.equal(rendered.at(-1).rows.at(-1)[1].tokens[0].href, 'https://example.com');
  assert.ok(retained <= 65536);
  assert.equal(blocks.at(-1).type, 'heading');
});
test('evicted sections replay from in-fence and in-table context without changing offsets', async () => {
  for (const source of [
    '```txt\n' + 'huge 中文🙂 row\n'.repeat(700000) + '```\n# done\n',
    '| A | B |\n|---|---|\n' + '| one | two |\n'.repeat(15000) + '\n# done\n'
  ]) {
    // Real Source checkpoints over segmented rows, without retaining rendered DOM.
    const rows = source.split('\n').map((text, i) => ({text, number:i + 1}));
    const reader = { rows:rows.length, eof:true, ensureRows:async()=>{}, getRows:async(start,count)=>rows.slice(start,start+count) };
    let stream = new Stream(), replay;
    const worker = {call: async m => m.op === 'feed' ? stream.feed(m.text,m.final)
      : m.op === 'replayStart' ? (replay = new Stream(m.start,m.context), {}) : replay.feed(m.text,m.final)};
    const index = new Index(new Source(reader),worker);
    const first = await index.get(0);
    for (let i=1; !index.done; i++) await index.get(i);
    assert.ok(index.sections.length > 5);
    assert.ok(index.detail.size <= 4);
    assert.deepEqual(await index.get(0), first);
    const expected = index.detail.get(index.sections.length-2);
    const reread = await index.get(1);
    assert.ok(reread[0].replay);
    assert.ok(reread.every(b=>b.fragment));
    assert.ok(!expected || expected.length > 0);
  }
});
test('unbounded inline syntax and giant table cells remain complete in literal windows', () => {
  const source = '**' + 'x'.repeat(300000) + '**';
  const {blocks} = collect(source);
  assert.equal(blocks.map(b => tokens(source.slice(b.start,b.end),{},b.fragment)[0].tokens[0].text).join(''),source);
  const table='| A | B |\n|---|---|\n| ' + 'x'.repeat(300000) + ' | y |\n';
  const rows=collect(table).blocks;
  assert.ok(rows.every(b=>b.fragment.kind==='table-row-source'));
  assert.equal(rows.map(b=>table.slice(b.start,b.end)).join(''),table);
});
