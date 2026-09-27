'use strict';
// Independent Firefox/WebKit profiles against the actual Rust fixture servers.
// A local throttling proxy preserves original HTTP routes/headers and makes
// unbuffered late media seeks observable without Chromium-only CDP APIs.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const http=require('node:http'),{Transform}=require('node:stream'),{spawn,spawnSync,execFileSync}=require('node:child_process');
const {createHash}=require('node:crypto');
const playwright=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-cross-engine-'));
const evidence=process.env.EVIDENCE_DIR||path.join(os.tmpdir(),'legnasend-cross-engine-evidence');fs.mkdirSync(evidence,{recursive:true});
const engines=(process.env.BROWSER_ENGINES||'firefox,webkit').split(',');
const children=[],proxies=[],results=[],errors=[],artifacts=[];let browser;
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const text=Buffer.from(Array.from({length:9000},(_,i)=>`LINE ${i+1} 碧绿 · readable content ${i===8765?'UNIQUE-TXT-NEEDLE':''}\n`).join(''));
const markdown=Buffer.from('# LegnaSend Markdown\n\nA **rendered** paragraph.\n\n| Item | Status |\n| --- | --- |\n| 中文 | Ready |\n\nMarkdown-内容搜索目标\n\n<script>window.injected=1</script>\n');
fs.mkdirSync(root+'/a');fs.mkdirSync(root+'/b');
for(const dir of [root,root+'/a']){fs.writeFileSync(dir+'/demo.txt',text);fs.writeFileSync(dir+'/demo.md',markdown);}
fs.writeFileSync(root+'/b/independent.txt','other workspace');
function generate(args){const result=spawnSync(process.env.FFMPEG_PATH||'ffmpeg',['-hide_banner','-loglevel','error','-y',...args],{encoding:'utf8',timeout:120000});assert.equal(result.status,0,result.stderr);}
generate(['-f','lavfi','-i','testsrc2=size=640x360:rate=24','-t','40','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-b:v','1500k','-g','24','-movflags','+faststart',root+'/demo.mp4']);
generate(['-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','80','-c:a','pcm_s16le',root+'/demo.wav']);
for(const name of ['demo.mp4','demo.wav'])fs.copyFileSync(root+'/'+name,root+'/a/'+name);
async function until(fn){for(let i=0;i<1200;i++){const value=await fn();if(value)return value;await new Promise(r=>setTimeout(r,25));}throw Error('fixture timeout');}
async function server(example){const process=spawn(path.join(repo,'target/debug/examples/'+example),[root],{env:{...global.process.env,LEGNASEND_FIXTURE_MODE:'download',LEGNASEND_FIXTURE_COUNT:'0'}});children.push(process);let output='';process.stdout.on('data',d=>output+=d);process.stderr.on('data',d=>output+=d);return until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);}
class Throttle extends Transform{
 _transform(chunk,encoding,done){let offset=0;const next=()=>{if(this.destroyed)return done();const end=Math.min(offset+8192,chunk.length);this.push(chunk.subarray(offset,end));offset=end;if(offset<chunk.length)this.timer=setTimeout(next,15);else this.timer=setTimeout(done,15);};next();}
 _destroy(error,done){clearTimeout(this.timer);done(error);}
}
async function proxy(upstream){
 const target=new URL(upstream),requests=[];
 const server=http.createServer((req,res)=>{
  const record={path:req.url,method:req.method,range:req.headers.range||null,status:0,bytes:0,closed:false};requests.push(record);
  const upstreamRequest=http.request({hostname:target.hostname,port:target.port,path:req.url,method:req.method,headers:req.headers},response=>{
   record.status=response.statusCode;res.writeHead(response.statusCode,response.headers);
   const media=req.url.includes('/content?')||req.url.includes('/download?');
   const stream=media&&req.method==='GET'?response.pipe(new Throttle()):response;
   stream.on('data',chunk=>record.bytes+=chunk.length);stream.on('error',()=>res.destroy());stream.pipe(res);
   res.on('close',()=>{record.closed=true;stream.destroy();response.destroy();upstreamRequest.destroy();});
  });upstreamRequest.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end();});req.pipe(upstreamRequest);
 });await new Promise(r=>server.listen(0,'127.0.0.1',r));proxies.push(server);return {url:`http://127.0.0.1:${server.address().port}/`,requests};
}
async function run(){
 const directory=await proxy(await server('directory_workspace_fixture')),temporary=await proxy(await server('web_preview_fixture'));
 for(const engine of engines){
  const type=playwright[engine];assert(type,'Unknown engine '+engine);
  browser=await type.launch({headless:true});const version=browser.version();
  const context=await browser.newContext({viewport:{width:1000,height:820},locale:'en-US',acceptDownloads:true});
  const page=await context.newPage();page.setDefaultTimeout(15000);const pageErrors=[];
  if(process.env.MEDIA_TEARDOWN_PROBE==='preload')await page.route('**/assets/media-preview.js',route=>route.fulfill({contentType:'text/javascript; charset=utf-8',body:fs.readFileSync(path.join(repo,'packages/core/assets/web/media-preview.js'),'utf8').replaceAll("media.removeAttribute('src'); media.load();","media.preload='none'; media.removeAttribute('src'); media.load();")}));
  if(process.env.MEDIA_TEARDOWN_PROBE==='empty')await page.route('**/assets/media-preview.js',route=>route.fulfill({contentType:'text/javascript; charset=utf-8',body:fs.readFileSync(path.join(repo,'packages/core/assets/web/media-preview.js'),'utf8').replaceAll("media.removeAttribute('src'); media.load();","media.src = ''; media.load(); media.removeAttribute('src');")}));
  page.on('pageerror',e=>pageErrors.push(e.message));
  for(const [surface,endpoint] of [['directory',directory],['temporary',temporary]]){
   const prefix=surface==='directory'?'directory-preview':'preview',content='#'+prefix+'-content';
   async function home(){await page.goto(endpoint.url+(surface==='directory'?'design/':''));await page.locator(surface==='directory'?'.preview-button':'.file-row').first().waitFor();}
   async function open(name){await page.locator(surface==='directory'?`.row[title="${name}"] .preview-button`:`[data-preview-id="${({'demo.mp4':'video','demo.wav':'audio','demo.txt':'text','demo.md':'markdown'})[name]}"]`).click();}
   async function close(){await page.locator('#'+prefix+'-close').click();}
   async function check(name,fn){if(process.env.CASE_FILTER&&!new RegExp(process.env.CASE_FILTER).test(surface+':'+name))return;const entry={engine,version,surface,case:name,ok:false};try{await home();await fn(entry);entry.ok=true;}catch(error){entry.error=String(error.stack||error);entry.trace=await page.evaluate(()=>window.__mediaTrace||[]).catch(()=>[]);errors.push(entry);try{await page.screenshot({path:path.join(evidence,`${engine}-${surface}-${name}-failure.png`)});}catch{} }results.push(entry);fs.writeFileSync(path.join(evidence,`${engine}-partial.json`),JSON.stringify({results,pageErrors},null,2));}
   for(const [name,tag,target] of [['demo.mp4','video',30],['demo.wav','audio',60]])await check(tag,async entry=>{
    const marker=endpoint.requests.length;await page.evaluate(()=>{const mount=LegnaMediaPreview.mount;LegnaMediaPreview.mount=function(options){const controller=mount(options);window.__lastMediaController=controller;return controller;};});await open(name);
    await page.locator(content+' .media-preview-player[data-state="paused"]').waitFor();
    const media=page.locator(content+' '+tag);entry.initial=await media.evaluate(m=>({preload:m.preload,src:m.getAttribute('src'),ready:m.readyState,buffers:m.buffered.length}));
    assert.equal(entry.initial.src,null);assert.equal(entry.initial.ready,0);assert.equal(entry.initial.buffers,0);
    await media.evaluate(m=>{window.__mediaTrace=[];for(const event of ['loadstart','loadedmetadata','play','playing','pause','seeked','emptied','error','ended','ratechange','abort','timeupdate'])m.addEventListener(event,()=>{if(window.__mediaTrace.length<100)window.__mediaTrace.push({event,time:m.currentTime,duration:m.duration,paused:m.paused,src:m.getAttribute('src'),at:performance.now()});});});
    await page.locator(content+' .media-preview-resume').click();await page.waitForFunction(selector=>document.querySelector(selector).currentTime>.2,content+' '+tag);
    entry.beforePause=await media.evaluate(m=>{const before=m.currentTime;m.volume=.4;m.playbackRate=1.25;const afterRate=m.currentTime;m.pause();return {before,afterRate,afterPause:m.currentTime};});
    await page.locator(content+' .media-preview-player[data-state="paused"]').waitFor();
    assert.equal(await media.getAttribute('src'),null);assert.equal(await media.evaluate(m=>m.buffered.length),0);
    entry.savedBeforeSample=await page.evaluate(()=>({snapshot:window.__lastMediaController.snapshot(),input:document.querySelector('.media-preview-position').value}));
    const pauseRequests=endpoint.requests.slice(marker).filter(r=>r.method==='GET');let before=pauseRequests.reduce((n,r)=>n+r.bytes,0);entry.pauseByteIntervals=[];
    for(let i=0;i<8;i++){await page.waitForTimeout(200);const after=pauseRequests.reduce((n,r)=>n+r.bytes,0);entry.pauseByteIntervals.push(after-before);before=after;}
    entry.pauseSettledBytes=entry.pauseByteIntervals.slice(-2).reduce((a,b)=>a+b,0);entry.resourceReleased=entry.pauseSettledBytes===0;
    entry.savedPosition=Number(await page.locator(content+' .media-preview-position').inputValue());assert(entry.savedPosition>.1);
    await page.locator(content+' .media-preview-position').evaluate((input,t)=>{input.value=String(t);input.dispatchEvent(new Event('input'));},target);
    const at=endpoint.requests.length;await page.locator(content+' .media-preview-resume').click();
    await page.waitForFunction(({selector,target})=>{const m=document.querySelector(selector);return m.currentTime>target+.1&&!m.seeking;},{selector:content+' '+tag,target},{timeout:40000});
    entry.lateRanges=endpoint.requests.slice(at).filter(r=>r.range&&Number(r.range.match(/bytes=(\d+)/)?.[1])>fs.statSync(root+'/'+name).size/2).map(r=>({range:r.range,status:r.status}));
    assert(entry.lateRanges.some(r=>r.status===206));assert.deepEqual(await media.evaluate(m=>[m.volume,m.playbackRate]),[.4,1.25]);
    // Change rate and pause again after a real unbuffered late seek. This
    // catches the WebKit clock reset at a meaningful resume position too.
    await media.evaluate(m=>{m.playbackRate=1.5;m.pause();});await page.locator(content+' .media-preview-player[data-state="paused"]').waitFor();
    entry.lateSavedPosition=Number(await page.locator(content+' .media-preview-position').inputValue());assert(entry.lateSavedPosition>=target);
    await page.locator(content+' .media-preview-resume').click();
    await page.waitForFunction(({selector,target})=>document.querySelector(selector).currentTime>target+.1,{selector:content+' '+tag,target},{timeout:40000});
    assert.equal(await media.evaluate(m=>m.playbackRate),1.5);
    const old=await media.elementHandle();await close();await page.waitForTimeout(200);assert(await old.evaluate(m=>m.paused&&!m.hasAttribute('src')&&m.readyState===0&&m.buffered.length===0));await old.dispose();entry.cleanup=true;entry.functional=true;assert.equal(entry.pauseSettledBytes,0,'media bytes continue after the release observation interval');
   });
   await check('text-search',async entry=>{
    const marker=endpoint.requests.length;await open('demo.txt');await page.locator(content+' .text-row').first().waitFor();
    await page.locator(content+' .text-search select').selectOption('full');await page.locator(content+' .text-query').fill('UNIQUE-TXT-NEEDLE');
    await page.waitForFunction(()=>document.querySelector('[data-current-match]')?.textContent==='UNIQUE-TXT-NEEDLE',null,{timeout:40000});
    entry.rows=await page.locator(content+' .text-row').count();assert(entry.rows<60);
    entry.rangeCount=endpoint.requests.slice(marker).filter(r=>r.range).length;
    assert(endpoint.requests.slice(marker).filter(r=>r.range).every(r=>{const m=/bytes=(\d+)-(\d+)/.exec(r.range);return m&&Number(m[2])-Number(m[1])+1<=65536;}));
    const download=page.waitForEvent('download');await page.locator('#'+prefix+'-download').click();const item=await download;
    assert.equal(await item.failure(),null);const destination=path.join(evidence,`${engine}-${surface}-text.txt`);artifacts.push(destination);await item.saveAs(destination);
    entry.sha256=sha(fs.readFileSync(destination));assert.equal(entry.sha256,sha(text));await close();
   });
   await check('markdown-search',async entry=>{
    await open('demo.md');await page.locator(content+' .markdown-document h1').waitFor();
    assert.equal(await page.locator(content+' .markdown-document h1').textContent(),'LegnaSend Markdown');
    assert.equal(await page.locator(content+' .markdown-document strong').textContent(),'rendered');assert.equal(await page.locator(content+' .markdown-document table').count(),1);
    assert.equal(await page.locator(content+' script').count(),0);assert.equal(await page.evaluate(()=>window.injected),undefined);
    await page.locator(content+' .text-query').fill('Markdown-内容搜索目标');await page.waitForFunction(()=>document.querySelector('[data-current-match]')?.textContent==='Markdown-内容搜索目标');
    entry.rendered=true;entry.contentSearch=true;await page.setViewportSize({width:320,height:740});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.screenshot({path:path.join(evidence,`${engine}-${surface}-markdown-320.png`)});await close();await page.setViewportSize({width:1000,height:820});
   });
   if(surface==='temporary')await check('selected-zip',async entry=>{
    await page.locator('.file-select[data-select-id="text"]').check();await page.locator('.file-select[data-select-id="markdown"]').check();
    const event=page.waitForEvent('download');await page.getByRole('button',{name:'Download selected · ZIP (2)',exact:true}).click();const item=await event;assert.equal(await item.failure(),null);
    const destination=path.join(evidence,`${engine}-selected.zip`);artifacts.push(destination);await item.saveAs(destination);
    const zip=JSON.parse(execFileSync('python3',['-c',`import sys,zipfile,json,hashlib\nwith zipfile.ZipFile(sys.argv[1]) as z:\n assert z.testzip() is None\n print(json.dumps({n:hashlib.sha256(z.read(n)).hexdigest() for n in z.namelist()}))`,destination],{encoding:'utf8'}));
    assert.deepEqual(zip,{'demo.md':sha(markdown),'demo.txt':sha(text)});entry.files=zip;entry.zipSha256=sha(fs.readFileSync(destination));
    assert.equal(await page.locator('.file-select:checked').count(),2);entry.pageRetained=true;
   });
  }
  assert.deepEqual(pageErrors,[]);await context.close();await browser.close();browser=null;
 }
 fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify({host:process.platform,playwright:require((process.env.PLAYWRIGHT_MODULE||'playwright')+'/package.json').version,results,errors,boundary:'Playwright desktop engines, real Rust loopback fixtures, no user browser settings; WebKit is not Safari physical acceptance'},null,2)+'\n');
 console.log(JSON.stringify({cases:results.length,passed:results.filter(r=>r.ok).length,errors}));assert.deepEqual(errors,[]);
}
run().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{
 if(browser)await browser.close();for(const artifact of artifacts)if(fs.existsSync(artifact))fs.unlinkSync(artifact);for(const proxy of proxies){proxy.closeAllConnections();await new Promise(r=>proxy.close(r));}for(const child of children)child.kill();fs.rmSync(root,{recursive:true,force:true});
});
