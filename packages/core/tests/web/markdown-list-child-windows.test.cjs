'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const api=require('../../assets/web/markdown-blocks.js');
const {render}=require('../../assets/web/markdown-preview.js');
const {Source,Index}=require('../../assets/web/markdown-stream.js');
const {domFixture}=require('./dom_fixture.cjs');
function collect(text,step=32768){const stream=new api.Stream(0,null,{externalReferences:true}),blocks=[];let retained=0;for(let at=0;at<text.length;at+=step){blocks.push(...stream.feed(text.slice(at,at+step),at+step>=text.length).blocks);retained=Math.max(retained,stream.pending.length);assert.ok(stream.pending.length<=api.limit);}assert.equal(stream.pending,'');return{blocks,retained};}
function textOf(tokens){return tokens.map(token=>token.text||'').join('');}
const body='   paragraph **bold 中文🙂** [reference][late]\n\n';
const item='3. **first**\n\n'+body.repeat(10000);
const source=item+'4. **following**\n\n# End\n';
test('one >256Ki loose item keeps complete child semantics without literal downgrade or source loss',()=>{
 assert.ok(item.length>api.limit);
 for(const step of[997,16384,65536]){
  const {blocks}=collect(source,step),windows=blocks.filter(b=>b.fragment?.kind==='list-item-children');
  assert.ok(windows.length>100);assert.ok(!blocks.some(b=>b.fragment?.kind==='list-item-source'));
  assert.equal(windows.map(b=>source.slice(b.start,b.end)).join(''),item);
  let paragraphs=0;
  for(const block of windows){
   assert.ok(block.end-block.start<=65536);
   const raw=source.slice(block.start,block.end);assert.ok(raw.split('\n').length<=257);
   assert.ok(!/^[\udc00-\udfff]|[\ud800-\udbff]$/.test(raw));
   const list=api.tokens(raw,{late:{href:'https://example.invalid/',title:null}},block.fragment)[0];
   assert.equal(list.type,'list');assert.equal(list.start,3);assert.equal(list.items.length,1);
   assert.equal(!!list.items[0].continuation,!block.fragment.first);
   const children=list.items[0].tokens.filter(t=>t.type==='paragraph');paragraphs+=children.length;
   assert.ok(children.every(p=>p.tokens.some(t=>t.type==='strong')));
   assert.ok(!textOf(children).includes('LegnaContinuation'));
  }
  assert.equal(paragraphs,10001);
  const following=blocks.find(b=>b.start===item.length);
  const next=api.tokens(source.slice(following.start,following.end),{},following.fragment)[0];assert.equal(next.start,4);
  assert.equal(blocks.at(-1).type,'heading');
 }
});
test('bounded nested fences remain code children, never fake list items or headings',()=>{
 const nested='   ```md\n   # inside code\n   - not an item\n   ```\n\n';
 const value='3. begin\n\n'+nested.repeat(2500)+'4. next\n\n# real\n';const {blocks}=collect(value,39173);
 let count=0;
 for(const b of blocks.filter(b=>b.fragment?.kind==='list-item-children')){
  const list=api.tokens(value.slice(b.start,b.end),{},b.fragment)[0];
  for(const token of list.items[0].tokens){if(token.type==='code'){count++;assert.equal(token.text,'# inside code\n- not an item');}assert.notEqual(token.type,'heading');}
 }
 assert.equal(count,2500);assert.equal(blocks.at(-1).type,'heading');
});
test('section eviction replays exactly from inside one oversized semantic item',async()=>{
 const rows=source.split('\n').map((text,i)=>({text,number:i+1}));const reader={rows:rows.length,eof:true,ensureRows:async()=>{},getRows:async(s,n)=>rows.slice(s,s+n)};
 const stream=new api.Stream();let replay;
 const worker={call:async m=>m.op==='feed'?stream.feed(m.text,m.final):m.op==='replayStart'?(replay=new api.Stream(m.start,m.context),{}):replay.feed(m.text,m.final)};
 const index=new Index(new Source(reader),worker);const first=await index.get(0),second=await index.get(1);for(let n=2;!index.done;n++)await index.get(n);
 assert.ok(index.sections.length>4);assert.ok(index.detail.size<=4);
 // Compare serialized metadata to avoid megabytes of assertion output.
 assert.equal(JSON.stringify(await index.get(0)),JSON.stringify(first));assert.equal(JSON.stringify(await index.get(1)),JSON.stringify(second));
});
test('continuation rendering hides duplicate markers while preserving safe semantic nodes and reference lookup',()=>{
 const {blocks}=collect(source);const b=blocks.find(b=>b.fragment?.kind==='list-item-children'&&!b.fragment.first),raw=source.slice(b.start,b.end);
 assert.ok(api.needed(raw,b.fragment).includes('late'));
 const f=domFixture();f.document.body.appendChild(render(api.tokens(raw,{late:{href:'https://example.invalid/'}},b.fragment),f.document));
 assert.ok(f.descendants().some(n=>n.tag==='li'&&n.className==='markdown-list-continuation'));
 assert.ok(f.descendants().some(n=>n.tag==='strong'));assert.ok(f.descendants().some(n=>n.tag==='a'));
 assert.ok(f.descendants().length<6000);assert.ok(!f.document.body.textContent.includes('LegnaContinuation'));
 const needle='paragraph **bold 中文🙂**',local=raw.indexOf(needle);assert.ok(local>=0);assert.equal(source.slice(b.start+local,b.start+local+needle.length),needle);
});
test('a later unbounded inline child keeps full literal source and an explicit fallback notice',()=>{
 const prefix='1. start\n\n'+('   **small**\n\n'.repeat(6000)),large='   **'+('giant 中文🙂 '.repeat(20000))+'**\n';
 const value=prefix+large+'1. next\n';const {blocks}=collect(value),semantic=blocks.filter(b=>b.fragment?.kind==='list-item-children'),literal=blocks.filter(b=>b.fragment?.kind==='list-item-source');
 assert.ok(semantic.length>0);assert.ok(literal.length>0);assert.equal(literal.filter(b=>b.fragment.first).length,1);
 const giantStart=value.indexOf('   **giant');assert.ok(literal.some(b=>b.start<=giantStart&&b.end>giantStart));
 const firstItem=blocks.filter(b=>b.start<prefix.length+large.length).map(b=>value.slice(b.start,b.end)).join('');assert.equal(firstItem,prefix+large);
});
