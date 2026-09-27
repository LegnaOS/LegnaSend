'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {Stream,tokens,windowLimit}=require('../../assets/web/markdown-blocks.js');
const {Source,Index}=require('../../assets/web/markdown-stream.js');
function collect(source,step=65536){const stream=new Stream(),blocks=[];let retained=0;for(let start=0;start<source.length;start+=step){blocks.push(...stream.feed(source.slice(start,start+step),start+step>=source.length).blocks);retained=Math.max(retained,stream.pending.length);}assert.equal(stream.pending,'');return{blocks,retained};}
function literal(source,blocks,kind){return blocks.filter(b=>b.fragment?.kind===kind).map(b=>tokens(source.slice(b.start,b.end),{},b.fragment).at(-1).tokens[0].text).join('');}
const giant='text 中文🙂 &amp; <script> **cross-window** '.repeat(30000);
test('single multi-megabyte ordered item remains exact source and following items resume semantic numbering',()=>{
 const item='1. **'+giant+'**\n';const source='1. **before**\n'+item+'1. **after**\n\n# end\n';
 for(const step of[16384,39173,65536]){const {blocks,retained}=collect(source,step);assert.ok(retained<=65536);const windows=blocks.filter(b=>b.fragment?.kind==='list-item-source');assert.ok(windows.length>20);assert.ok(windows.every(b=>b.end-b.start<=windowLimit));assert.equal(windows.filter(b=>b.fragment.first).length,1);assert.equal(literal(source,blocks,'list-item-source'),item);const semantic=blocks.filter(b=>b.type==='list'&&b.fragment?.kind!=='list-item-source').map(b=>tokens(source.slice(b.start,b.end),{},b.fragment)[0]);assert.equal(semantic[0].items[0].tokens[0].tokens[0].type,'strong');assert.equal(semantic.at(-1).start,3);assert.equal(semantic.at(-1).items[0].tokens[0].tokens[0].text,'after');assert.equal(blocks.at(-1).type,'heading');}
});
test('multiline giant item and nested fences preserve all indentation and bound physical height',()=>{
 const item='- start\n'+('  ```md\n  > quoted\n\n  - inside fence\n  ```\n\n').repeat(18000);
 const source=item+'- next\n\n# end\n';const {blocks}=collect(source,39173);const windows=blocks.filter(b=>b.start<item.length);assert.equal(windows.map(b=>source.slice(b.start,b.end)).join('').trimEnd(),item.trimEnd());assert.ok(windows.some(b=>b.fragment?.kind==='list-item-children'));assert.ok(windows.every(b=>source.slice(b.start,b.end).split('\n').length<=257));assert.equal(blocks.at(-1).type,'heading');
});
test('giant table cells keep every source character; bounded header and later rows retain table semantics',()=>{
 const header='| **Key** | Value |\n|:---|---:|\n',row='| '+giant+' | escaped \\| tail |\n';
 for(const before of['','| first | **normal** |\n']){const source=header+before+row+'| final | **styled** |\n\n# end\n';for(const step of[16384,65536]){const{blocks,retained}=collect(source,step);assert.ok(retained<=65536);assert.equal(literal(source,blocks,'table-row-source'),row);const windows=blocks.filter(b=>b.fragment?.kind==='table-row-source');assert.equal(windows.filter(b=>b.fragment.first).length,1);assert.ok(windows.every(b=>b.end-b.start<=windowLimit+4096));const last=blocks.filter(b=>b.fragment?.kind==='table').at(-1);const table=tokens(source.slice(last.start,last.end),{},last.fragment)[0];assert.deepEqual(table.align,['left','right']);assert.equal(table.rows.at(-1)[1].tokens[0].type,'strong');assert.equal(table.rows.at(-1)[1].tokens[0].text,'styled');assert.equal(blocks.at(-1).type,'heading');}}
});
test('EOF without newline and surrogate pairs never lose or corrupt giant item/cell content',()=>{
 for(const[source,kind,expected]of[['1. '+giant,'list-item-source','1. '+giant],['| A | B |\n|---|---|\n| '+giant+' | tail |','table-row-source','| '+giant+' | tail |']]){const {blocks}=collect(source,32767);assert.equal(literal(source,blocks,kind),expected);for(const block of blocks){const text=tokens(source.slice(block.start,block.end),{},block.fragment).at(-1).tokens[0].text;assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(text));}}
});
test('oversized table row does not swallow a following large heading as another row',()=>{
 const source='| A | B |\n|---|---|\n| '+giant+' | tail |\n\n# '+('heading '.repeat(3000))+'\n';const{blocks}=collect(source);assert.equal(blocks.at(-1).type,'heading');assert.match(source.slice(blocks.at(-1).start),/^# heading/);
});
test('evicted sections replay from inside a single giant item or table row without altered boundaries',async()=>{
 for(const source of['1. '+giant.repeat(10)+'\n1. next\n','| A | B |\n|---|---|\n| '+giant.repeat(10)+' | tail |\n| next | cell |\n']){
  // Match production segmented physical rows instead of feeding oversized chunks.
  const rows=[];source.split('\n').forEach((line,index)=>{for(let i=0;i<line.length||i===0;i+=8192)rows.push({text:line.slice(i,i+8192),number:index+1});});const reader={rows:rows.length,eof:true,ensureRows:async()=>{},getRows:async(s,n)=>rows.slice(s,s+n)};
  const stream=new Stream();let replay;const worker={call:async m=>m.op==='feed'?stream.feed(m.text,m.final):m.op==='replayStart'?(replay=new Stream(m.start,m.context),{}):replay.feed(m.text,m.final)};
  const index=new Index(new Source(reader),worker);const first=await index.get(0),second=await index.get(1);for(let n=2;!index.done;n++)await index.get(n);assert.ok(index.sections.length>5);assert.deepEqual(await index.get(0),first);assert.deepEqual(await index.get(1),second);assert.ok(index.detail.size<=4);
 }
});
test('bounded moderately large items and rows keep semantic formatting rather than falling back unnecessarily',()=>{
 const value='**'+('body '.repeat(5000))+'end**';
 const list=('1. '+value+'\n').repeat(5);const ls=collect(list).blocks;assert.ok(ls.every(b=>b.fragment?.kind==='list'));assert.ok(ls.every(b=>tokens(list.slice(b.start,b.end),{},b.fragment)[0].items[0].tokens[0].tokens[0].type==='strong'));
 const table='| A | B |\n|---|---|\n'+('| '+value+' | cell |\n').repeat(5);const ts=collect(table).blocks;assert.ok(ts.every(b=>b.fragment?.kind==='table'));assert.equal(ts.reduce((n,b)=>n+tokens(table.slice(b.start,b.end),{},b.fragment)[0].rows.length,0),5);assert.ok(ts.every(b=>tokens(table.slice(b.start,b.end),{},b.fragment)[0].rows[0][0].tokens[0].type==='strong'));
});
test('a fragmented row just over the initial indexing threshold waits for row identity instead of dropping the table context',()=>{
 const source='| A | B |\n|---|---|\n| '+giant+' | tail |\n| last | **normal** |\n';
 const stream=new Stream(),blocks=[];blocks.push(...stream.feed(source.slice(0,65536),false).blocks);blocks.push(...stream.feed(source.slice(65536,65537),false).blocks);for(let i=65537;i<source.length;i+=65536)blocks.push(...stream.feed(source.slice(i,i+65536),i+65536>=source.length).blocks);
 assert.equal(stream.pending,'');assert.equal(literal(source,blocks,'table-row-source'),'| '+giant+' | tail |\n');const last=blocks.at(-1);assert.equal(tokens(source.slice(last.start,last.end),{},last.fragment)[0].rows[0][1].tokens[0].type,'strong');
});
