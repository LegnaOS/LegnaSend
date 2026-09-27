'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const upload=require('../../assets/web/directory-upload.js');
const context={id:'workspace',slug:'design',name:'Design',generation:7,path:'目标',allowUpload:true,authorized:true};
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function file(name='note.txt',size=4){return {name,size};}
function fixture(extra={}){
 const requests=[],events=[];
 class XHR {
  constructor(){this.upload={};this.headers={};requests.push(this);}
  open(method,url,async){Object.assign(this,{method,url,async});}
  setRequestHeader(k,v){this.headers[k]=v;}
  send(body){this.body=body;}
  abort(){this.aborted=true;if(this.onabort)this.onabort();}
  respond(status,body){this.status=status;this.responseText=JSON.stringify(body);this.onload();}
 }
 const manager=new upload.Manager({xhrFactory:()=>new XHR(),onAuth:()=>events.push('auth'),onInvalid:reason=>events.push(reason),resolveConflict:async()=> 'conflict',...extra});
 manager.setContext(context);
 const add=(entries,target=manager.snapshot())=>manager.enqueue(entries,target);
 const success=(i)=>{const task=manager.tasks.find(t=>t.xhr===requests[i]);requests[i].respond(201,{path:task.path,size:task.size,sha256:'ab'.repeat(32),directory:task.directory});};
 return {manager,requests,events,add,success};
}
test('all upload locales are complete and traditional variants stay traditional',()=>{
 const keys=Object.keys(upload.messages.en).sort();for(const values of Object.values(upload.messages)){assert.deepEqual(Object.keys(values).sort(),keys);assert.ok(Object.values(values).every(v=>typeof v==='string'&&v.length));}
 assert.equal(upload.locale('zh-HK'),'zh-HK');assert.equal(upload.locale('zh-Hans'),'zh-CN');assert.equal(upload.locale('fr'),'en');
});
test('relative path validation matches bounded cross-platform names and excludes cache files',()=>{
 for(const value of ['中文 %/😀.txt','a/b/c','folder','spaces allowed/file.txt'])assert.equal(upload.validPath(value),true,value);
 for(const value of ['', '/absolute','../file','a/../b','a//b','C:/bad','a\\b','x\0y','a/CON.txt','a/NUL','a/trailing.','a/trailing ','a/cache.ls','.legnasend-owned/a',Array(65).fill('a').join('/'),'中'.repeat(86)])assert.equal(upload.validPath(value),false,value);
});
test('read-only and unauthenticated workspaces never accept queued files',()=>{
 const f=fixture();f.manager.setContext({...context,allowUpload:false});assert.equal(f.manager.snapshot(),null);assert.throws(()=>f.add([{path:'a',file:file()}],context),/permission/);assert.equal(f.requests.length,0);
 f.manager.setContext({...context,authorized:false});assert.equal(f.manager.snapshot(),null);
});
test('selection target is immutable across directory navigation and requests use raw file bodies',()=>{
 const f=fixture(),selected=f.manager.snapshot(),original=file('文件 %.txt',9);
 f.manager.setContext({...context,path:'other'});const [task]=f.add([{path:original.name,file:original}],selected);
 assert.equal(task.path,'目标/文件 %.txt');assert.equal(task.base,'目标');assert.equal(f.requests[0].body,original);
 assert.equal(f.requests[0].method,'POST');assert.equal(f.requests[0].headers['X-LegnaSend-Upload'],'1');assert.equal(f.requests[0].headers['Content-Type'],'application/octet-stream');assert.equal(f.requests[0].withCredentials,true);
 const url=new URL(f.requests[0].url,'http://fixture');assert.equal(url.searchParams.get('generation'),'7');assert.equal(url.searchParams.get('path'),task.path);assert.equal(url.searchParams.has('directory'),false);
});
test('two request bound holds for 5000 files and cancellation does not accidentally start the queue',()=>{
 const f=fixture();f.add(Array.from({length:5000},(_,i)=>({path:`${i}.txt`,file:file(`${i}.txt`)})));
 assert.equal(f.requests.length,2);assert.equal(f.manager.running,2);f.manager.cancelAll();assert.equal(f.requests.length,2);assert.equal(f.manager.running,0);assert.ok(f.manager.tasks.every(t=>t.state==='cancelled'));
 f.manager.clear();assert.equal(f.manager.tasks.length,0);
});
test('generation change and permission revocation cancel active and queued work',()=>{
 for(const change of [{...context,generation:8},{...context,allowUpload:false}]){
  const f=fixture();f.add(Array.from({length:8},(_,i)=>({path:`${i}`,file:file()})));f.manager.observe(change);
  assert.equal(f.manager.context,null);assert.equal(f.requests.length,2);assert.ok(f.requests.every(r=>r.aborted));assert.ok(f.manager.tasks.every(t=>t.state==='cancelled'));
  assert.equal(f.manager.retry(f.manager.tasks[0]),false);assert.deepEqual(f.events,[]);
 }
});
test('ordinary directory refresh suspends selection but does not cancel captured uploads',()=>{
 const f=fixture();f.add([{path:'a',file:file()},{path:'b',file:file()},{path:'c',file:file()}]);f.manager.suspend();assert.equal(f.manager.snapshot(),null);f.manager.observe(context);f.success(0);
 assert.equal(f.requests.length,3);assert.ok(!f.requests[1].aborted);f.manager.setContext({...context,path:'new'});assert.equal(f.manager.snapshot().path,'new');assert.equal(f.manager.tasks[2].path,'目标/c');
});
test('401 or readonly 403 stops the entire queue instead of sending thousands of failing requests',()=>{
 for(const [status,reason] of [[401,'auth'],[403,'permission']]){
  const f=fixture();f.add(Array.from({length:100},(_,i)=>({path:`${i}`,file:file()})));f.requests[0].respond(status,{});
  assert.equal(f.requests.length,2);assert.equal(f.manager.tasks[0].state,'failed');assert.equal(f.manager.tasks[0].error,reason);assert.ok(f.manager.tasks.slice(1).every(t=>t.state==='cancelled'));assert.deepEqual(f.events,[reason]);
 }
});
test('busy and network errors pause remaining uploads until an explicit user action',()=>{
 for(const status of [429,0]){
  const f=fixture();f.add(Array.from({length:7},(_,i)=>({path:`${i}`,file:file()})));
  if(status)f.requests[0].respond(status,{});else f.requests[0].onerror();f.success(1);
  assert.equal(f.requests.length,2);assert.equal(f.manager.paused,true);assert.equal(f.manager.tasks[2].state,'queued');
  f.manager.retry(f.manager.tasks[0]);assert.equal(f.requests.length,4);assert.equal(f.requests[2].body,f.manager.tasks[0].file);assert.equal(f.manager.tasks[0].path,'目标/0');
 }
});
test('upload bytes reaching 100% wait for provider confirmation and expose measured speed',()=>{
 let now=1000;const f=fixture({now:()=>now});const [task]=f.add([{path:'a',file:file('a',4096)}]);now+=1000;f.requests[0].upload.onprogress({loaded:2048});assert.equal(task.speed,2048);now+=1000;f.requests[0].upload.onprogress({loaded:4096});assert.equal(task.state,'publishing');assert.equal(f.manager.running,1);f.success(0);assert.equal(task.state,'succeeded');assert.equal(task.speed,0);
});
test('missing or mismatched success receipts remain failures rather than fabricated success',()=>{
 for(const response of [{},{path:'wrong',size:4,sha256:'a'.repeat(64),directory:false},{path:'目标/a',size:3,sha256:'a'.repeat(64),directory:false},{path:'目标/a',size:4,sha256:'wrong',directory:false}]){
  const f=fixture();const [task]=f.add([{path:'a',file:file()}]);f.requests[0].respond(201,response);assert.equal(task.state,'failed');assert.equal(task.error,'response');assert.equal(f.manager.paused,true);
 }
});
test('empty directories use explicit zero-byte requests and a directory receipt',()=>{
 const f=fixture();const [task]=f.add([{path:'empty/nested',directory:true}]);assert.equal(f.requests[0].body.size,0);assert.equal(new URL(f.requests[0].url,'http://fixture').searchParams.get('directory'),'true');f.success(0);assert.equal(task.state,'succeeded');
});
test('409 resolves generation before allowing a name-conflict rename',async()=>{
 const f=fixture();const [task]=f.add([{path:'x/a.txt',file:file()}]);f.requests[0].respond(409,{});assert.equal(task.state,'checking');await tick();assert.equal(task.error,'conflict');assert.equal(task.state,'failed');assert.equal(f.manager.paused,true);
 f.manager.setContext({...context,path:'elsewhere'});assert.throws(()=>f.manager.retry(task,'../escape'),/invalid/);assert.equal(f.manager.retry(task,'renamed.txt'),true);assert.equal(task.path,'目标/x/renamed.txt');assert.equal(f.requests[1].body,task.file);
});
test('stale generation after 409 cancels other work and never offers rename',async()=>{
 const f=fixture({resolveConflict:async()=> 'changed'});f.add([{path:'a',file:file()},{path:'b',file:file()},{path:'c',file:file()}]);f.requests[0].respond(409,{});await tick();assert.equal(f.manager.tasks[0].error,'changed');assert.equal(f.requests.length,2);assert.equal(f.manager.tasks[1].state,'cancelled');assert.equal(f.manager.tasks[2].state,'cancelled');assert.equal(f.manager.retry(f.manager.tasks[0],'renamed'),false);
});
test('cancel during conflict metadata lookup ignores a late successful lookup',async()=>{
 let resolve;const f=fixture({resolveConflict:()=>new Promise(r=>resolve=r)});const [task]=f.add([{path:'a',file:file()}]);f.requests[0].respond(409,{});await tick();f.manager.cancel(task);resolve('conflict');await tick();assert.equal(task.state,'cancelled');assert.deepEqual(f.events,[]);assert.equal(f.manager.running,0);
});
test('folder chooser retains webkit-relative paths and drag traversal reads all batches plus empty folders',async()=>{
 const original=file('文.txt');original.webkitRelativePath='root/sub/文.txt';assert.equal(upload.fileEntries([original])[0].path,original.webkitRelativePath);
 function entry(name){return {name,isFile:true,file:ok=>ok(file(name))};}
 function dir(name,batches){return {name,isDirectory:true,createReader(){let at=0;return {readEntries(ok){ok(batches[at++]||[]);}};}};}
 const entries=await upload.scanDrop({entries:[dir('root',[[entry('a')],[dir('empty',[]),dir('deep',[[entry('中文.txt')]])]])],files:[]});
 assert.deepEqual(entries.map(e=>[e.path,!!e.directory]),[['root/a',false],['root/empty',true],['root/deep/中文.txt',false]]);
});
test('drag entries are captured before asynchronous enumeration begins',async()=>{
 let captured=0;const f=file('from-file-list');const result=upload.captureDrop({items:[{kind:'string'},{kind:'file',webkitGetAsEntry(){captured++;return {name:'empty',isDirectory:true,createReader(){return {readEntries(ok){ok([]);}};}};}}],files:[f]});assert.equal(captured,1);assert.deepEqual((await upload.scanDrop(result)).map(x=>x.path),['empty']);
 assert.equal((await upload.scanDrop({entries:[],files:[f]}))[0].file,f);
});
test('queue intake is atomic for invalid names and bounded before creating network requests',()=>{
 const f=fixture();assert.throws(()=>f.add([{path:'valid',file:file()},{path:'../invalid',file:file()}]),/invalid/);assert.equal(f.requests.length,0);assert.equal(f.manager.tasks.length,0);
 assert.throws(()=>f.add(Array.from({length:upload.MAX_TASKS+1},()=>({path:'a',file:file()}))),/limit/);assert.equal(f.requests.length,0);
});
test('UI keeps paged task rows and uses text-only names, native modal and HTTP-compatible file inputs',()=>{
 const assets=path.resolve(__dirname,'../../assets/web'),js=fs.readFileSync(path.join(assets,'directory-upload.js'),'utf8'),html=fs.readFileSync(path.join(assets,'directories.html'),'utf8');
 assert.equal(upload.PAGE,24);assert.ok(js.includes('slice(page*PAGE,page*PAGE+PAGE)'));assert.ok(js.includes("el('dialog'"));assert.ok(js.includes("folder.setAttribute('webkitdirectory'"));assert.ok(!js.includes('innerHTML'));assert.ok(!js.includes('alert('));assert.ok(!js.includes('showDirectoryPicker'));assert.ok(html.includes('id="workspace-upload"'));assert.ok(html.indexOf('/assets/directory-upload.js')<html.indexOf('/assets/directories.js'));
});

test('document parent is an immutable opaque token, never a relative path prefix',()=>{
 const f=fixture(),parent='11111111-1111-4111-8111-111111111111';
 f.manager.setContext({...context,backend:'documents',path:parent,displayPath:'资料'});
 const selected=f.manager.snapshot();f.manager.setContext({...context,backend:'documents',path:'other-token'});
 const [task]=f.add([{path:'nested/文本.txt',file:file('文本.txt',7)}],selected);
 const url=new URL(f.requests[0].url,'http://fixture');
 assert.equal(url.searchParams.get('parent'),parent);assert.equal(url.searchParams.get('path'),'nested/文本.txt');assert.equal(task.path,'nested/文本.txt');
 f.requests[0].respond(201,{parent:'wrong-parent',path:task.path,size:7,directory:false,sha256:'ab'.repeat(32)});
 assert.equal(task.error,'response');assert.equal(f.manager.retry(task),true);
 const retry=new URL(f.requests[1].url,'http://fixture');assert.equal(retry.searchParams.get('parent'),parent);
 f.requests[1].respond(201,{parent,path:task.path,size:7,directory:false,sha256:'ab'.repeat(32)});
 assert.equal(task.state,'succeeded');f.manager.close();
});

test('legacy filesystem uploads never gain a provider parent parameter',()=>{
 const f=fixture();f.add([{path:'plain.txt',file:file()}]);
 assert.equal(new URL(f.requests[0].url,'http://fixture').searchParams.has('parent'),false);f.manager.close();
});

test('cancel after body upload or during directory creation never claims host publication was undone',()=>{
 for(const directory of [false,true]){
  const f=fixture();const [task]=f.add([directory?{path:'Empty',directory:true}:{path:'file',file:file()}]);
  if(!directory)f.requests[0].upload.onprogress({loaded:task.size});
  f.manager.cancel(task);assert.equal(task.state,'failed');assert.equal(task.error,'unconfirmed');assert.equal(f.manager.paused,true);
  f.manager.close();
 }
});
