const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const { domFixture } = require('./dom_fixture.cjs');
async function until(fn) { for (let i = 0; i < 100; i++) { if (fn()) return; await new Promise(r => setTimeout(r, 5)); } assert.fail('UI did not settle'); }
function fixture(workspace = false) {
  const dom = domFixture(), nodes = {}, intervals = new Map(), requests = [], xhrs = [], handlers = {};
  for (const id of ['file-input','folder-input','upload-button','folder-button','web-language','status-text','progress-text','transfer-metrics','transfer-progress','transfer-bytes','transfer-speed','content']) {
    nodes[id] = dom.element(id.endsWith('input') ? 'input' : 'div'); nodes[id].id = id; dom.document.body.appendChild(nodes[id]);
  }
  let now = 0, count = 0;
  dom.document.addEventListener = () => {};
  const labels = require('../../assets/web/i18n/en.json');
  const sandbox = { document: dom.document, AbortController, URLSearchParams, Response, Uint8Array, setTimeout, clearTimeout,
    setInterval: fn => { intervals.set(++count, fn); return count; }, clearInterval: id => intervals.delete(id), performance: { now: () => now },
    location: { protocol:'http:', search:workspace?'?workspace=1':'', origin:'http://fixture' }, parent: {}, sessionStorage: { getItem: () => 'fixture' }, crypto: {},
    addEventListener: (name, fn) => handlers[name] = fn,
    LegnaWebUI: { localize: () => ({ webUi: labels, waiting: 'Waiting', uploadRejected: 'Rejected' }), apply: () => labels, translateStatus() {} },
    fetch: async (url, options) => { requests.push({ url, options }); return new Response(JSON.stringify(url === '/i18n.json' ? {} : url === '/web-status.json' ? {allowUpload:true,fileCount:1} : { sessionId:'s', files: { '1': 'token' } })); },
    XMLHttpRequest: function () { this.upload = {}; this.status = 200; this.open = (method, url) => this.url = url; this.send = body => this.body = body; this.abort = () => this.onabort?.(); xhrs.push(this); },
  };
  vm.createContext(sandbox); vm.runInContext(fs.readFileSync(path.join(__dirname, '../../assets/web/web-upload.js'), 'utf8'), sandbox);
  return { nodes, intervals, requests, xhrs, handlers, parent: sandbox.parent, tick(time) { now = time; [...intervals.values()].forEach(fn => fn()); } };
}
test('upload UI uses accepted bytes, reports live/stalled speed and waits for receiver before completion', async () => {
  const f = fixture(); await until(() => !f.nodes['upload-button'].disabled);
  const files = [{ name:'declined.txt',size:1000,type:'text/plain' },{ name:'accepted.txt',size:3000,type:'text/plain' }];
  f.nodes['file-input'].files = files; f.nodes['file-input'].onchange(); await until(() => f.xhrs.length === 1);
  const xhr = f.xhrs[0]; assert.equal(xhr.body, files[1]); assert.match(xhr.url, /sessionId=s&fileId=1&token=token$/);
  assert.equal(f.nodes['transfer-metrics'].hidden, false); assert.equal(f.nodes['transfer-bytes'].textContent, '0 B / 3.0 KB');
  xhr.upload.onprogress({ loaded:1000 }); f.tick(500);
  assert.equal(f.nodes['transfer-speed'].textContent, 'Speed: 2.0 KB/s'); assert.equal(f.nodes['transfer-progress'].value, 1 / 3);
  for (let t = 1000; t <= 4000; t += 500) f.tick(t);
  assert.equal(f.nodes['transfer-speed'].textContent, 'Speed: 0 B/s');
  xhr.upload.onprogress({ loaded:3000 }); assert.equal(f.nodes['status-text'].textContent, 'Waiting for the receiving device to confirm…');
  assert.equal(f.nodes['upload-button'].disabled, true); xhr.onload(); await until(() => !f.nodes['upload-button'].disabled);
  assert.equal(f.nodes['status-text'].textContent, 'Transfer complete'); assert.equal(f.nodes['transfer-progress'].value, 1);
  assert.equal(f.nodes['transfer-speed'].textContent, 'Average speed: 750 B/s'); assert.equal(f.intervals.size, 0);
});
test('page hide aborts upload and removes the speed timer without reporting completion', async () => {
  const f = fixture(); await until(() => !f.nodes['upload-button'].disabled);
  f.nodes['file-input'].files = [{name:'a',size:1},{name:'b',size:100}]; f.nodes['file-input'].onchange(); await until(() => f.xhrs.length === 1);
  f.handlers.pagehide(); await until(() => f.intervals.size === 0);
  assert.equal(f.nodes['transfer-metrics'].hidden, true); assert.notEqual(f.nodes['status-text'].textContent, 'Transfer complete');
});

test('an acknowledged empty file completes without division by zero or a permanent measuring label', async () => {
  const f = fixture(); await until(() => !f.nodes['upload-button'].disabled);
  f.nodes['file-input'].files = [{name:'not-selected',size:10},{name:'empty.txt',size:0}]; f.nodes['file-input'].onchange(); await until(() => f.xhrs.length === 1);
  f.xhrs[0].onload(); await until(() => !f.nodes['upload-button'].disabled);
  assert.equal(f.nodes['transfer-progress'].value, 1); assert.equal(f.nodes['transfer-bytes'].textContent, '0 B / 0 B');
  assert.equal(f.nodes['transfer-speed'].textContent, 'Average speed: —'); assert.equal(f.intervals.size, 0);
});

test('workspace permission disables new uploads while an approved transfer survives tab hiding and permission changes', async () => {
  const f=fixture(true);await until(()=>!f.nodes['upload-button'].disabled);
  f.nodes['file-input'].files=[{name:'skip',size:1},{name:'approved',size:3}];f.nodes['file-input'].onchange();await until(()=>f.xhrs.length===1);
  assert.match(f.requests.find(r=>r.url.includes('prepare-upload')).url,/web=1/);
  f.handlers.message({origin:'http://fixture',source:f.parent,data:{type:'legna-workspace',status:{allowUpload:false}}});
  const xhr=f.xhrs[0];xhr.upload.onprogress({loaded:3});xhr.onload();await until(()=>f.intervals.size===0);
  assert.equal(f.nodes['status-text'].textContent,'Transfer complete');assert.equal(f.nodes['upload-button'].disabled,true);
  f.handlers.message({origin:'http://other',source:f.parent,data:{type:'legna-workspace',status:{allowUpload:true}}});
  assert.equal(f.nodes['upload-button'].disabled,true);
  f.handlers.message({origin:'http://fixture',source:f.parent,data:{type:'legna-workspace',status:{allowUpload:true}}});
  assert.equal(f.nodes['upload-button'].disabled,false);
  f.handlers.pagehide();
});
