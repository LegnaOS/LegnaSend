const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { domFixture } = require('./dom_fixture.cjs');
const en = require('../../assets/web/i18n/en.json'), zh = require('../../assets/web/i18n/zh-CN.json');
const source = fs.readFileSync(path.join(__dirname, '../../assets/web/download-ui.js'), 'utf8');
function fixture() {
  const dom = domFixture(), handles = [], created = [], revoked = [], downloads = [];
  const create = dom.document.createElement;
  dom.document.createElement = tag => { const node = create(tag); node.scrollIntoView = () => {}; node.click = () => downloads.push({ href: node.href, download: node.download }); return node; };
  dom.document.createTextNode = text => { const node = create('#text'); node.textContent = text; return node; };
  class FakeManager {
    constructor({ onChange }) { this.tasks = []; this.emit = () => onChange(this.tasks); handles.push(this); }
    add(source, sink) { const task = { ...source, sink, offset: 0, state: 'ready' }; this.tasks.push(task); this.emit(); return task; }
    start(task) { if (['ready', 'paused', 'failed'].includes(task.state)) task.state = 'downloading'; this.emit(); }
    pause(task) { task.state = 'paused'; this.emit(); }
    cancel(task) { task.state = 'cancelled'; this.emit(); }
    remove(task) { this.tasks = this.tasks.filter(t => t !== task); this.emit(); }
    close() { this.closed = true; }
  }
  const engine = { Manager: FakeManager, BUFFER_LIMIT: 32 * 1024 * 1024,
    MemorySink: class { constructor() { this.kind = 'memory'; } blob() { return new Blob(['file']); } }, DiskSink: class {},
    sourceUrl: task => '/download?sessionId=' + encodeURIComponent(task.sessionId) + '&fileId=' + encodeURIComponent(task.fileId) };
  const root = { document: dom.document, LegnaDownloads: engine, URL: { createObjectURL(blob) { created.push(blob); return 'blob:fixture'; }, revokeObjectURL(url) { revoked.push(url); } }, isSecureContext: false };
  vm.createContext(root); vm.runInContext(source, root);
  const container = create('section'); dom.document.body.appendChild(container); const panel = root.LegnaDownloadUI.mount({ container, labels: en });
  return { ...dom, panel, container, created, revoked, downloads, root, manager: handles[0] };
}
const file = { fileName: 'nested/demo.txt', size: 10 };
test('task rows remain mounted across speed ticks, pause/resume, and language changes', async () => {
  const f = fixture(); await f.panel.add('f', file, 'old session'); const row = f.document.querySelectorAll('.download-task')[0];
  const task = f.manager.tasks[0], pause = f.descendants().find(n => n.tag === 'button' && n.textContent === en.downloadPause);
  pause.focus(); task.speed = 12000; task.offset = 6; f.manager.emit(); assert.equal(f.document.activeElement, pause);
  assert.match(f.document.querySelectorAll('.download-metrics')[0].textContent, /11.7 KiB\/s/);
  pause.onclick(); assert.equal(task.state, 'paused'); assert.equal(pause.hidden, true);
  const resume = f.descendants().find(n => n.tag === 'button' && n.textContent === en.continue); assert.equal(resume.hidden, false); resume.onclick();
  assert.equal(task.state, 'downloading'); f.panel.setLabels(zh); assert.equal(pause.textContent, '暂停'); assert.equal(f.document.querySelectorAll('.download-task')[0], row);
  const original = f.document.querySelectorAll('.download-original')[0]; assert.match(original.href, /sessionId=old%20session/);
  await f.panel.add('f', file, 'old session'); assert.equal(f.manager.tasks.length, 1); f.panel.close();
});
test('complete buffered files require an explicit save click and revoke their URL when removed', async () => {
  const f = fixture(); await f.panel.add('f', file, 's'); const task = f.manager.tasks[0]; task.offset = 10; task.state = 'complete'; f.manager.emit();
  assert.equal(f.downloads.length, 0); const save = f.descendants().find(n => n.tag === 'button' && n.textContent === en.downloadSave); assert.equal(save.hidden, false);
  save.onclick(); assert.deepEqual(f.downloads, [{ href: 'blob:fixture', download: 'nested-demo.txt' }]); assert.equal(f.created.length, 1);
  await f.descendants().find(n => n.tag === 'button' && n.textContent === en.downloadRemove).onclick(); assert.deepEqual(f.revoked, ['blob:fixture']); assert.equal(f.document.querySelectorAll('.download-task').length, 0);
  f.panel.close();
});
test('large downloads without disk-save capability explain unavailable storage and retain a real browser link', async () => {
  const f = fixture(); await f.panel.add('large', { fileName: 'large.bin', size: 33 * 1024 * 1024 }, 's');
  assert.equal(f.manager.tasks.length, 0); assert.ok(f.container.textContent.includes(en.dlError_storageUnsupported)); assert.match(f.document.querySelectorAll('.download-original')[0].href, /fileId=large/);
  f.panel.close();
});
test('source changes block continuation instead of showing a misleading retry button', async () => {
  const f = fixture(); await f.panel.add('f', file, 's'); const task = f.manager.tasks[0]; task.state = 'blocked'; task.error = 'sourceChanged'; f.manager.emit();
  const resume = f.descendants().find(n => n.tag === 'button' && n.textContent === en.continue); assert.equal(resume.hidden, true);
  assert.match(f.document.querySelectorAll('.download-error')[0].textContent, /source changed/); f.panel.close(); assert.equal(f.manager.closed, true);
});
test('buffer-cache lifecycle uses pause on page-cache entry, while full page close releases the manager', async () => {
  const f = fixture(); await f.panel.add('f', file, 's'); f.panel.pauseAll(); assert.equal(f.manager.tasks[0].state, 'paused'); assert.notEqual(f.manager.closed, true);
  f.panel.close(); assert.equal(f.manager.closed, true);
});

test('language changes preserve a capacity error and translate its ordinary-download fallback', async () => {
  const f = fixture(); await f.panel.add('large', { fileName: 'large.bin', size: 33 * 1024 * 1024 }, 's');
  f.panel.setLabels(zh); assert.ok(f.document.querySelectorAll('.download-message')[0].textContent.includes(zh.dlError_storageUnsupported));
  assert.equal(f.document.querySelectorAll('.download-original')[0].textContent, zh.downloadOriginal);
  assert.match(f.document.querySelectorAll('.download-original')[0].href, /fileId=large/); f.panel.close();
});

test('cancelling the native file picker clears the choosing state without creating a task', async () => {
  const f = fixture(); f.root.isSecureContext = true;
  f.root.showSaveFilePicker = async () => { throw Object.assign(new Error('cancelled'), { name: 'AbortError' }); };
  await f.panel.add('large', { fileName: 'large.bin', size: 33 * 1024 * 1024 }, 's');
  assert.equal(f.document.querySelectorAll('.download-message')[0].textContent, ''); assert.equal(f.manager.tasks.length, 0);
  await f.panel.add('small', file, 's'); assert.equal(f.manager.tasks.length, 1); f.panel.close();
});

for (const locale of ['en', 'zh-CN', 'zh-TW', 'zh-HK']) test(`authorization state is explicit and manually retryable in ${locale}`, async () => {
  const f = fixture(); await f.panel.add('f', file, 's');
  const task = f.manager.tasks[0]; task.state = 'failed'; task.error = 'authRequired'; task.offset = 4;
  const labels = require('../../assets/web/i18n/' + locale + '.json');
  f.panel.setLabels(labels);
  assert.equal(f.document.querySelectorAll('.download-state')[0].textContent, labels.dl_authRequired);
  assert.equal(f.document.querySelectorAll('.download-error')[0].textContent, labels.dlError_authRequired);
  const retry = f.descendants().find(n => n.tag === 'button' && n.textContent === labels.retry);
  assert.equal(retry.hidden, false); assert.equal(task.state, 'failed'); assert.equal(task.offset, 4);
  await retry.onclick(); assert.equal(task.state, 'downloading'); f.panel.close();
});
