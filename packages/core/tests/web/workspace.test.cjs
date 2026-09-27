const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { domFixture } = require('./dom_fixture.cjs');
async function flush() { for(let i=0;i<8;i++) await Promise.resolve(); }
function fixture(initial) {
  const dom = domFixture(), nodes={}, handlers={}, frames=[], timers=[];
  const create=dom.document.createElement;
  dom.document.createElement = tag => {
    const node=create(tag); node.events={}; node.addEventListener=(name,fn)=>node.events[name]=fn;
    if(tag==='iframe') { node.messages=[];node.contentWindow={postMessage:(...args)=>node.messages.push(args)};frames.push(node); }
    return node;
  };
  for (const id of ['web-language','tab-download','tab-upload','pane-download','pane-upload','workspace-tabs','workspace-state','workspace-empty','workspace-disabled']) {
    const node=dom.document.createElement('div');node.id=id;nodes[id]=node;dom.document.body.appendChild(node);
  }
  const en=require('../../assets/web/i18n/en.json'), zh=require('../../assets/web/i18n/zh-CN.json');
  let next=initial, bad=false, locale='en';
  const api={localize(){dom.document.documentElement.lang=locale;return{webUi:locale==='en'?en:zh};},apply(){},setLocale(value){locale=value;api.onLanguageChange?.();}};
  const root={document:dom.document,URLSearchParams,AbortController,location:{search:'?pin=1234',origin:'http://fixture'},
    LegnaWebUI:api,addEventListener:(name,fn)=>handlers[name]=fn,
    setTimeout:fn=>(timers.push(fn),timers.length),clearTimeout(){},fetch:async()=>({ok:!bad,json:async()=>next})};
  root.window=root;vm.createContext(root);vm.runInContext(fs.readFileSync(path.join(__dirname,'../../assets/web/workspace.js'),'utf8'),root);
  return {nodes,frames,handlers,api,async refresh(value,fail=false){next=value;bad=fail;timers.shift()();await flush();}};
}
test('workspace keeps both direction frames mounted across switches, permissions and locale changes',async()=>{
  const f=fixture({fileCount:0,allowUpload:false});await flush();assert.equal(f.frames.length,0);
  await f.refresh({fileCount:1,allowUpload:true});assert.equal(f.frames.length,1);
  const download=f.frames[0];assert.match(download.src,/^\/download\?pin=1234&workspace=1$/);
  f.nodes['tab-upload'].events.click();assert.equal(f.frames.length,2);const upload=f.frames[1];
  assert.equal(f.nodes['pane-download'].hidden,true);assert.match(upload.src,/^\/upload\?/);
  await f.refresh({fileCount:2,allowUpload:false});assert.equal(f.frames[0],download);assert.equal(f.frames[1],upload);
  assert.equal(upload.messages.at(-1)[0].status.allowUpload,false);
  f.nodes['tab-download'].events.click();assert.equal(f.frames.length,2);assert.equal(f.nodes['pane-upload'].hidden,true);
  f.api.setLocale('zh-CN');assert.equal(f.nodes['tab-download'].textContent,'取文件');assert.equal(f.frames.length,2);
  assert.equal(upload.messages.at(-1)[0].type,'legna-locale');
  f.handlers.pagehide();
});
test('workspace supports keyboard navigation and reports an interrupted service without destroying active frames',async()=>{
  const f=fixture({fileCount:1,allowUpload:true});await flush();
  f.nodes['workspace-tabs'].events.keydown({key:'ArrowRight',preventDefault(){}});
  assert.equal(f.nodes['tab-upload'].attributes['aria-selected'],'true');assert.equal(f.frames.length,2);
  await f.refresh(null,true);assert.match(f.nodes['workspace-state'].textContent,/interrupted/);assert.equal(f.frames.length,2);
  await f.refresh({fileCount:1,allowUpload:true});assert.match(f.nodes['workspace-state'].textContent,/allowed/);
  f.handlers.pagehide();
});
