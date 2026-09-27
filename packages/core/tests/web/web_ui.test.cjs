const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { domFixture } = require('./dom_fixture.cjs');
const { buildIndex, filterIndex } = require('../../assets/web/web-ui.js');

function fixture() {
  const dom = domFixture(), listeners = new Map();
  const sandbox = { document: dom.document, AbortController, setTimeout, clearTimeout, location: { protocol: 'http:' }, navigator: { language: 'zh-CN' },
    requestAnimationFrame: fn => setTimeout(fn, 0), addEventListener: (name, fn) => listeners.set(name, fn), removeEventListener: name => listeners.delete(name),
    localStorage: { getItem: () => null, setItem() {} } };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../assets/web/web-ui.js'), 'utf8'), sandbox);
  return { ...dom, api: sandbox.LegnaWebUI, sandbox, listeners };
}
const kind = mime => mime === 'image/png' ? 'img' : mime === 'text/plain' ? 'text' : null;

async function until(fn) {
  // Same bounded readiness budget as the other DOM contract tests. The query
  // debounce and cooperative index yields must finish, not merely 150 ms elapse.
  for (let i = 0; i < 150; i++) {
    if (fn()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.fail('Latest file query did not finish rendering');
}


test('10,000 files are indexed and filtered in interruptible batches with exact identities', async () => {
  const files = Object.fromEntries(Array.from({ length: 10000 }, (_, i) => [String(i), { fileName: `File ${i}.txt`, size: i, fileType: 'text/plain' }]));
  let yields = 0;
  const index = await buildIndex(files, kind, () => { yields++; return true; });
  assert.equal(index.entries.length, 10000); assert.ok(yields >= 10);
  const matches = await filterIndex(index.entries, 'FILE 9999', 'text', () => true);
  assert.deepEqual(matches, [9999]); assert.equal(index.entries[matches[0]].id, '9999');
  assert.equal(await filterIndex(index.entries, '', 'all', () => false), null);
  assert.equal(await buildIndex(files, kind, () => false), null);
});

test('virtual file list keeps a bounded DOM, safely renders names and preserves focused rows', async () => {
  const f = fixture(), container = f.element('div'); f.document.body.appendChild(container);
  const files = Object.fromEntries(Array.from({ length: 10000 }, (_, i) => [String(i), { fileName: `File ${i}.txt`, size: i, fileType: 'text/plain' }]));
  files['0'].fileName = '<img src=x onerror=alert(1)>.txt';
  const selected = [];
  const list = f.api.mountFiles({ container, files, previewKind: kind, downloadUrl: id => '/download?fileId=' + encodeURIComponent(id), onPreview: (id, button) => selected.push([id, button]) });
  await list.ready;
  let rows = f.document.querySelectorAll('.file-row'); assert.ok(rows.length <= 18); assert.equal(rows[0].children[1].children[0].textContent, files['0'].fileName);
  assert.equal(f.descendants().filter(n => n.tag === 'img').length, 0);
  const viewport = f.document.querySelectorAll('.file-viewport')[0], rowContainer = f.document.querySelectorAll('.file-rows')[0];
  const preview = rows[0].children[2].children[0]; preview.focus();
  rowContainer.onclick({ target: preview.children[0].children[0] }); assert.equal(selected[0][0], '0');
  viewport.scrollTop = 9000 * 56; viewport.onscroll(); await new Promise(r => setTimeout(r, 10));
  rows = f.document.querySelectorAll('.file-row'); assert.ok(rows.length <= 19); assert.ok(rows.some(n => n.contains(preview)));
  assert.ok(rows.some(n => n.children[1].children[0].textContent === 'File 9000.txt'));
  list.close(); assert.equal(f.document.querySelectorAll('.file-row').length, 0); assert.equal(f.listeners.size, 0);
});

test('rapid query changes never allow stale filtering to replace the latest result', async () => {
  const f = fixture(), container = f.element('div'); f.document.body.appendChild(container);
  const files = Object.fromEntries(Array.from({ length: 10000 }, (_, i) => [String(i), { fileName: `Item ${i}`, size: 1, fileType: 'text/plain' }]));
  const list = f.api.mountFiles({ container, files, previewKind: kind, downloadUrl: id => '/' + id, onPreview() {} }); await list.ready;
  const input = f.descendants().find(n => n.type === 'search');
  input.value = 'Item 9'; input.oninput(); input.value = 'Item 9999'; input.oninput();
  try {
    await until(() => container.getAttribute('aria-busy') === 'false' && f.document.querySelectorAll('.file-row').length === 1);
    const rows = f.document.querySelectorAll('.file-row'); assert.equal(rows.length, 1); assert.equal(rows[0].children[1].children[0].textContent, 'Item 9999');
  } finally { list.close(); }
});

test('PIN modal retries inline, prevents duplicate submissions and restores focus after success', async () => {
  const f = fixture(), main = f.element('main'), trigger = f.element('button'); main.className = 'web-shell'; main.appendChild(trigger); f.document.body.appendChild(main); trigger.focus();
  let calls = 0, completed = 0, release;
  f.api.pin({ verify: () => { calls++; return new Promise(resolve => release = resolve); }, onSuccess: () => completed++ });
  const form = f.document.querySelectorAll('form')[0], input = f.document.getElementById('sharing-pin'); input.value = '111111';
  const first = form.onsubmit({ preventDefault() {} }); await form.onsubmit({ preventDefault() {} }); assert.equal(calls, 1); assert.equal(input.disabled, true); assert.equal(main.inert, true);
  release({ ok: false, error: 'PIN incorrect' }); await first;
  assert.equal(f.document.getElementById('pin-error').textContent, 'PIN incorrect'); assert.equal(input.disabled, false);
  input.value = '123456'; const second = form.onsubmit({ preventDefault() {} }); release({ ok: true }); await second;
  assert.equal(completed, 1); assert.equal(input.value, ''); assert.equal(main.inert, false); assert.equal(f.document.activeElement, trigger); assert.equal(f.document.querySelectorAll('form').length, 0);
});

test('PIN cancellation aborts verification and ignores late success', async () => {
  const f = fixture(); let signal, release, accepted = 0, canceled = 0;
  f.api.pin({ verify: (_, value) => { signal = value; return new Promise(resolve => release = resolve); }, onSuccess: () => accepted++, onCancel: () => canceled++ });
  const form = f.document.querySelectorAll('form')[0]; f.document.getElementById('sharing-pin').value = '123456';
  const pending = form.onsubmit({ preventDefault() {} }); form.onkeydown({ key: 'Escape', preventDefault() {} }); assert.equal(signal.aborted, true);
  release({ ok: true }); await pending; assert.equal(accepted, 0); assert.equal(canceled, 1);
});

test('offline language bundles cover upload, PIN, media and text controls with no native dialogs', () => {
  const f = fixture(); f.sandbox.window = f.sandbox;
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../assets/web/web-i18n.js'), 'utf8'), f.sandbox);
  const localized = f.api.localize({}); assert.equal(localized.webUi.selectFiles, '选择文件'); assert.equal(localized.webUi.pinTitle, '输入共享 PIN'); assert.equal(localized.textPreview.encoding, '编码');
  for (const name of ['download.html', 'upload.html', 'web-ui.js', 'web-upload.js']) {
    const source = fs.readFileSync(path.join(__dirname, '../../assets/web', name), 'utf8'); assert.doesNotMatch(source, /\b(?:prompt|alert|confirm)\s*\(/);
  }
  for (const locale of ['en', 'zh-CN', 'zh-TW', 'zh-HK']) assert.deepEqual(Object.keys(f.sandbox.LegnaWebLocales[locale].webUi).sort(), Object.keys(f.api.defaults).sort());
});

test('language changes translate existing status text and retain list query/type/position', async () => {
  const f = fixture(), node = f.element('p'); node.textContent = '请求失败 (503)';
  f.api.translateStatus(node, { error: '请求失败' }, { error: 'Request failed' }); assert.equal(node.textContent, 'Request failed (503)');
  const container = f.element('div'); f.document.body.appendChild(container);
  const files = { a: { fileName: 'first.txt', size: 1, fileType: 'text/plain' }, b: { fileName: 'second.txt', size: 1, fileType: 'text/plain' } };
  const list = f.api.mountFiles({ container, files, previewKind: kind, downloadUrl: id => '/' + id, onPreview() {}, state: { query: 'second', type: 'text', page: 0, scrollTop: 0 } });
  await list.ready;
  assert.equal(f.document.querySelectorAll('.file-row').length, 1);
  assert.equal(f.document.querySelectorAll('.file-name')[0].textContent, 'second.txt');
  assert.equal(list.state().query, 'second'); list.close();
});

test('managed download clicks are delegated without breaking modified ordinary links', async () => {
  const f = fixture(), container = f.element('div'), calls = []; f.document.body.appendChild(container);
  const list = f.api.mountFiles({ container, files: { a: { fileName: 'one.txt', fileType: 'text/plain', size: 1 } }, previewKind: kind,
    downloadUrl: id => '/download?fileId=' + id, onPreview() {}, onDownload: id => calls.push(id) }); await list.ready;
  const link = f.document.querySelectorAll('.file-main')[0], rows = f.document.querySelectorAll('.file-rows')[0]; let prevented = 0;
  rows.onclick({ target: link, preventDefault() { prevented++; } }); assert.deepEqual(calls, ['a']); assert.equal(prevented, 1);
  rows.onclick({ target: link, ctrlKey: true, preventDefault() { prevented++; } }); assert.equal(calls.length, 1); assert.equal(prevented, 1);
  assert.equal(link.href, '/download?fileId=a'); list.close();
});

test('batch selection spans virtual rows, filters and remounts with one ordinary download action', async () => {
  const f=fixture(), container=f.element('div');f.document.body.appendChild(container);
  const files=Object.fromEntries(Array.from({length:5000},(_,i)=>[String(i),{fileName:`folder/${i}.txt`,size:4,fileType:'text/plain'}]));
  const batches=[];const params={container,files,previewKind:kind,downloadUrl:id=>'/'+id,onPreview(){},onDownload(){return false;},onBatch:ids=>batches.push(ids)};
  let list=f.api.mountFiles(params);await list.ready;
  const labels=f.api.defaults;const buttons=()=>f.descendants().filter(n=>n.tag==='button');
  const select=buttons().find(n=>n.textContent===labels.selectVisible);select.onclick();
  assert.equal(list.state().selected.length,5000);assert.ok(f.document.querySelectorAll('.file-select').length<=18);
  buttons().find(n=>n.textContent.startsWith(labels.downloadSelected)).onclick();assert.equal(batches[0].length,5000);
  const rows=f.document.querySelectorAll('.file-rows')[0];const link=f.descendants().find(n=>n.dataset.downloadId==='0');let prevented=false;
  rows.onclick({target:link,preventDefault(){prevented=true;}});assert.equal(prevented,false);
  const state=list.state();list.close();delete files['4999'];list=f.api.mountFiles({...params,state});await list.ready;
  assert.equal(list.state().selected.length,4999);assert.equal(f.document.querySelectorAll('.managed-download').length,0);
  buttons().find(n=>n.textContent===labels.clearSelection).onclick();assert.equal(list.state().selected.length,0);
  buttons().find(n=>n.textContent===labels.downloadAll).onclick();assert.equal(batches.at(-1),null);
  list.close();
});
