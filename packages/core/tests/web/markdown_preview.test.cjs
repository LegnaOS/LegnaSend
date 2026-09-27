const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { domFixture } = require('./dom_fixture.cjs');
const marked = require('../../assets/web/vendor/marked.umd.js');
const { render, safeUrl } = require('../../assets/web/markdown-preview.js');
function documentFor(source) {
  const f = domFixture(); f.document.body.appendChild(render(marked.lexer(source, { gfm: true }), f.document)); return f;
}
test('Markdown renders headings, emphasis, lists, task lists, tables, quotes, code and approved links', () => {
  const f = documentFor('# 标题\n\n**bold** *em* ~~del~~ `code`\n\n> 引用\n\n- [x] 完成\n- [ ] 待办\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n```js\nconst a = "<script>";\n```\n\n[官网](https://example.com)');
  for (const tag of ['h1','strong','em','del','code','blockquote','ul','li','input','table','thead','tbody','th','td','pre','a']) assert.ok(f.descendants().some(n => n.tag === tag), tag);
  assert.equal(f.descendants().find(n => n.tag === 'a').rel, 'noopener noreferrer');
  assert.ok(f.descendants().filter(n => n.tag === 'input').every(n => n.disabled));
  assert.equal(f.descendants().filter(n => n.tag === 'input').length, 2);
  assert.equal(f.document.body.textContent.includes('[x]'), false);
});
test('HTML, event handlers, active URLs and images do not create active content or automatic requests', () => {
  const f = documentFor('<script>window.pwned=1</script>\n\n<img src=x onerror=alert(1)>\n\n[bad](javascript:alert(1)) ![pixel](https://example.com/tracker) [data](data:text/html,hello)');
  assert.equal(f.descendants().filter(n => ['script','img','iframe','svg','a'].includes(n.tag)).length, 0);
  assert.ok(f.document.body.textContent.includes('<script>'));
  for (const url of ['javascript:alert(1)', 'java&#x73;cript:alert(1)', 'file:///tmp/x', '//host/path', '/api/localsend/v2/cancel', 'https:\n//host']) assert.equal(safeUrl(url), null);
  assert.equal(safeUrl('https://example.com/?a=1&amp;b=2'), 'https://example.com/?a=1&b=2');
});
test('DOM construction has a hard node budget, including large Markdown tables/lists', () => {
  const f = domFixture(); assert.throws(() => render(Array.from({ length: 6001 }, () => ({ type: 'text', text: 'row' })), f.document), /limit/);
});
test('worker uses the bundled parser and rejects oversized source/token graphs', () => {
  let result;
  const worker = { self: { postMessage: message => result = message }, importScripts(url) { assert.equal(url, '/assets/vendor/marked.umd.js'); }, marked };
  vm.createContext(worker); vm.runInContext(fs.readFileSync(require.resolve('../../assets/web/markdown-worker.js'), 'utf8'), worker);
  worker.self.onmessage({ data: '# 目标\n\n**正文**' }); assert.equal(result.tokens[0].type, 'heading');
  worker.self.onmessage({ data: 'x'.repeat(256 * 1024 + 1) }); assert.equal(result.error, 'format');
  worker.self.onmessage({ data: '- item\n'.repeat(5000) }); assert.equal(result.error, 'format');
});

test('vendored parser remains pinned to the verified offline artifact', () => {
  const crypto = require('node:crypto');
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(require.resolve('../../assets/web/vendor/marked.umd.js'))).digest('hex'), 'b147274a9ce27d17276587167e49483d719f6893eeca3a3667a59797661d3556');
});

test('reference definitions do not appear as literal body content', () => {
  const f = documentFor('[visible][ref]\n\n[ref]: https://example.com\n');
  assert.ok(f.descendants().some(n => n.tag === 'a' && n.href === 'https://example.com/'));
  assert.equal(f.document.body.textContent.includes('[ref]:'), false);
});

test('missing Worker retains the original rejected-ready fallback for large documents', async () => {
  const api = require('../../assets/web/markdown-preview.js'), previous = global.LegnaMarkdownStream;
  global.LegnaMarkdownStream = { mount() { throw Error('unexpected dispatch'); } };
  try {
    const view = api.mount({ reader: { size: 1024 * 1024 }, container: {} });
    await assert.rejects(view.ready, /limit/); view.close();
  } finally { if (previous === undefined) delete global.LegnaMarkdownStream; else global.LegnaMarkdownStream = previous; }
});
