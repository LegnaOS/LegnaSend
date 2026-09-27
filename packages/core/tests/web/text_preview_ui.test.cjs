const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function uiFixture(input, injectFetch = false, compact = false) {
  const data = Buffer.from(input), requests = [], handlers = new Map();
  const { document, element } = require('./dom_fixture.cjs').domFixture();
  const sandbox = { TextDecoder, AbortController, ReadableStream, Response, setTimeout, clearTimeout,
    document,
    requestAnimationFrame: fn => setTimeout(fn, 0),
    addEventListener: (name, fn) => handlers.set(name, fn), removeEventListener: name => handlers.delete(name),
    fetch: async (_, options) => {
      requests.push(options);
      if (options.method === 'HEAD') return new Response(null, { headers: { 'Content-Length': String(data.length), 'Accept-Ranges': 'bytes', ETag: '"test"' } });
      const [, a, b] = options.headers.Range.match(/bytes=(\d+)-(\d+)/), start = Number(a), end = Number(b);
      return new Response(data.subarray(start, end + 1), { status: 206, headers: { 'Content-Length': String(end - start + 1), 'Content-Range': `bytes ${start}-${end}/${data.length}`, ETag: '"test"' } });
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../assets/web/text-search.js'), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../assets/web/text-preview.js'), 'utf8'), sandbox);
  const container = element('div'), status = element('p');
  container.clientHeight = 360;
  const originalFetch = sandbox.fetch, injected = [];
  const fetch = injectFetch ? async (url, options) => { injected.push(options.method); return originalFetch(url, options); } : undefined;
  if (injectFetch) sandbox.fetch = () => { throw new Error('Reader bypassed its supplied fetch'); };
  const mounted = sandbox.LegnaTextPreview.mount({ container, status, url: '/download', size: data.length, fetch, compact });
  container.children[4].clientHeight = 360;
  return { sandbox, container, status, requests, handlers, mounted, injected };
}
async function until(fn) {
  for (let i = 0; i < 150; i++) { if (fn()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
  assert.fail('UI did not reach the expected state');
}

test('virtual viewport bounds DOM rows and reads only the visible section', async () => {
  const f = uiFixture('<script>alert(1)</script>\n' + 'Line content 碧绿\n'.repeat(200000));
  const viewport = f.container.children[4], rows = viewport.children[0].children[0], toolbar = f.container.children[0];
  await until(() => rows.children.length > 0);
  assert.ok(rows.children.length <= 31);
  assert.equal(rows.children[0].children[1].textContent, '<script>alert(1)</script>');
  assert.equal(rows.children[0].children[1].tag, 'span');
  assert.equal(f.requests.length, 2);
  viewport.scrollTop = 500 * 28; viewport.onscroll();
  await until(() => rows.children[0].children[0].textContent === '495');
  assert.ok(rows.children.length <= 31); assert.equal(f.requests.length, 2);
  toolbar.children[2].onclick(); // Next section, without indexing the entire file.
  await until(() => rows.children[0].children[0].textContent === '1001');
  assert.ok(rows.children.length <= 31);
  toolbar.children[1].onclick();
  await until(() => rows.children[0].children[0].textContent === '1');
  f.mounted.close(); assert.equal(f.handlers.size, 0); assert.equal(viewport.onscroll, null);
});

test('encoding changes replace the reader and page section; close rejects late rendering', async () => {
  const f = uiFixture('碧绿\n'.repeat(50000));
  const viewport = f.container.children[4], rows = viewport.children[0].children[0], select = f.container.children[0].children[0].children[0];
  await until(() => rows.children.length > 0);
  viewport.scrollTop = 8000; viewport.onscroll();
  select.value = 'utf-8'; select.onchange();
  await until(() => f.requests.length >= 4 && rows.children.length > 0);
  assert.equal(rows.children[0].children[0].textContent, '1');
  assert.equal(viewport.scrollTop, 0);
  viewport.scrollTop = 500; viewport.onscroll(); f.mounted.close();
  const before = rows.children;
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(rows.children, before);
});

test('preview content search highlights literal text, navigates matches and retains wrapping toggle', async () => {
  const f = uiFixture('intro\n' + 'ordinary\n'.repeat(1500) + '**目标**\n尾部目标');
  const viewport = f.container.children[4], rows = viewport.children[0].children[0], toolbar = f.container.children[0];
  await until(() => rows.children.length > 0);
  const searchBar = f.container.children[1], query = searchBar.children[0], find = searchBar.children[3];
  query.value = '目标'; await find.onclick();
  await until(() => rows.children.some(n => n.children[1].children.some(c => c.tag === 'mark')));
  assert.match(f.container.children[2].textContent, /Matches: 1 \/ 2/);
  assert.ok(rows.children.some(n => n.children[0].textContent === '1502'));
  assert.equal(viewport.className, 'text-viewport');
  const wrap = toolbar.children[5].children[0]; wrap.checked = false; wrap.onchange();
  assert.match(viewport.className, /text-nowrap/);
  searchBar.children[6].onclick(); await until(() => /Matches: 2 \/ 2/.test(f.container.children[2].textContent));
  searchBar.children[7].onclick(); assert.equal(query.value, ''); assert.equal(f.container.children[2].textContent, '');
  f.mounted.close();
});


test('mounted reader retains the injected authorization fetch for HEAD and ranges', async () => {
  const f = uiFixture('authorized text\n'.repeat(5000), true);
  await until(() => f.container.children[4].children[0].children[0].children.length > 0 && f.status.textContent === '');
  assert.ok(f.injected.includes('HEAD'));
  assert.ok(f.injected.includes('GET'));
  assert.equal(f.status.textContent, '');
  f.mounted.close();
});


test('compact reader caps empty space after a short complete document', async () => {
  const f = uiFixture('one\ntwo\n', false, true);
  try {
    // First rows can render before Reader.init finishes its cooperative yield.
    // Wait for completed initialization/layout, not just the first visible row.
    await until(() => f.container.children[4].children[0].children[0].children.length > 0 &&
      f.status.textContent === '' && /End of file/.test(f.container.children[3].textContent));
    assert.equal(f.container.children[4].style.maxHeight, '160px');
  } finally { f.mounted.close(); }
});

test('explicit logical-line input indexes unseen rows, preserves wrapping and leaves search usable', async () => {
  const f = uiFixture('first\n' + 'plain 中文🙂\n'.repeat(90000) + 'last');
  const toolbar=f.container.children[0], jump=toolbar.children[8], input=jump.children[0].children[0];
  const viewport=f.container.children[4], rows=viewport.children[0].children[0];
  await until(()=>rows.children.length>0);
  input.value='75000';await jump.children[1].onclick();
  await until(()=>rows.children.some(n=>n.getAttribute('data-line-target')==='75000'));
  assert.equal(f.container.dataset.textSeekState,'found');assert.match(jump.children[3].textContent,/Showing line 75,000/);
  assert.ok(rows.children.length<=31);assert.equal(viewport.className,'text-viewport');
  const before=f.requests.length;input.value='1e6';await jump.children[1].onclick();assert.equal(f.requests.length,before);
  assert.match(jump.children[3].textContent,/whole line number/);
  const bar=f.container.children[1];bar.children[0].value='first';await bar.children[3].onclick();
  await until(()=>rows.children.some(n=>n.children[1].children.some(c=>c.tag==='mark')));
  assert.ok(rows.children.some(n=>n.children[0].textContent==='1'));f.mounted.close();
});
