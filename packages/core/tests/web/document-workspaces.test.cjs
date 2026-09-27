'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');
const ui=require('../../assets/web/directories.js');
test('document workspaces fail closed for unsupported controls while filesystem defaults stay unchanged',()=>{
  for(const capability of ['archive','capture','events','preview','resume','state']){
    assert.equal(ui.workspaceCapability({backend:'documents'},capability),false);
    assert.equal(ui.workspaceCapability({backend:'documents',capabilities:{[capability]:true}},capability),true);
    assert.equal(ui.workspaceCapability({backend:'filesystem'},capability),true);
    assert.equal(ui.workspaceCapability({backend:'filesystem',capabilities:{[capability]:false}},capability),false);
  }
});
test('opaque document navigation keeps readable names and correct parent history',()=>{
  const first='11111111-1111-4111-8111-111111111111',second='22222222-2222-4222-8222-222222222222';
  let trail=ui.documentTrailFor([],first,'图片 / Photos','Documents');
  trail=ui.documentTrailFor(trail,second,'旅行','Documents');
  assert.deepEqual(trail.map(e=>e.name),['图片 / Photos','旅行']);
  assert.deepEqual(ui.documentTrailFor(trail,first,null,'Documents'),[trail[0]]);
  assert.deepEqual(ui.documentTrailFor(trail,'',null,'Documents'),[]);
  assert.equal(ui.documentTrailFor([],second,null,'Documents')[0].name,'Documents');
});
test('document rows use plain downloads and unknown sizes have no download link',()=>{
  const js=fs.readFileSync(path.join(__dirname,'../../assets/web/directories.js'),'utf8');
  assert.ok(js.includes("if(downloads&&!documents()&&!item.directory)"));
  assert.ok(js.includes("item.size===null?'—':formatSize(item.size)"));
  assert.ok(js.includes("item.downloadable===false){link.removeAttribute('href')"));
  assert.ok(js.includes("if(previewsAvailable&&capability('preview')"));
  assert.ok(js.includes("if(eventWatch&&capability('events')"));
});

 test('provider invalidation revisions are independent of listing stamps and never strong file versions',()=>{
  const response={refreshFromStart:true,stamp:'watch:1',observing:true};
  assert.equal(ui.documentRevision(null,response).changed,false);
  assert.equal(ui.documentRevision('watch:1',response).changed,false);
  assert.equal(ui.documentRevision('watch:0',response).changed,true);
  assert.equal(ui.documentRevision('expired:1',response).changed,true);
  assert.equal(ui.documentRevision(null,{...response,observing:false}).observing,false);
  for(const invalid of [{},{...response,refreshFromStart:false},{...response,stamp:''},{...response,observing:1}])assert.throws(()=>ui.documentRevision(null,invalid));
});
