const {test}=require('node:test'),assert=require('node:assert/strict');
const {Manager,requestId}=require('../../assets/web/directory-upload.js');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const target={id:'ws',slug:'workspace',generation:9,name:'Workspace',path:'folder',allowUpload:true,uploadApproval:true,authorized:true};
const token='ab'.repeat(32);
function fixture(){
 const http=[],xhr=[],events=[];let id=0;
 class Xhr{constructor(){this.upload={};this.headers={};xhr.push(this);}open(method,url){this.url=url;}setRequestHeader(k,v){this.headers[k]=v;}send(body){this.body=body;}abort(){this.onabort();}respond(status){this.status=status;this.responseText='{}';this.onload();}}
 const manager=new Manager({requestId:()=>`00000000-0000-4000-8000-${String(++id).padStart(12,'0')}`,fetch:(url,options)=>new Promise((resolve,reject)=>http.push({url,options,resolve,reject})),xhrFactory:()=>new Xhr(),onAuth:()=>events.push('auth'),onInvalid:()=>events.push('invalid')});
 manager.setContext(target);
 return {manager,http,xhr,events,add:(count=1)=>manager.enqueue(Array.from({length:count},(_,i)=>({path:`${i}.txt`,file:{name:`${i}.txt`,size:3}})),target),reply:(index,status=200,body={token})=>http[index].resolve(new Response(JSON.stringify(body),{status}))};
}
test('one immutable approval manifest gates 5000 files; original bodies begin only after approval',async()=>{
 const f=fixture();f.add(5000);assert.equal(f.http.length,1);assert.equal(f.xhr.length,0);
 const payload=JSON.parse(f.http[0].options.body);assert.equal(payload.files.length,5000);assert.equal(payload.generation,9);assert.equal(payload.files[4999].path,'folder/4999.txt');
 assert.ok(f.manager.tasks.every(t=>t.state==='approving'));f.reply(0);await tick();assert.equal(f.xhr.length,2);
 assert.equal(f.xhr[0].headers['X-LegnaSend-Upload-Token'],token);assert.equal(f.xhr[0].body,f.manager.tasks[0].file);
 assert.ok(!f.xhr[0].url.includes(token));f.manager.cancelAll();await tick();assert.equal(f.http.length,2);assert.ok(f.http[1].url.endsWith('/cancel-upload-approval'));f.reply(1);
});
test('denied approval does not revoke workspace; retry creates a fresh one-file manifest',async()=>{
 const f=fixture();const tasks=f.add(3);f.reply(0,403,{});await tick();assert.equal(f.xhr.length,0);assert.equal(f.manager.allowed(),true);
 assert.ok(tasks.every(t=>t.error==='approvalDenied'));assert.deepEqual(f.events,[]);
 f.manager.retry(tasks[1],'renamed.txt');assert.equal(f.http.length,2);const retry=JSON.parse(f.http[1].options.body);
 assert.equal(retry.files.length,1);assert.equal(retry.files[0].path,'folder/renamed.txt');assert.notEqual(retry.requestId,JSON.parse(f.http[0].options.body).requestId);
 f.reply(1);await tick();assert.equal(f.xhr.length,1);assert.equal(f.xhr[0].body,tasks[1].file);f.manager.close();await tick();f.reply(2);
});
test('cancel before acceptance revokes exact batch and late acceptance never resurrects tasks',async()=>{
 const f=fixture();const tasks=f.add(4);f.manager.cancel(tasks[1]);await tick();assert.ok(f.http[0].options.signal.aborted);
 assert.ok(tasks.every(t=>t.state==='cancelled'));assert.equal(f.http.length,2);assert.equal(JSON.parse(f.http[1].options.body).requestId,JSON.parse(f.http[0].options.body).requestId);
 f.reply(1);f.reply(0);await tick();assert.equal(f.xhr.length,0);assert.ok(tasks.every(t=>t.state==='cancelled'));
});
test('cancel during token body parsing cannot revive a batch',async()=>{
 const f=fixture();f.add();let body;
 f.http[0].resolve({ok:true,json:()=>new Promise(resolve=>body=resolve)});await tick();f.manager.cancelAll();await tick();body({token});f.reply(1);await tick();assert.equal(f.xhr.length,0);
});
test('428 upload response requires a fresh approval, never reuses consumed grant',async()=>{
 const f=fixture();const tasks=f.add(3);f.reply(0);await tick();f.xhr[0].respond(428);assert.equal(tasks[0].error,'approvalRequired');assert.equal(f.manager.allowed(),true);
 f.manager.retry(tasks[0]);assert.equal(f.http.length,2);f.reply(1,200,{token:'cd'.repeat(32)});await tick();
 assert.ok(f.xhr.some(x=>x.headers['X-LegnaSend-Upload-Token']==='cd'.repeat(32)));f.manager.close();await tick();for(let i=2;i<f.http.length;i++)f.reply(i);
});
test('permission/generation change revokes pending approvals and suppresses late responses',async()=>{
 for(const meta of [{...target,generation:10},{...target,allowUpload:false},{...target,uploadApproval:false}]){
  const f=fixture();f.add(2);f.manager.observe(meta);await tick();assert.ok(!f.manager.allowed());f.reply(0);f.reply(1);await tick();assert.equal(f.xhr.length,0);
 }
});
test('expiry and malformed tokens stay local failures without disabling workspace',async()=>{
 for(const [status,body,error]of [[408,{},'approvalExpired'],[200,{token:'bad'},'response'],[429,{},'busy']]){
  const f=fixture();f.add();f.reply(0,status,body);await tick();assert.equal(f.manager.tasks[0].error,error);assert.equal(f.manager.allowed(),true);assert.equal(f.xhr.length,0);
 }
});
test('HTTP-compatible UUID generation uses cryptographic randomness without randomUUID',()=>{
 const descriptor=Object.getOwnPropertyDescriptor(globalThis,'crypto');
 Object.defineProperty(globalThis,'crypto',{configurable:true,value:{getRandomValues:bytes=>require('node:crypto').randomFillSync(bytes)}});
 try{const ids=Array.from({length:100},()=>requestId());assert.equal(new Set(ids).size,100);assert.ok(ids.every(id=>/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id)));}
 finally{Object.defineProperty(globalThis,'crypto',descriptor);}
});
test('missing secure randomness cannot leave sendable unapproved queue entries',()=>{
 const f=fixture();f.manager.options.requestId=()=>{throw Error('unsupported');};const tasks=f.add(2);
 assert.ok(tasks.every(t=>t.state==='failed'&&t.error==='unavailable'));f.manager.resume();assert.equal(f.xhr.length,0);assert.equal(f.http.length,0);
});

test('document approval and retry remain bound to the originally selected parent after navigation',async()=>{
 const f=fixture(),parent='11111111-1111-4111-8111-111111111111';
 const documentTarget={...target,backend:'documents',path:parent};f.manager.setContext(documentTarget);
 const [task]=f.manager.enqueue([{path:'child/file.txt',file:{name:'file.txt',size:3}}],documentTarget);
 let request=JSON.parse(f.http[0].options.body);assert.equal(request.parent,parent);assert.equal(request.files[0].path,'child/file.txt');
 f.reply(0,403,{});await tick();f.manager.setContext({...documentTarget,path:'another-parent'});f.manager.retry(task,'renamed.txt');
 request=JSON.parse(f.http[1].options.body);assert.equal(request.parent,parent);assert.equal(request.files[0].path,'child/renamed.txt');
 f.reply(1);await tick();assert.equal(new URL(f.xhr[0].url,'http://fixture').searchParams.get('parent'),parent);
 f.manager.close();await tick();for(let i=2;i<f.http.length;i++)f.reply(i);
});
