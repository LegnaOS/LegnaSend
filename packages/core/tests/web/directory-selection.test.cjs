'use strict';
const test=require('node:test');const assert=require('node:assert/strict');
const {Selection,archiveSelectionUrl,messages}=require('../../assets/web/directories.js');
const route='/api/legnasend/v1/workspaces/workspace';
function validate(ids){return archiveSelectionUrl(route,3,'资料/子目录',ids);}
test('bulk ZIP query preserves opaque IDs and encoded filesystem IDs without joining paths',()=>{
  const ids=['opaque-id','中文 % #?&/+'];
  const url=new URL(validate(ids),'http://localhost');
  assert.equal(url.pathname,route+'/archive');
  assert.equal(url.searchParams.get('path'),'资料/子目录');
  assert.equal(url.searchParams.get('generation'),'3');
  assert.deepEqual(JSON.parse(url.searchParams.get('ids')),ids);
  assert.equal(new URL(validate([]),'http://localhost').searchParams.has('ids'),false);
});
test('selection retains bounded metadata across loaded windows, not file contents',()=>{
  const selection=new Selection();
  for(let i=0;i<128;i++)assert.equal(selection.toggle({id:String(i),name:'entry'+i,directory:i%2===0,bytes:Buffer.alloc(4096)},true,validate),true);
  assert.equal(selection.items.size,128);
  assert.deepEqual(Object.keys(selection.items.get('0')),['id','name','directory']);
  assert.equal(selection.toggle({id:'128'},true,validate),false);
  assert.equal(selection.toggle({id:'0',name:'updated'},true,validate),true);
  assert.equal(selection.toggle({id:'0'},false,validate),true);
  assert.equal(selection.toggle({id:'128'},true,validate),true);
  selection.clear();assert.equal(selection.items.size,0);
});
test('invalid/duplicate IDs and long encoded URLs fail before browser download',()=>{
  for(const ids of [['x','x'],[''],[null],Array.from({length:129},(_,i)=>String(i)),['中'.repeat(1000)]])assert.throws(()=>validate(ids),/selection-limit/);
  for(const generation of [0,-1,1.1,NaN,Infinity])assert.throws(()=>archiveSelectionUrl(route,generation,'',[]));
  const selection=new Selection();selection.toggle({id:'ok'},true,validate);
  assert.equal(selection.toggle({id:'中'.repeat(1000)},true,validate),false);
  assert.deepEqual(Array.from(selection.items.keys()),['ok']);
});
test('unreadable document files are excluded but directories can be selected',()=>{
  const selection=new Selection();
  assert.equal(selection.toggle({id:'virtual',directory:false,downloadable:false},true,validate),false);
  assert.equal(selection.toggle({id:'folder',directory:true,downloadable:false},true,validate),true);
});
test('selection controls have matching English and Chinese language labels',()=>{
  for(const locale of ['en','zh-CN','zh-TW','zh-HK'])for(const key of ['selectLoaded','clearSelection','downloadSelection','selected','selectionLimit','browserDownload','selectItem','selectionHint'])assert.ok(messages[locale][key]);
});

test('prepared archive selection requires an explicit capability; old filesystem default does not opt in',()=>{
 const {preparedArchiveCapability}=require('../../assets/web/directories.js');
 for(const workspace of[null,{}, {backend:'filesystem'}, {capabilities:{archive:true}}, {capabilities:{archiveSelection:false}}, {capabilities:{archiveSelection:'true'}}])assert.equal(preparedArchiveCapability(workspace),false);
 assert.equal(preparedArchiveCapability({capabilities:{archiveSelection:true}}),true);
 for(const locale of['en','zh-CN','zh-TW','zh-HK'])for(const key of['selectLoadedLarge','selectionHintLarge','selectionLimitLarge','archivePreparing','archiveCancelPrepare','archiveCancelDownload','archiveCancelled','archiveDownloadCancelled','archiveFailed','archiveExpired','archiveBusy','archiveTimeout','archiveCancelFailed'])assert.ok(messages[locale][key]);
});
