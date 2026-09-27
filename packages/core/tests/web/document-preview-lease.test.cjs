'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const api=require('../../assets/web/directory-preview.js');
const lease='11111111-1111-4111-8111-111111111111',tag='"'+'a'.repeat(64)+'"';
const url='/api/legnasend/v1/workspaces/workspace/files/file/content?generation=7';
const base='http://127.0.0.1:53317/folder/';
function receipt(overrides={}){return {url:url+'&preview=1&lease='+lease,size:104857600,etag:tag,mime:'text/plain',lease,...overrides};}
function response(value){return new Response(JSON.stringify(value),{status:200,headers:{'Content-Type':'application/json'}});}
function source(fetch){return api.documentLease({url,base,file:{id:'file'},fetch});}

test('document preview acquires one bounded lease and preserves source path and generation',async()=>{
  const calls=[];
  const owner=source(async(path,init)=>{calls.push({path,init});return response(path.includes('prepare-preview')?receipt():{});});
  const result=await owner.prepare();
  assert.equal(result.tag,tag);assert.equal(result.size,104857600);
  assert.equal(new URL(result.url,base).searchParams.get('lease'),lease);
  assert.equal(calls[0].path,'/api/legnasend/v1/workspaces/workspace/prepare-preview?generation=7');
  assert.deepEqual(JSON.parse(calls[0].init.body),{id:'file'});
  assert.equal(calls[0].init.credentials,'same-origin');assert.equal(calls[0].init.redirect,'error');
  assert.strictEqual(await owner.prepare(),result);assert.equal(calls.length,1);
  await owner.close();await owner.close();
  assert.equal(calls.length,2);assert.deepEqual(JSON.parse(calls[1].init.body),{lease});
  assert.equal(calls[1].init.keepalive,true);
});
test('closing during prepare returns the late lease without mounting or aborting that response',async()=>{
  let resolve,signal;const closes=[];
  const owner=source((path,init)=>{
    if(path.includes('prepare-preview')){signal=init.signal;return new Promise(done=>resolve=done);}
    closes.push(JSON.parse(init.body).lease);return Promise.resolve(response({}));
  });
  const pending=owner.prepare();await owner.close();assert.equal(signal.aborted,false);
  resolve(response(receipt()));await assert.rejects(pending,{code:'closed'});assert.deepEqual(closes,[lease]);
});
test('foreign or different file lease URLs and invalid metadata are rejected and released locally',async()=>{
  for(const patch of [{url:'https://other.invalid/private'},{url:url.replace('/file/','/other/')+'&preview=1&lease='+lease},
    {url:url.replace('generation=7','generation=8')+'&preview=1&lease='+lease},
    {etag:'W/'+tag},{size:Infinity},{url:url+'&preview=1&lease=22222222-2222-4222-8222-222222222222'}]){
    const calls=[];const owner=source(async(path,init)=>{calls.push(path);return response(path.includes('prepare-preview')?receipt(patch):{});});
    await assert.rejects(owner.prepare());assert.equal(calls.length,2);assert.match(calls[1],/^\/api\/legnasend\/v1\/workspaces\/workspace\/close-preview/);
  }
});
test('expired or denied preparation never falls back to ordinary document HEAD or loads bytes',async()=>{
  for(const status of [401,409,410]){
    const calls=[];const owner=source(async(path)=>{calls.push(path);return new Response(null,{status});});
    await assert.rejects(owner.prepare(),{status});assert.equal(calls.length,1);assert.match(calls[0],/prepare-preview/);
  }
});
test('oversized preparation JSON fails within the response budget rather than buffering content',async()=>{
  const owner=source(async()=>new Response('x'.repeat(8193)));
  await assert.rejects(owner.prepare(),{code:'unsupported'});
});

const fs=require('node:fs'),vm=require('node:vm');
function previewFixture(){
  const elements=new Map(),docEvents={},windowEvents={},calls=[],mounts=[];
  class Element{
    constructor(){this.open=false;this.hidden=false;this.isConnected=true;this.handlers={};}
    addEventListener(name,fn){this.handlers[name]=fn;}
    removeAttribute(name){delete this[name];}
    replaceChildren(){} focus(){} close(){this.open=false;} showModal(){this.open=true;}
    querySelector(){return null;}
  }
  const doc={hidden:false,activeElement:new Element(),getElementById(id){if(!elements.has(id))elements.set(id,new Element());return elements.get(id);},
    addEventListener(name,fn){docEvents[name]=fn;}};
  let count=0;
  const fetch=async(path,init={})=>{
    calls.push({path,init});
    if(path.includes('prepare-preview')){count++;const id=count===1?lease:'22222222-2222-4222-8222-222222222222';return response(receipt({lease:id,url:url+'&preview=1&lease='+id,size:10}));}
    if(path.includes('close-preview'))return response({});
    assert.equal(init.method,'HEAD');assert.match(path,/lease=/);
    return new Response(null,{headers:{'Content-Length':'10','ETag':tag,'Accept-Ranges':'bytes','Content-Type':'text/plain'}});
  };
  const labels={webUi:{retry:'Retry',text:'Text'},textPreview:{},preview:'Preview',previewLoading:'Loading',closePreview:'Close',downloadOriginal:'Download',previewError:'Failed',previewUnsupported:'Unsupported'};
  const window={document:doc,location:new URL(base),fetch,addEventListener(name,fn){windowEvents[name]=fn;},LegnaWebLocales:{en:labels},
    LegnaTextPreview:{mount(options){const record={options,closed:false};mounts.push(record);return{close(){record.closed=true;}};}}};
  const context=vm.createContext({window,URL,AbortController,TextDecoder,Uint8Array,setTimeout,clearTimeout,Promise,console});
  vm.runInContext(fs.readFileSync(require.resolve('../../assets/web/directory-preview.js'),'utf8'),context);
  return {api:window.LegnaDirectoryPreview.create({onInvalid(){}}),elements,doc,docEvents,windowEvents,calls,mounts};
}
test('document text renderer retains normal original download and reacquires after explicit retry',async()=>{
  const f=previewFixture();
  await f.api.open({id:'file',name:'notes.md',size:10},url,'en',false,{documents:true});
  assert.equal(f.mounts.length,1);assert.equal(f.mounts[0].options.markdown,true);
  assert.match(f.mounts[0].options.url,/lease=/);assert.match(f.mounts[0].options.url,/version=/);
  assert.equal(f.elements.get('directory-preview-download').href,url);
  f.elements.get('directory-preview-retry').onclick();await new Promise(setImmediate);await new Promise(setImmediate);
  assert.equal(f.mounts.length,2);assert.equal(f.mounts[0].closed,true);
  assert.notEqual(f.mounts[0].options.url,f.mounts[1].options.url);
  f.doc.hidden=true;f.docEvents.visibilitychange();await new Promise(setImmediate);
  assert.equal(f.mounts[1].closed,true);assert.equal(f.elements.get('directory-preview').open,false);
  assert.equal(f.calls.filter(v=>v.path.includes('close-preview')).length,2);
  f.doc.hidden=false;f.docEvents.visibilitychange();await new Promise(setImmediate);
  assert.equal(f.mounts.length,2,'returning to foreground does not silently acquire a new source');
});
