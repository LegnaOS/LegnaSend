const {test}=require('node:test');
const assert=require('node:assert/strict');
const {Reader,LineSeek}=require('../../assets/web/text-preview.js');
function fixture(source, encoding='auto') {
  const bytes=Buffer.isBuffer(source)?source:Buffer.from(source),requests=[];
  let version='"v1"', stall=false, waiting=false;
  const fetch=async(_url,options)=>{
    requests.push(options);
    if(options.method==='HEAD')return new Response(null,{headers:{'Content-Length':String(bytes.length),'Accept-Ranges':'bytes',ETag:version}});
    if(stall) {waiting=true;await new Promise((resolve,reject)=>{options.signal.addEventListener('abort',()=>reject(new DOMException('Aborted','AbortError')),{once:true});});}
    if(options.headers['If-Match']!==version)return new Response(null,{status:412});
    const [,start,end]=options.headers.Range.match(/bytes=(\d+)-(\d+)/).map(Number);
    return new Response(bytes.subarray(start,end+1),{status:206,headers:{'Content-Length':String(end-start+1),'Content-Range':`bytes ${start}-${end}/${bytes.length}`,ETag:version}});
  };
  return {reader:new Reader('/source',bytes.length,{fetch,encoding}),bytes,requests,
    change(){version='"v2"';},stall(){stall=true;},get waiting(){return waiting;}};
}
test('seeking an unindexed late logical line keeps source, ranges, caches and adopted content bounded',async()=>{
  const f=fixture(Array.from({length:160000},(_,i)=>`line ${i+1} 中文🙂 content\n`).join(''));await f.reader.init();
  const before=f.reader.offset;let peak=0,updates=0;
  const seek=new LineSeek(f.reader,125000,{onProgress:s=>{updates++;if(s.reader)peak=Math.max(peak,s.reader.cacheBytes);}});
  await seek.run();assert.equal(seek.error,null);assert.equal(seek.row,124999);assert.equal(seek.complete,true);
  assert.ok(seek.index.offset>before);assert.ok(seek.index.offset<f.bytes.length);assert.equal(f.reader.offset,before);
  assert.ok(updates>20);assert.ok(peak<=2*1024*1024);assert.equal(seek.reader.cacheBytes,0);assert.equal(seek.reader.closed,true);
  f.reader.adopt(seek.index);assert.equal((await f.reader.getRows(seek.row,1))[0].text,'line 125000 中文🙂 content');
  assert.ok(f.requests.filter(r=>r.method==='GET').every(r=>{const [,a,b]=r.headers.Range.match(/bytes=(\d+)-(\d+)/).map(Number);return b-a+1<=65536;}));
  f.reader.close();
});
test('UTF-8/UTF-16 boundaries and segmented long lines preserve physical line addressing',async()=>{
  const source='甲🙂'.repeat(50000)+'\r\n目标第二行🙂\r\nthird';
  const le=Buffer.concat([Buffer.from([255,254]),Buffer.from(source,'utf16le')]),be=Buffer.from(le);be.swap16();
  for(const data of [Buffer.from(source),le,be]) {
    const f=fixture(data);await f.reader.init();
    const seek=new LineSeek(f.reader,2);await seek.run();assert.equal(seek.error,null);assert.ok(seek.row>1);
    f.reader.adopt(seek.index);const row=(await f.reader.getRows(seek.row,1))[0];
    assert.equal(row.number,2);assert.equal(row.continued,false);assert.equal(row.text,'目标第二行🙂');
    const back=new LineSeek(f.reader,1);await back.run();assert.equal(back.row,0);
    f.reader.close();
  }
});
test('user cancellation aborts only seek requests and preserves the visible reader',async()=>{
  const f=fixture('visible 中文🙂\n'.repeat(200000));await f.reader.init();const before=f.reader.offset;
  let seek;seek=new LineSeek(f.reader,150000,{onProgress:s=>{if(s.index?.offset>200000&&!s.cancelled)s.cancel();}});
  await seek.run();assert.equal(seek.cancelled,true);assert.equal(seek.running,false);assert.equal(seek.error,null);
  assert.equal(f.reader.offset,before);assert.equal(f.reader.closed,false);assert.equal((await f.reader.getRows(0,1))[0].text,'visible 中文🙂');
  const count=f.requests.length;await new Promise(r=>setTimeout(r,20));assert.equal(f.requests.length,count);f.reader.close();
});
test('canceling a pending body request resolves promptly without closing the viewport',async()=>{
  const f=fixture('line\n'.repeat(100000));await f.reader.init();f.stall();const seek=new LineSeek(f.reader,90000);const task=seek.run();
  for(let i=0;!f.waiting&&i<100;i++)await new Promise(r=>setTimeout(r,1));assert.equal(f.waiting,true);seek.cancel();
  await Promise.race([task,new Promise((_,reject)=>setTimeout(()=>reject(Error('cancel timeout')),1000))]);
  assert.equal(seek.error,null);assert.equal(f.reader.closed,false);assert.equal((await f.reader.getRows(0,1))[0].text,'line');f.reader.close();
});
test('version changes before and during seeking never publish a target from mixed versions',async()=>{
  for(const during of [false,true]){
    const f=fixture('line\n'.repeat(300000));await f.reader.init();if(!during)f.change();
    const seek=new LineSeek(f.reader,250000,{onProgress:s=>{if(during&&s.index?.offset>150000)f.change();}});
    await seek.run();assert.equal(seek.error?.code,'changed');assert.equal(seek.row,null);assert.equal(seek.complete,false);assert.equal(seek.reader.cacheBytes,0);f.reader.close();
  }
});
test('EOF reports only the actual total line count and already-indexed seeks skip rescanning',async()=>{
  const f=fixture('hello\n'.repeat(100000));await f.reader.init();await f.reader.ensureRows(100001);
  const before=f.requests.length,seek=new LineSeek(f.reader,50000);await seek.run();
  assert.equal(seek.row,49999);assert.ok(f.requests.length-before<=3);
  assert.ok(f.requests.slice(before).filter(r=>r.method==='GET').every(r=>!r.headers.Range.startsWith('bytes=0-')));
  const missing=new LineSeek(f.reader,200000);await missing.run();assert.equal(missing.row,null);assert.equal(missing.complete,true);assert.equal(missing.knownLine,100001);f.reader.close();
});
test('empty files expose line one; invalid requested numbers never trigger network reads',async()=>{
  const f=fixture('');await f.reader.init();const seek=new LineSeek(f.reader,1);await seek.run();assert.equal(seek.row,0);
  const before=f.requests.length;for(const target of [0,-1,1.5,NaN,Infinity,Number.MAX_SAFE_INTEGER+1])assert.throws(()=>new LineSeek(f.reader,target),{code:'line'});
  assert.equal(f.requests.length,before);f.reader.close();
});
