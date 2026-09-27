const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm'),
  fs = require('node:fs'),
  path = require('node:path');
const { domFixture } = require('./dom_fixture.cjs');
const en = require('../../assets/web/i18n/en.json'),
  zh = require('../../assets/web/i18n/zh-CN.json');
const source = fs.readFileSync(path.join(__dirname, '../../assets/web/persistent-download-ui.js'), 'utf8');
function fixture(supported = true) {
  const dom = domFixture(),
    create = dom.document.createElement;
  dom.document.createElement = (tag) => {
    const n = create(tag);
    n.scrollIntoView = () => {};
    n.append = (...children) => children.forEach((child) => n.appendChild(child));
    n.insertBefore = (child, anchor) => {
      n.appendChild(child);
      n.children.splice(n.children.indexOf(child), 1);
      n.children.splice(n.children.indexOf(anchor), 0, child);
    };
    n.listeners = {};
    n.addEventListener = (event, callback) => (n.listeners[event] = callback);
    n.showModal = () => {
      n.open = true;
    };
    n.close = () => {
      n.open = false;
    };
    return n;
  };
  class Manager {
    constructor({ onChange }) {
      this.tasks = [];
      this.files = {};
      this.ready = Promise.resolve();
      this.emit = () => onChange(this.tasks);
      this.directory = null;
      this.registry = { directory: async () => {} };
    }
    async configureTransfers(settings) { Object.assign(this,{parallelFiles:settings.files,parallelRanges:settings.ranges,autoReconnect:settings.autoReconnect}); this.emit(); }
    pump() {}
    async setRetention(days) { this.retentionDays=days; this.cleanupReport={removed:2,retained:1,failed:1}; this.emit(); }
    attachSession(session, files) {
      this.session = session;
      this.files = files;
    }
    async add(source) {
      const task = { source, name: source.name, size: source.size, offset: 0, state: 'downloading', record: {} };
      this.tasks.push(task);
      this.emit();
      return task;
    }
    async start(task) {
      task.state = 'downloading';
      this.emit();
    }
    async pause(task) {
      task.state = 'paused';
      this.emit();
    }
    async remove(task) {
      this.tasks = this.tasks.filter((t) => t !== task);
      this.emit();
    }
    close() {
      this.closed = true;
    }
  }
  let picks = 0;
  const root = {
    document: dom.document, AbortController, URLSearchParams, URL, location: {href: "http://host/share", origin: "http://host"},
    showDirectoryPicker: async () => {
      picks++;
      return { name: 'chosen' };
    },
    LegnaPersistentDownloads: {
      supported: () => supported,
      Manager,
      sourceUrl: (s) => '/file/' + s.fileId,
      code: (e) => e.code || 'storage'
    }
  };
  vm.createContext(root);
  vm.runInContext(source, root);
  const container = dom.document.createElement('section');
  dom.document.body.appendChild(container);
  const panel = root.LegnaPersistentDownloadUI.mount({ container, labels: en });
  return { ...dom, root, panel, container, manager: panel.manager, picks: () => picks };
}
const file = { fileName: 'a.txt', size: 40 * 1024 * 1024 };
const button = (f, label) => f.descendants().find((n) => n.tag === 'button' && n.textContent === label);
test('unsupported storage never intercepts ordinary download or opens a picker', async () => {
  const f = fixture(false);
  await f.panel.add('f', file, 's');
  assert.equal(f.panel.available, false);
  assert.equal(f.picks(), 0);
  assert.ok(f.container.textContent.includes(en.downloadNativeHint));
  assert.equal(f.document.querySelectorAll('.download-task').length, 0);
  f.panel.setLabels(zh);
  assert.ok(f.container.textContent.includes(zh.downloadNativeHint));
  f.panel.close();
});
test('persistent task rows retain focus through pending checkpoints and language changes', async () => {
  const f = fixture();
  await f.panel.ready;
  await f.panel.add('f', file, 's');
  const task = f.manager.tasks[0],
    row = f.document.querySelectorAll('.download-task')[0],
    pause = button(f, en.downloadPause);
  pause.focus();
  task.offset = 1048576;
  task.pendingBytes = 4194304;
  task.speed = 2097152;
  f.manager.emit();
  assert.equal(f.document.activeElement, pause);
  assert.ok(f.container.textContent.includes('2.0 MiB/s'));
  assert.ok(f.container.textContent.includes(en.downloadPending));
  assert.equal(f.document.querySelectorAll('.download-progress')[0].value, 1048576);
  await pause.onclick();
  assert.equal(task.state, 'paused');
  task.restored = true;
  f.panel.setLabels(zh);
  assert.equal(f.document.querySelectorAll('.download-task')[0], row);
  assert.ok(f.container.textContent.includes(zh.downloadRecorded));
  assert.equal(pause.textContent, zh.downloadPause);
  await button(f, zh.continue).onclick();
  assert.equal(task.state, 'downloading');
  f.panel.close();
});
test('removal requires an in-page modal with cancel and live localized labels', async () => {
  const f = fixture();
  await f.panel.ready;
  await f.panel.add('f', file, 's');
  const dialog = f.document.querySelectorAll('dialog')[0];
  const remove = f.document.querySelectorAll('.download-task')[0].children.find(n => n.className === 'download-actions').children[2];
  remove.onclick();
  assert.equal(dialog.open, true);
  assert.equal(f.manager.tasks.length, 1);
  assert.equal(f.document.activeElement, button(f, en.cancel));
  f.panel.setLabels(zh);
  assert.equal(dialog.getAttribute('aria-label'), zh.downloadRemove);
  button(f, zh.cancel).onclick();
  assert.equal(dialog.open, false);
  assert.equal(f.manager.tasks.length, 1);
  remove.onclick();
  await dialog.children[2].children[1].onclick();
  assert.equal(dialog.open, false);
  assert.equal(f.manager.tasks.length, 0);
  f.panel.close();
});
test('complete task removal leaves file ownership to the manager without a cancellation dialog', async () => {
  const f = fixture();
  await f.panel.ready;
  await f.panel.add('f', file, 's');
  const task = f.manager.tasks[0];
  task.state = 'complete';
  task.offset = task.size;
  f.manager.emit();
  f.document.querySelectorAll('.download-task')[0].children.find(n => n.className === 'download-actions').children[2].onclick();
  await Promise.resolve();
  assert.equal(f.document.querySelectorAll('dialog')[0].open, undefined);
  assert.equal(f.manager.tasks.length, 0);
  f.panel.close();
});
test('current download entrypoints load persistent modules and leave ordinary links native', () => {
  const html = fs.readFileSync(path.join(__dirname, '../../assets/web/download.html'), 'utf8');
  assert.match(html, /persistent-downloads\.js/);
  assert.doesNotMatch(html, /src="\/assets\/download-engine\.js"/);
  const directories = fs.readFileSync(path.join(__dirname, '../../assets/web/directories.js'), 'utf8');
  assert.match(directories, /if\(event.persisted\)downloads.pauseAll\(\)/);
  assert.match(directories, /'pageshow',function\(event\)\{pageActive=true;if\(event.persisted\)resumeBrowsing\(/);
  assert.doesNotMatch(html, /onManaged:/);
  assert.match(html, /onDownload:/);
  assert.match(html, /onBatch:/);
});

test('one download entry uses browser default until a directory is configured', async()=>{
 const f=fixture();await f.panel.ready;
 assert.equal(f.panel.downloadSource({kind:'web',fileId:'f',name:'a.txt',size:1}),false);
 assert.equal(f.picks(),0);assert.equal(f.manager.tasks.length,0);
 await button(f,en.downloadChooseFolder).onclick();assert.equal(f.picks(),1);
 assert.equal(f.panel.downloadSource({kind:'web',fileId:'f',name:'a.txt',size:1}),true);
 await new Promise(resolve=>setImmediate(resolve));assert.equal(f.manager.tasks.length,1);
 await button(f,en.downloadBrowserFolder).onclick();assert.equal(f.manager.directory,null);
 assert.equal(f.panel.downloadSource({kind:'web',fileId:'g',name:'b',size:1}),false);
 assert.equal(f.manager.tasks.length,1);f.panel.close();
});
test('HTTP-style missing directory API retains an explanatory save-location control',async()=>{
 const f=fixture(false);await f.panel.ready;
 const control=button(f,en.downloadChooseFolder);assert.equal(control.hidden,false);assert.equal(control.disabled,false);
 await control.onclick();assert.equal(f.picks(),0);assert.equal(f.document.querySelectorAll('details')[0].open,true);
 assert.match(f.container.textContent,/HTTP/);assert.equal(f.panel.downloadSource({}),false);f.panel.close();
});

test('selected batch preparation uses a short browser download link, never a navigation form or ZIP Blob',async()=>{
 const f=fixture(false),downloads=[];await f.panel.ready;
 const create=f.document.createElement;f.document.createElement=tag=>{assert.notEqual(tag,'form');const n=create(tag);if(tag==='a')n.click=()=>downloads.push({url:n.href,download:n.getAttribute('download')});return n;};
 let calls=0;
 f.root.fetch=async(url,options)=>{calls++;assert.equal(url,'/archive?prepare=1');assert.equal(options.method,'POST');assert.equal(options.body,'sessionId=s&fileId=a&fileId=b');return {ok:true,json:async()=>({entries:2,downloadUrl:'/archive?sessionId=s&selection=ticket'})};};
 await f.panel.batch('/archive',[['sessionId','s'],['fileId','a'],['fileId','b']]);
 assert.equal(calls,1);assert.deepEqual(downloads,[{url:'http://host/archive?sessionId=s&selection=ticket',download:''}]);
 assert.ok(f.container.textContent.includes(en.downloadStartedHint));assert.equal(f.picks(),0);f.panel.close();
});
test('prepared batch rejects foreign, malformed and wrong-endpoint links without losing the page',async()=>{
 const f=fixture(false);await f.panel.ready;
 for(const url of ['https://foreign/archive?selection=x','/wrong?selection=x','/archive','/archive?selection=x#fragment','javascript:alert(1)']){
   f.root.fetch=async()=>({ok:true,json:async()=>({downloadUrl:url})});
   await f.panel.batch('/archive',[['sessionId','s']]);
   assert.ok(f.container.textContent.includes(en.dlError_network));
   assert.equal(f.document.querySelectorAll('form').length,0);
 }
 f.panel.close();
});
test('closing while a selection is being prepared prevents late browser downloads',async()=>{
 const f=fixture(false);await f.panel.ready;let release;
 f.root.fetch=async()=>({ok:true,json:()=>new Promise(resolve=>release=resolve)});
 const pending=f.panel.batch('/archive',[['sessionId','s']]);await new Promise(resolve=>setImmediate(resolve));
 f.panel.close();release({downloadUrl:'/archive?selection=ticket'});await pending;
 assert.equal(f.document.querySelectorAll('a').length,0);
});
test('batch preflight failures remain inline and never launch a download',async()=>{
 const f=fixture(false);await f.panel.ready;
 for(const [status,key] of [[401,'authRequired'],[410,'sourceEnded'],[409,'archiveConflict'],[413,'archiveLimit'],[429,'busy']]){
  f.root.fetch=async()=>({ok:false,status});await f.panel.batch('/archive');assert.ok(f.container.textContent.includes(en['dlError_'+key]));assert.equal(f.document.querySelectorAll('form').length,0);
 }
 f.panel.close();
});
test('duplicate batch clicks share one preflight and closing aborts it',async()=>{
 const f=fixture(false);await f.panel.ready;let calls=0,signal;
 f.root.fetch=(_,options)=>{calls++;signal=options.signal;return new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(Object.assign(new Error('cancelled'),{name:'AbortError'}))));};
 const pending=f.panel.batch('/archive');await f.panel.batch('/archive');assert.equal(calls,1);f.panel.close();await pending;assert.equal(signal.aborted,true);
});

test('retention policy is an accessible inline setting with live cleanup report and translated labels',async()=>{
  const f=fixture();await f.panel.ready;
  const select=f.descendants().find(n=>n.tag==='select'&&n.getAttribute('aria-label')==='Keep unfinished downloads');
  assert.ok(select);assert.ok(select.children.some(n=>n.value==='-2'&&n.textContent==='1 hour (default)'));
  select.value='-2';await select.onchange();assert.equal(f.manager.retentionDays,-2);
  select.value='7';await select.onchange();
  assert.equal(f.manager.retentionDays,7);assert.ok(f.container.textContent.includes('Removed: 2'));
  f.document.documentElement={lang:'zh-CN'};f.manager.emit();
  assert.equal(select.getAttribute('aria-label'),'未完成下载保留');assert.ok(f.container.textContent.includes('保留／待重试: 2'));
  f.document.documentElement.lang='zh-TW';f.manager.emit();assert.equal(select.getAttribute('aria-label'),'未完成下載保留');
  f.panel.close();
});

test('bulk pause resume and completed-record clearing keep controls and task ownership distinct',async()=>{
 const f=fixture();await f.panel.ready;await f.panel.add('a',file,'s');await f.panel.add('b',file,'s');
 const pause=button(f,en.downloadPauseAll),resume=button(f,en.downloadResumeAll),clear=button(f,en.downloadClearFinished);
 pause.onclick();for(let i=0;i<10;i++)await Promise.resolve();assert.ok(f.manager.tasks.every(t=>t.state==='paused'));
 resume.onclick();for(let i=0;i<10;i++)await Promise.resolve();assert.ok(f.manager.tasks.every(t=>t.state==='downloading'));
 f.manager.tasks[0].state='complete';f.manager.emit();clear.onclick();for(let i=0;i<10;i++)await Promise.resolve();
 assert.equal(f.manager.tasks.length,1);assert.equal(f.manager.tasks[0].state,'downloading');f.panel.close();
});

for (const locale of ['en', 'zh-CN', 'zh-TW', 'zh-HK']) test(`authorization state is explicit and manually retryable in ${locale}`, async () => {
  const f = fixture(); await f.panel.ready; await f.panel.add('f', file, 's');
  const task = f.manager.tasks[0]; task.state = 'failed'; task.error = 'authRequired'; task.offset = 4;
  const labels = require('../../assets/web/i18n/' + locale + '.json');
  f.panel.setLabels(labels);
  assert.equal(f.document.querySelectorAll('.download-state')[0].textContent, labels.dl_authRequired);
  assert.equal(f.document.querySelectorAll('.download-error')[0].textContent, labels.dlError_authRequired);
  const retry = f.descendants().find(n => n.tag === 'button' && n.textContent === labels.retry);
  assert.equal(retry.hidden, false); assert.equal(task.state, 'failed'); assert.equal(task.offset, 4);
  await retry.onclick(); assert.equal(task.state, 'downloading'); f.panel.close();
});
