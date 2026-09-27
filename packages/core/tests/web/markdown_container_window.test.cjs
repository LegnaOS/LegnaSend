const {test} = require('node:test');
const assert = require('node:assert/strict');
const {Stream,tokens} = require('../../assets/web/markdown-blocks.js');
const {Source,Index} = require('../../assets/web/markdown-stream.js');
function collect(source,step=65536){const s=new Stream(),blocks=[];let peak=0;for(let p=0;p<source.length;p+=step){blocks.push(...s.feed(source.slice(p,p+step),p+step>=source.length).blocks);peak=Math.max(peak,s.pending.length);}assert.equal(s.pending,'');return {blocks,peak};}
test('large ordered lists retain every complete item, nested code and ordinal across windows',()=>{
  const item='1. **value** [later]\n   continuation\n   - nested\n\n   ```js\n   const value = "<img>";\n   ```\n\n';
  const source=item.repeat(6000)+'# after\n';
  const {blocks,peak}=collect(source,39173), windows=blocks.filter(b=>b.fragment);
  let count=0;
  for(const b of windows){const t=tokens(source.slice(b.start,b.end),{later:{href:'https://example.com'}},b.fragment)[0];assert.equal(t.type,'list');assert.equal(t.start,count+1);count+=t.items.length;assert.ok(t.items.length<=16);assert.ok(t.items[0].tokens.some(t=>t.type==='code'));}
  assert.equal(count,6000);assert.ok(peak<=65536);assert.equal(blocks.at(-1).type,'heading');
  assert.equal(windows.map(b=>source.slice(b.start,b.end)).join('').trimEnd(),item.repeat(6000).trimEnd());
});
test('large quote windows retain complete nested fences, paragraph emphasis and source bytes',()=>{
  const item='> **paragraph** [later]\n>\n> ```js\n> > literal quote\n>\n> literal blank\n> ```\n>\n';
  const source=item.repeat(6000)+'\n# after\n';
  const {blocks,peak}=collect(source), windows=blocks.filter(b=>b.fragment);
  let paragraphs=0,codes=0;
  for(const b of windows){const t=tokens(source.slice(b.start,b.end),{later:{href:'https://example.com'}},b.fragment)[0];assert.equal(t.type,'blockquote');for(const child of t.tokens){if(child.type==='paragraph'){paragraphs++;assert.equal(child.tokens[0].type,'strong');}if(child.type==='code'){codes++;assert.equal(child.text,'> literal quote\n\nliteral blank');}}}
  assert.equal(paragraphs,6000);assert.equal(codes,6000);assert.ok(peak<=65536);assert.equal(blocks.at(-1).type,'heading');assert.equal(windows.map(b=>source.slice(b.start,b.end)).join('').trimEnd(),item.repeat(6000).trimEnd());
});
test('container section LRU replays mid-list numbering and quote context exactly',async()=>{
  for(const source of ['1. **value** [later]\n   second line\n'.repeat(10000),'> paragraph **value**\n>\n'.repeat(10000)]){
    const rows=source.split('\n').map((text,i)=>({text,number:i+1}));const reader={rows:rows.length,eof:true,ensureRows:async()=>{},getRows:async(s,n)=>rows.slice(s,s+n)};
    const stream=new Stream();let replay;const worker={call:async m=>m.op==='feed'?stream.feed(m.text,m.final):m.op==='replayStart'?(replay=new Stream(m.start,m.context),{}):replay.feed(m.text,m.final)};
    const index=new Index(new Source(reader),worker);const first=await index.get(0),second=await index.get(1);for(let n=2;!index.done;n++)await index.get(n);assert.ok(index.sections.length>5);assert.deepEqual(await index.get(0),first);assert.deepEqual(await index.get(1),second);
  }
});
test('a quote fence containing blank markers is never cut at those markers',()=>{
  const code='> ```txt\n'+'> literal\n>\n'.repeat(100)+'> ```\n>\n';
  const source=code.repeat(150);const {blocks}=collect(source,16384);for(const b of blocks){const t=tokens(source.slice(b.start,b.end),{},b.fragment);for(const c of t[0].tokens.filter(t=>t.type==='code'))assert.equal(c.text,('literal\n\n'.repeat(100)).replace(/\n$/,''));}
});
test('enormous paragraphs preserve every character, entities, soft lines and a following real heading',()=>{
  for(const body of ['**'+'word 中文🙂 &amp; '.repeat(30000)+'**',('text 中文🙂 &amp; '.repeat(80)+'\n').repeat(1000)]){
    const source=body+'\n\n# after\n';const {blocks,peak}=collect(source,39173);const windows=blocks.filter(b=>['paragraph','table-header-source'].includes(b.fragment?.kind));
    assert.ok(windows.length>20);assert.ok(peak<=65536);assert.ok(windows.every(b=>b.end-b.start<=16384));
    assert.equal(windows.map(b=>tokens(source.slice(b.start,b.end),{},b.fragment)[0].tokens[0].text).join('').trimEnd(),body.trimEnd());
    assert.equal(blocks.at(-1).type,'heading');
  }
});
test('reference index exceeds 4096 definitions without retaining their values; visible labels resolve first definitions',async()=>{
  const source='[last][ref11999] [first][ref0]\n\n'+Array.from({length:12000},(_,i)=>`[ref${i}]: https://example.com/${i} "Title ${i}"\n`).join('')+'\n[ref0]: javascript:bad\n\n'+('# next\n\ntext\n\n'.repeat(150));
  const rows=source.split('\n').map((text,i)=>({text,number:i+1}));const reader={rows:rows.length,eof:true,ensureRows:async()=>{},getRows:async(s,n)=>rows.slice(s,s+n)};
  const stream=new Stream(0,null,{externalReferences:true});let lookup;
  const worker={call:async m=>{if(m.op==='feed')return stream.feed(m.text,m.final);if(m.op==='lookupStart'){lookup=new Stream(0,null,{referenceFilter:new Set(m.names)});return {};}if(m.op==='lookup'){lookup.feed(m.text,m.final);return m.final?lookup.links:{};}throw Error(m.op);}};
  const index=new Index(new Source(reader),worker);await index.ensure(0);assert.deepEqual(Object.keys(stream.links),[]);assert.ok(stream.version>12000);
  const links=await index.resolveReferences(['ref0','ref11999','missing']);assert.equal(links.ref0.href,'https://example.com/0');assert.equal(links.ref11999.href,'https://example.com/11999');assert.equal(links.missing,undefined);assert.ok(index.referenceBytes<=1024*1024);assert.equal(index.references.size,3);
});
test('needed-reference probing has no inherited Object properties and preserves literal paragraph entities',()=>{
  const {needed}=require('../../assets/web/markdown-blocks.js');const {render}=require('../../assets/web/markdown-preview.js');const {domFixture}=require('./dom_fixture.cjs');
  assert.deepEqual(needed('[x][constructor] [missing]'),['constructor','missing']);
  const ordinary=tokens('[x][constructor]',{});assert.ok(ordinary[0].tokens.every(t=>t.type!=='link'));
  const fixture=domFixture();const rendered=render(tokens('&amp; <script> **literal**',{}, {kind:'paragraph',literal:true}),fixture.document);fixture.document.body.appendChild(rendered);
  assert.ok(fixture.descendants().some(n=>n.textContent==='&amp; <script> **literal**'));assert.equal(fixture.descendants().filter(n=>n.tag==='script').length,0);
});
