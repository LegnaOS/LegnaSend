'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const api=require('../../assets/web/directory-window.js');
const page=(start,count=100,name='file')=>({entries:Array.from({length:count},(_,i)=>({id:String(start+i),name:name+(start+i),directory:false,size:1})),cursor:'next-'+start});
test('100k entries retain a bounded metadata window and bounded history',()=>{
  const state=new api.Window();
  for(let n=0;n<1000;n++){state.append(page(n*100),'cursor-'+n);assert.ok(state.length<=1000);assert.ok(state.bytes<=api.limits.bytes);assert.ok(state.pages.length<=16);assert.ok(state.history.length<=64);}
  assert.equal(state.offset,99000);assert.equal(state.items()[0].id,'99000');
  const previous=state.previous();assert.deepEqual(previous,{start:98900,cursor:'cursor-989'});
  state.reset(previous.start,state.history);state.append(page(98900),previous.cursor);assert.equal(state.items()[0].id,'98900');assert.equal(state.length,100);
});
test('metadata byte and empty-page budgets apply independently of item count',()=>{
  const state=new api.Window();for(let i=0;i<20;i++)state.append(page(i*100,100,'字'.repeat(4096)),'token-'+i);
  assert.ok(state.bytes<=api.limits.bytes);assert.ok(state.length<1000);
  state.reset();for(let i=0;i<10000;i++)state.append(page(0,0),'token-'+i);
  assert.equal(state.pages.length,0);assert.equal(state.history.length,0);assert.equal(state.length,0);
});
test('invalid or over-budget pages never enter the retained window',()=>{
  const state=new api.Window();assert.throws(()=>state.append(page(0,101),null));
  assert.throws(()=>state.append(page(0,100,'x'.repeat(30000)),null));
  const bad=page(0,1);bad.entries[0].size=-1;assert.throws(()=>state.append(bad,null));assert.equal(state.length,0);
});
test('prefetch responds to forward speed/latency within two screens and polling backs off',()=>{
  assert.equal(api.prefetchDistance(500,-1,500),312);assert.ok(api.prefetchDistance(500,1,500)>312);assert.equal(api.prefetchDistance(500,100,90000),1000);
  assert.equal(api.delay(0,100,0),5000);assert.equal(api.delay(10,100,0),30000);assert.equal(api.delay(0,100,2),20000);assert.equal(api.delay(0,90000,0),30000);
});
test('visible probes cap count and encoded query size including deep paths',()=>{
  const items=page(0).entries;assert.equal(api.probeIds(items,4,100).length,64);assert.equal(api.probeIds(items,4,100,0).length,0);
  items.forEach(v=>v.id='é'.repeat(200));const ids=api.probeIds(items,0,100);assert.ok(encodeURIComponent(ids.join(',')).length<=6000);assert.ok(ids.length<64);
});

test('empty scan continuations never evict rare matching entries',()=>{
  const state=new api.Window();state.append(page(4,1,'needle'),null);
  for(let i=0;i<10000;i++)state.append(page(0,0),'token-'+i);
  assert.equal(state.items().length,1);assert.equal(state.items()[0].name,'needle4');
  assert.equal(state.pages.length,1);assert.equal(state.offset,0);
});

test('provider unknown sizes remain visible only as explicit non-downloadable entries',()=>{
  const state=new api.Window(),unknown=page(0,1);unknown.entries[0].size=null;
  assert.throws(()=>state.append(unknown,null));
  unknown.entries[0].downloadable=false;state.append(unknown,null);
  assert.equal(state.items()[0].size,null);
  const directory=page(1,1);directory.entries[0].directory=true;directory.entries[0].size=null;state.append(directory,null);
  assert.equal(state.length,2);
});
