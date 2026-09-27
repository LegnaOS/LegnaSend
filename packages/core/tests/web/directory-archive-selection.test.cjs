'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {Selection,Controller,body,limits}=require('../../assets/web/directory-archive-selection.js');
const route='/api/legnasend/v1/workspaces/11111111-1111-4111-8111-111111111111';
const base='http://127.0.0.1:53317/design/';
const uuid=n=>'22222222-2222-4222-8222-'+String(n).padStart(12,'0');
const receipt=(n=1,count=2)=>({selection:uuid(n),selectedEntries:count,expiresIn:120,downloadUrl:route+'/archive?generation=7&selection='+uuid(n)});
const response=(value,status=200)=>new Response(JSON.stringify(value),{status});
function create(fetch,extra={}){const handed=[];const controller=new Controller({route,base,generation:7,path:'folder',fetch,handoff:url=>handed.push(url),...extra});return {controller,handed};}
const ids=['one','two'];

test('5000+ choices persist across page eviction without retaining page metadata or URL encoding',()=>{
 const selected=new Selection('文件目录');
 for(let page=0;page<60;page++)for(let i=0;i<100;i++)assert.ok(selected.toggle({id:'path/'+page+'/'+i+'文件🙂',name:'unretained',directory:false,body:'not copied'},true));
 assert.equal(selected.items.size,6000);assert.deepEqual(Object.keys(selected.items.values().next().value),['id']);
 const request=JSON.parse(selected.body());assert.equal(request.ids.length,6000);assert.equal(request.path,'文件目录');
 assert.ok(Buffer.byteLength(selected.body())<limits.bytes);assert.ok(selected.body().length>7800);
 selected.toggle({id:request.ids[0]},false);assert.equal(selected.items.size,5999);assert.ok(selected.toggle({id:request.ids[0]},true));
 selected.clear('new-folder');assert.equal(selected.items.size,0);assert.throws(()=>selected.body(),{code:'empty-selection'});
});
test('selection budget counts UTF-8 JSON bytes and rejects 20001st item without corrupting prior selection',()=>{
 const selected=new Selection('');for(let i=0;i<20000;i++)assert.ok(selected.toggle({id:String(i)},true));
 assert.equal(selected.toggle({id:'extra'},true),false);assert.equal(selected.items.size,20000);
 const wide=new Selection('');assert.equal(wide.toggle({id:'🙂'.repeat(300000)},true),true);
 assert.equal(wide.toggle({id:'🙂'.repeat(300001)},true),false);assert.equal(wide.items.size,1);
 assert.throws(()=>body('', ['same','same']),{code:'selection-limit'});assert.throws(()=>body('',[]),{code:'selection-limit'});
 assert.equal(wide.toggle({id:'blocked',downloadable:false,directory:false},true),false);
});
test('prepares JSON once and hands only a short same-origin URL to native browser download',async()=>{
 const calls=[];const {controller,handed}=create(async(url,init)=>{calls.push({url,init});return response(receipt());});
 const result=await controller.download(ids);
 assert.equal(result.handedOff,true);assert.equal(calls.length,1);assert.equal(calls[0].url,route+'/prepare-archive?generation=7');
 assert.deepEqual(JSON.parse(calls[0].init.body),{path:'folder',ids});assert.equal(calls[0].init.credentials,'same-origin');assert.equal(calls[0].init.redirect,'error');
 assert.deepEqual(handed,[receipt().downloadUrl]);assert.ok(handed[0].length<200);assert.equal(controller.snapshot().tickets.length,1);
 await controller.close();assert.equal(calls.length,1,'navigation must not revoke an already handed-off download');
});
test('same pending repeat click joins one scoped prepare, different selection reports busy',async()=>{
 let resolve,count=0;const {controller}=create(()=>{count++;return new Promise(done=>resolve=done);});
 const first=controller.download(ids);assert.strictEqual(controller.download(ids.slice()),first);
 await assert.rejects(controller.download(['different']),{code:'busy'});assert.equal(count,1);
 resolve(response(receipt()));await first;
});
test('closing or losing auth/generation scope during preparation revokes a late receipt and never downloads',async()=>{
 for(const mode of ['close','scope']){
  let resolve,current=true;const calls=[];const {controller,handed}=create((url,init)=>{calls.push({url,init});return url.includes('prepare-')?new Promise(done=>resolve=done):Promise.resolve(response({}));},{isCurrent:()=>current});
  const pending=controller.download(ids);if(mode==='close')await controller.close();else current=false;
  assert.equal(calls[0].init.signal.aborted,false);resolve(response(receipt()));await assert.rejects(pending,{code:'stale'});
  assert.deepEqual(handed,[]);assert.deepEqual(JSON.parse(calls[1].init.body),{selection:uuid(1)});assert.equal(calls[1].url,route+'/cancel-archive?generation=7');assert.equal(calls[1].init.keepalive,true);
 }
});
test('cancel pending then new selection keeps both receipts scoped and never revokes the new ticket',async()=>{
 const waiting=[],cancelled=[];const {controller,handed}=create((url,init)=>url.includes('prepare-')?new Promise(done=>waiting.push(done)):(cancelled.push(JSON.parse(init.body).selection),Promise.resolve(response({}))));
 const old=controller.download(ids);await controller.cancel();const fresh=controller.download(['new']);
 waiting[1](response(receipt(2,1)));await fresh;waiting[0](response(receipt(1)));await assert.rejects(old,{code:'stale'});
 assert.deepEqual(cancelled,[uuid(1)]);assert.deepEqual(handed,[receipt(2,1).downloadUrl]);assert.equal(controller.snapshot().tickets[0].selection,uuid(2));
});
test('timeout aborts preparation; even an abort-ignoring late transport receipt is revoked',async()=>{
 let resolve,signal;const cancelled=[];const {controller,handed}=create((url,init)=>{if(url.includes('prepare-')){signal=init.signal;return new Promise(done=>resolve=done);}cancelled.push(JSON.parse(init.body).selection);return Promise.resolve(response({}));},{timeout:10});
 const pending=controller.download(ids);await assert.rejects(pending,{code:'timeout'});assert.equal(signal.aborted,true);
 resolve(response(receipt()));await new Promise(done=>setTimeout(done,0));assert.deepEqual(cancelled,[uuid(1)]);assert.deepEqual(handed,[]);
});
test('at most four abandoned pending requests retain resources; cancelling never opens unlimited preparation slots',async()=>{
 const waiting=[];const {controller}=create(url=>url.includes('prepare-')?new Promise(done=>waiting.push(done)):Promise.resolve(response({})));
 const results=[];for(let i=0;i<4;i++){results.push(controller.download(ids).catch(e=>e.code));await controller.cancel();}
 await assert.rejects(controller.download(ids),{code:'busy'});
 waiting.forEach((done,i)=>done(response(receipt(i+1))));assert.deepEqual(await Promise.all(results),['stale','stale','stale','stale']);
});
test('admission expiry retains handed-off cancellation controls; new request evicts only bounded oldest metadata',async()=>{
 let clock=1000,count=0;const {controller}=create(async()=>response(receipt(++count)),{now:()=>clock});
 for(let i=0;i<4;i++)await controller.download(ids);await assert.rejects(controller.download(ids),{code:'busy'});
 clock=120999;assert.equal(controller.snapshot().tickets.length,4);clock=121000;assert.equal(controller.snapshot().tickets.length,4);
 await controller.download(ids);assert.equal(count,5);assert.equal(controller.snapshot().tickets.length,4);assert.ok(!controller.snapshot().tickets.some(t=>t.selection===uuid(1)));
});
test('explicit cancellation is ticket-local, coalesces repeats, and reports failed revocation for retry',async()=>{
 let fail=true,cancels=0;const {controller}=create(async(url)=>{if(url.includes('prepare-'))return response(receipt());cancels++;return response({},fail?503:200);});
 await controller.download(ids);await assert.rejects(controller.cancel(uuid(1)),{code:'cancel-failed',status:503});assert.equal(controller.snapshot().tickets.length,1);
 fail=false;await Promise.all([controller.cancel(uuid(1)),controller.cancel(uuid(1))]);assert.equal(cancels,2);assert.equal(controller.snapshot().tickets.length,0);assert.equal(await controller.cancel(uuid(9)),false);
});
test('invalid cross-origin, wrong-generation, duplicate query or mismatched-count receipt is never handed off and is revoked',async()=>{
 for(const patch of [{downloadUrl:'https://other.invalid/archive'},{downloadUrl:receipt().downloadUrl+'&generation=7'},{downloadUrl:receipt().downloadUrl.replace('generation=7','generation=8')},{downloadUrl:receipt().downloadUrl+'&ids=stolen'},{selectedEntries:1},{expiresIn:121}]){
  const calls=[];const {controller,handed}=create(async(url,init)=>{calls.push({url,init});return response(url.includes('prepare-')?{...receipt(),...patch}:{});});
  await assert.rejects(controller.download(ids),{code:'invalid-receipt'});assert.deepEqual(handed,[]);assert.equal(calls.length,2);assert.deepEqual(JSON.parse(calls[1].init.body),{selection:uuid(1)});
 }
});
test('HTTP authorization/expiry/quota errors are not blindly retried and receipt JSON has an 8192-byte limit',async()=>{
 for(const status of[400,401,403,409,410,413,429]){let calls=0;const {controller}=create(async()=>{calls++;return response({},status);});await assert.rejects(controller.download(ids),{code:'prepare-failed',status});assert.equal(calls,1);}
 const {controller}=create(async()=>new Response(' '.repeat(8193)));await assert.rejects(controller.download(ids),{code:'invalid-receipt'});
});
test('handoff exception revokes its ticket, and caller mutation cannot change prepared selection cardinality',async()=>{
 let resolve;const calls=[];const {controller}=create((url)=>{calls.push(url);return url.includes('prepare-')?new Promise(done=>resolve=done):Promise.resolve(response({}));},{handoff:()=>{throw new Error('browser handoff failed');}});
 const chosen=ids.slice(),pending=controller.download(chosen);chosen.pop();resolve(response(receipt()));await assert.rejects(pending,/browser handoff failed/);assert.equal(calls.length,2);assert.equal(controller.snapshot().tickets.length,0);
});
test('foreign scope is rejected before any request',()=>{assert.throws(()=>create(()=>{}, {route:'https://other.invalid'+route}),{code:'invalid-scope'});assert.throws(()=>create(()=>{}, {generation:0}),{code:'invalid-scope'});});
test('admission expiry never cancels a slow admitted ZIP and its explicit cancel remains available',async()=>{
 let clock=0;const calls=[];const {controller}=create(async(url,init)=>{calls.push({url,init});return response(url.includes('prepare-')?receipt():{});},{now:()=>clock});
 await controller.download(ids);clock=3600000;assert.equal(controller.snapshot().tickets.length,1);assert.equal(calls.length,1);
 await controller.cancel(uuid(1));assert.equal(calls.length,2);assert.deepEqual(JSON.parse(calls[1].init.body),{selection:uuid(1)});
});

test('rapid directory controller replacement shares four actual preparation slots until late work settles',async()=>{
 const waiting=[],results=[];
 for(let i=0;i<4;i++){const {controller}=create(url=>url.includes('prepare-')?new Promise(done=>waiting.push(done)):Promise.resolve(response({})),{path:'folder-'+i});results.push(controller.download(ids).catch(e=>e.code));await controller.close();}
 const {controller}=create(async()=>response(receipt(9)));await assert.rejects(controller.download(ids),{code:'busy'});
 waiting.forEach((done,i)=>done(response(receipt(i+1))));assert.deepEqual(await Promise.all(results),['stale','stale','stale','stale']);
 await controller.download(ids);assert.equal(controller.snapshot().tickets.length,1);
});

test('failed replacement admission preserves every old cancellation handle, including expired active ZIPs',async()=>{
 let clock=0,count=0,fail=false;const calls=[];const {controller}=create(async(url,init)=>{calls.push({url,init});if(url.includes('cancel-'))return response({});if(fail)return response({},429);return response(receipt(++count));},{now:()=>clock});
 for(let i=0;i<4;i++)await controller.download(ids);clock=121000;fail=true;await assert.rejects(controller.download(ids),{status:429});
 assert.deepEqual(controller.snapshot().tickets.map(t=>t.selection),[1,2,3,4].map(uuid));
 await controller.cancel(uuid(1));assert.deepEqual(JSON.parse(calls.at(-1).init.body),{selection:uuid(1)});
});

test('real server rounded remaining admission TTL of 119 seconds is accepted without extending it',async()=>{
 const {controller,handed}=create(async()=>response({...receipt(),expiresIn:119}),{now:()=>1000});
 const ticket=await controller.download(ids);assert.equal(ticket.expiresAt,120000);assert.equal(handed.length,1);
 for(const expiresIn of[0,-1,1.5,121,'119']){const invalid=create(async(url)=>response(url.includes('prepare-')?{...receipt(),expiresIn}:{})).controller;await assert.rejects(invalid.download(ids),{code:'invalid-receipt'});}
});

test('select all walks every page without retaining pages or altering the previous choice',async()=>{
 const {collectAll}=require('../../assets/web/directory-archive-selection.js');
 const previous=new Selection('folder');previous.toggle({id:'old',directory:false},true);
 const calls=[],progress=[];
 const result=await collectAll({generation:7,path:'folder',createSelection:()=>new Selection('folder'),progress:n=>progress.push(n),page:async cursor=>{
  calls.push(cursor);const index=cursor===null?0:Number(cursor);
  return {generation:7,path:'folder',stamp:'stable',cursor:index<2?String(index+1):null,entries:Array.from({length:100},(_,n)=>({id:String(index*100+n),name:n+'.txt',directory:false}))};
 }});
 assert.equal(result.items.size,300);assert.deepEqual(calls,[null,'1','2']);assert.deepEqual(progress,[100,200,300]);assert.deepEqual([...previous.items.keys()],['old']);
});
test('select all cancellation, page failure, stale scope and over-budget enumeration never yield partial selection',async()=>{
 const {collectAll}=require('../../assets/web/directory-archive-selection.js');
 const row={id:'first',name:'first',directory:false};
 const page={generation:7,path:'folder',stamp:'s',cursor:'next',entries:[row]};
 const base={generation:7,path:'folder',createSelection:()=>new Selection('folder')};
 const cancel=new AbortController();
 await assert.rejects(collectAll({...base,signal:cancel.signal,page:async()=>{cancel.abort();return page;}}),{code:'selection-cancelled'});
 let calls=0;await assert.rejects(collectAll({...base,page:async()=>{if(calls++)throw Error('offline');return page;}}),/offline/);
 calls=0;await assert.rejects(collectAll({...base,page:async()=>({...page,stamp:calls++?'changed':'s'})}),{code:'selection-changed'});
 await assert.rejects(collectAll({...base,page:async()=>({...page,generation:8})}),{code:'selection-changed'});
 await assert.rejects(collectAll({...base,page:async()=>({...page,filter:'limited'})}),{code:'selection-changed'});
 await assert.rejects(collectAll({...base,page:async()=>page}),{code:'selection-changed'});
 calls=0;await assert.rejects(collectAll({...base,page:async()=>({generation:7,path:'folder',stamp:'s',cursor:String(++calls),entries:Array.from({length:1000},(_,n)=>({id:calls+'-'+n,name:'x',directory:false}))})}),{code:'selection-limit'});
 let now=0;await assert.rejects(collectAll({...base,now:()=>now,timeout:10,page:async()=>{now=11;return page;}}),{code:'selection-timeout'});
});
test('select all respects unavailable document entries and the old host 128-item limit atomically',async()=>{
 const {collectAll}=require('../../assets/web/directory-archive-selection.js');
 const {Selection:Legacy,archiveSelectionUrl}=require('../../assets/web/directories.js');
 const base={generation:7,path:'',page:async()=>({generation:7,path:'',stamp:'s',cursor:null,entries:[{id:'a',name:'a',directory:false,downloadable:false},{id:'b',name:'b',directory:false,downloadable:true},{id:'c',name:'c',directory:true}]})};
 const selected=await collectAll({...base,documents:true,createSelection:()=>new Selection('')});assert.deepEqual([...selected.items.keys()],['b','c']);
 await assert.rejects(collectAll({...base,createSelection:()=>new Legacy(),validate:ids=>archiveSelectionUrl('/route',7,'',ids),page:async()=>({generation:7,path:'',stamp:'s',cursor:null,entries:Array.from({length:129},(_,n)=>({id:String(n),name:'x',directory:false}))})}),{code:'selection-limit'});
});
