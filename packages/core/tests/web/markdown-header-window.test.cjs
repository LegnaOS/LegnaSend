'use strict';
const {test}=require('node:test'), assert=require('node:assert/strict');
const {Stream,tokens,windowLimit}=require('../../assets/web/markdown-blocks.js');
const {Source,Index}=require('../../assets/web/markdown-stream.js');
function collect(source,step=65536){
 const stream=new Stream(),blocks=[];let retained=0;
 for(let start=0;start<source.length;start+=step){
  blocks.push(...stream.feed(source.slice(start,start+step),start+step>=source.length).blocks);
  retained=Math.max(retained,stream.pending.length);
 }
 assert.equal(stream.pending,'');return{blocks,retained};
}
function headerSource(source,blocks){
 const windows=blocks.filter(b=>b.fragment?.kind==='table-header-source');
 assert.ok(windows.length>1,'oversized header must have bounded source windows');
 assert.ok(windows.every(b=>b.end-b.start<=windowLimit));
 const chunks=windows.map(b=>{
  const parsed=tokens(source.slice(b.start,b.end),{},b.fragment);
  const value=parsed.at(-1).tokens[0].text;
  assert.equal(parsed.at(-1).tokens[0].type,'literal');
  assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(value));
  return value;
 });
 return chunks.join('');
}
function assertRows(source,blocks,align){
 const tables=blocks.filter(b=>b.fragment?.kind==='table').map(b=>tokens(source.slice(b.start,b.end),{},b.fragment)[0]);
 assert.ok(tables.length>0,'following bounded rows recover table semantics');
 for(const table of tables){assert.equal(table.type,'table');assert.deepEqual(table.header,[]);assert.deepEqual(table.align,align);}
 const rows=tables.flatMap(t=>t.rows);assert.equal(rows.length,2);
 assert.equal(rows[0][0].tokens[0].type,'strong');assert.equal(rows[0][0].tokens[0].text,'later');
 assert.equal(rows[1][1].tokens[0].type,'codespan');assert.equal(rows[1][1].tokens[0].text,'tail');
 assert.equal(blocks.at(-1).type,'heading');
}
const giant='中文🙂 **strong across windows** &amp; text '.repeat(10000);
const body='| **later** | cell |\n| final | `tail` |\n\n# end\n';
test('giant first header line keeps all source and restores aligned subsequent rows without synthetic headings',()=>{
 for(const prefix of ['| ','Heading | ']){
  const header=prefix+giant+' | value |\n';
  const delimiter=prefix==='| '?'|:---|---:|\n':'|:---|---:|---|\n';
  const source=header+delimiter+body;
  for(const step of[16384,39173,65536]){
   const{blocks,retained}=collect(source,step);assert.ok(retained<=65536);
   assert.equal(headerSource(source,blocks),header+delimiter);
   assertRows(source,blocks,prefix==='| '?['left','right']:['left','right',null]);
  }
 }
});
test('giant delimiter and bounded header preserve full delimiter source plus column alignment',()=>{
 const header='| **Key** | Value |\n',delimiter='|:'+ '-'.repeat(90000)+'|'+ '-'.repeat(100000)+':|\n';
 const source=header+delimiter+body;
 for(const step of[16384,65536]){
  const {blocks,retained}=collect(source,step);assert.ok(retained<=65536);
  assert.equal(headerSource(source,blocks),header+delimiter);assertRows(source,blocks,['left','right']);
 }
});
test('single-column bounded first line with huge delimiter is not rejected by a partially valid prefix',()=>{
 const header='| Key |\n',delimiter='|'+ '-'.repeat(170000)+':|\n';
 const source=header+delimiter+'| **later** |\n\n# end\n';
 for(const step of[16384,65536]){
  const{blocks,retained}=collect(source,step);assert.ok(retained<=65536);
  assert.equal(headerSource(source,blocks),header+delimiter);
  const row=blocks.find(b=>b.fragment?.kind==='table');assert.ok(row);
  const table=tokens(source.slice(row.start,row.end),{},row.fragment)[0];
  assert.deepEqual(table.header,[]);assert.deepEqual(table.align,['right']);
  assert.equal(table.rows[0][0].tokens[0].type,'strong');assert.equal(blocks.at(-1).type,'heading');
 }
});
test('escaped and even-backslash pipes preserve actual column count across header source windows',()=>{
 const header='| escaped \\| '+giant+' | even \\\\| third |\n';
 const delimiter='|:---|:---:|---:|\n', source=header+delimiter+body;
 for(const step of[16383,65536]){
  const {blocks}=collect(source,step);assert.equal(headerSource(source,blocks),header+delimiter);
  assertRows(source,blocks,['left','center','right']);
 }
});
test('invalid delimiter remains complete source without falsely upgrading later text into a table',()=>{
 const header='| '+giant+' | value |\n',delimiter='| not a delimiter | nope |\n';
 const source=header+delimiter+'\nordinary **text**\n\n# end\n';
 const{blocks,retained}=collect(source,39173);assert.ok(retained<=65536);
 assert.equal(headerSource(source,blocks),header);
 const delimiterBlock=blocks.find(b=>b.start===header.length);assert.ok(delimiterBlock);
 assert.equal(delimiterBlock.type,'paragraph');
 assert.equal(source.slice(delimiterBlock.start,delimiterBlock.end).trimEnd(),delimiter.trimEnd());
 assert.equal(tokens(source.slice(delimiterBlock.start,delimiterBlock.end),{},delimiterBlock.fragment)[0].tokens[0].text,delimiter.trimEnd());
 assert.ok(!blocks.some(b=>b.fragment?.kind==='table'));assert.equal(blocks.at(-1).type,'heading');
});
test('evicted section replay in the middle of a huge header matches original ranges and metadata',async()=>{
 const source='| '+giant.repeat(25)+' | value |\n|:---|---:|\n'+body;
 const rows=[];source.split('\n').forEach((line,index)=>{
  for(let start=0;start<line.length||start===0;start+=8192)rows.push({text:line.slice(start,start+8192),number:index+1});
 });
 const reader={rows:rows.length,eof:true,ensureRows:async()=>{},getRows:async(start,count)=>rows.slice(start,start+count)};
 const stream=new Stream();let replay;
 const worker={call:async message=>{
  if(message.op==='feed')return stream.feed(message.text,message.final);
  if(message.op==='replayStart'){replay=new Stream(message.start,message.context);return{};}
  if(message.op==='replay')return replay.feed(message.text,message.final);
  throw Error(message.op);
 }};
 const index=new Index(new Source(reader),worker);
 const first=await index.get(0),second=await index.get(1);
 for(let n=2;!index.done;n++)await index.get(n);
 assert.ok(index.sections.length>5);assert.ok(index.detail.size<=4);
 assert.deepEqual(await index.get(0),first);assert.deepEqual(await index.get(1),second);
 for(const section of index.sections)assert.ok(JSON.stringify(section.context).length<16384);
});
test('giant no-pipe single-column first header line restores following single-column table',()=>{
 const header='Heading '+giant+' tail\n',delimiter='|---:|\n';
 const source=header+delimiter+'| **later** |\n\n# end\n';
 for(const step of[16384,39173,65536]){
  const{blocks,retained}=collect(source,step);assert.ok(retained<=65536);
  assert.equal(headerSource(source,blocks),header+delimiter);
  const row=blocks.find(b=>b.fragment?.kind==='table');assert.ok(row);
  const table=tokens(source.slice(row.start,row.end),{},row.fragment)[0];
  assert.deepEqual(table.header,[]);assert.deepEqual(table.align,['right']);
  assert.equal(table.rows[0][0].tokens[0].type,'strong');assert.equal(blocks.at(-1).type,'heading');
 }
});
