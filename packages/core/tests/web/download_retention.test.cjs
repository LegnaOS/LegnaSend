const { test } = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { diskFixture } = require('./disk_fixture.cjs');
const ls = require('../../assets/web/ls-cache.js');
const { Manager } = require('../../assets/web/persistent-downloads.js');
const DAY = 86400000, NOW = 1790100000000;
async function fixture({days=1,state='paused',age=3*DAY,batch=false}={}) {
  const f = diskFixture(); let policy=days;
  f.registry.retention = async function(value) { if(arguments.length)policy=value;return policy; };
  const id={taskId:randomUUID(),sourceId:'fixture',resourceId:'file',version:'"v1"',fileName:'source.bin',size:3,chunkSize:65536,createdUnixMs:NOW-age,sha256:null};
  const handle=f.handle(id.taskId+'.ls'); const cache=await new ls.Cache(handle,id).initialize();
  await cache.commit([{index:0,bytes:Buffer.from('abc')}]);
  const record={id:id.taskId,source:{kind:'web',fileId:'file',name:'source.bin',size:3},directory:f.directory,handle,identity:id,cacheName:handle.name,cacheMark:cache.stamp,state,updatedUnixMs:NOW-age};
  if(batch)record.batchId='batch-fixture';
  await f.registry.put(record);
  f.start=()=>new Manager({registry:f.registry,locks:f.locks,fetch:async()=>{throw Error('cleanup must not fetch source');},wallNow:()=>NOW});
  f.id=id.taskId;f.record=record;f.handleFile=handle;return f;
}
test('origin restoration applies chosen age policy to registered idle caches only',async()=>{
  const f=await fixture();const user=f.handle('unknown.ls');user.bytes=Buffer.from('user');
  const final=f.handle('published.txt');final.bytes=Buffer.from('final');
  const m=f.start();await m.ready;
  assert.equal(m.tasks.length,0);assert.equal(f.records.size,0);assert.equal(f.entries.has(f.handleFile.name),false);
  assert.deepEqual(user.bytes,Buffer.from('user'));assert.deepEqual(final.bytes,Buffer.from('final'));
  assert.deepEqual(m.cleanupReport,{removed:1,retained:0,failed:0,skipped:0});m.close();
});
test('default manual retention and recent, complete or batch tasks preserve files',async()=>{
  for(const options of [{days:0},{age:DAY/2},{state:'complete'},{batch:true}]){
    const f=await fixture(options);const m=f.start();await m.ready;
    assert.equal(f.records.size,1);assert.equal(f.entries.has(f.handleFile.name),true);m.close();
  }
});
test('active cross-tab lease and revoked directory permission retain without prompting',async()=>{
  for(const permission of [true,false]){
    const f=await fixture();let prompts=0;f.directory.requestPermission=async()=>{prompts++;throw Error('prompt forbidden');};
    if(permission)f.held.add('legnasend-download:'+f.id);else f.directory.permission='denied';
    const m=f.start();await m.ready;
    assert.equal(m.cleanupReport.retained,1);assert.equal(f.records.size,1);assert.equal(prompts,0);m.close();
  }
});
test('replaced or modified cache is preserved and reported as failed rather than freed',async()=>{
  const f=await fixture();f.handleFile.bytes=Buffer.from('user replaced content');f.handleFile.stamp++;
  const m=f.start();await m.ready;
  assert.equal(m.cleanupReport.failed,1);assert.equal(m.cleanupReport.removed,0);assert.equal(f.records.size,1);
  assert.deepEqual(f.handleFile.bytes,Buffer.from('user replaced content'));m.close();
});
test('record is re-read under lock so a just-completed task in another tab survives',async()=>{
  const f=await fixture();const acquire=f.locks.request;
  f.locks.request=async(name,options,body)=>acquire(name,options,async lock=>{
    const current=f.records.get(f.id);current.state='complete';await f.registry.put(current);return body(lock);
  });
  const m=f.start();await m.ready;
  assert.equal(m.cleanupReport.removed,0);assert.equal(f.entries.has(f.handleFile.name),true);m.close();
});
test('changing retention persists preference and immediately applies safe cleanup',async()=>{
  const f=await fixture({days:0});const m=f.start();await m.ready;assert.equal(f.records.size,1);
  await m.setRetention(1);assert.equal(await f.registry.retention(),1);assert.equal(f.records.size,0);
  await assert.rejects(m.setRetention(2),{code:'storage'});m.close();assert.equal(m.retentionTimer,null);
});
test('failed registry save does not enable a destructive policy',async()=>{
  const f=await fixture({days:0});const m=f.start();await m.ready;
  f.registry.retention=async()=>{throw Error('storage offline');};
  await assert.rejects(m.setRetention(1));assert.equal(m.retentionDays,0);assert.equal(f.records.size,1);m.close();
});

test('unset web policy defaults to exactly one hour, keeping the boundary-minus-one cache', async () => {
  for (const age of [3599999, 3600000]) {
    const f = await fixture({ age });
    f.registry.retention = async () => undefined;
    const m = f.start(); await m.ready;
    assert.equal(m.retentionDays, -2);
    assert.equal(f.records.size, age < 3600000 ? 1 : 0);
    assert.equal(f.entries.has(f.handleFile.name), age < 3600000);
    m.close();
  }
});

test('explicit manual and day policies survive the new default while invalid policy stays conservative', async () => {
  for (const policy of [0, 1, 7, 30, null, 'hour', -3]) {
    const f = await fixture({ age: 3600000 });
    f.registry.retention = async () => policy;
    const m = f.start(); await m.ready;
    assert.equal(m.retentionDays, [0, 1, 7, 30].includes(policy) ? policy : 0);
    assert.equal(f.records.size, 1);
    m.close();
  }
});

test('hour policy setter persists its explicit code and keeps active, finished and unknown files', async () => {
  const f = await fixture({ days: 0, age: 7200000 });
  const user = f.handle('user.ls'); user.bytes = Buffer.from('user-owned');
  const m = f.start(); await m.ready;
  f.held.add('legnasend-download:' + f.id);
  await m.setRetention(-2);
  assert.equal(await f.registry.retention(), -2);
  assert.equal(f.records.size, 1);
  f.held.delete('legnasend-download:' + f.id);
  f.records.get(f.id).state = 'complete';
  await m.cleanupExpired();
  assert.equal(f.records.size, 1);
  assert.deepEqual(user.bytes, Buffer.from('user-owned'));
  m.close();
});
