// Actual production preview controllers, browser decoding and a throttled local
// Range server. Server byte counters measure delivery, not a mocked pause event.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const http = require('node:http'), {spawnSync} = require('node:child_process');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../../assets/web');
const evidence = process.env.EVIDENCE_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-media-evidence-'));
fs.mkdirSync(evidence, {recursive:true});
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-media-lifecycle-'));
const baseline = process.env.MEDIA_BASELINE === '1';
const tag = '"'+'a'.repeat(64)+'"';
const mediaTypes = {mp4:'video/mp4',webm:'video/webm',mp3:'audio/mpeg',wav:'audio/wav'};
const generate = (args) => { const p = spawnSync(process.env.FFMPEG_PATH || 'ffmpeg', ['-hide_banner','-loglevel','error','-y',...args], {encoding:'utf8',timeout:120000});assert.equal(p.status,0,p.stderr); };
generate(['-f','lavfi','-i','testsrc2=size=640x360:rate=24','-t','60','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-b:v','1500k','-g','24','-movflags','+faststart',fixture+'/demo.mp4']);
generate(['-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','120','-c:a','pcm_s16le',fixture+'/demo.wav']);
if(!baseline){
 generate(['-f','lavfi','-i','testsrc2=size=640x360:rate=24','-t','60','-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','8','-b:v','1000k','-g','24',fixture+'/demo.webm']);
 generate(['-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','120','-c:a','libmp3lame','-b:a','192k',fixture+'/demo.mp3']);
}
const files = Object.fromEntries(fs.readdirSync(fixture).map(name=>[name,{fileName:name,fileType:mediaTypes[name.split('.').pop()],size:fs.statSync(fixture+'/'+name).size}]));
const requests = []; let browser; const active = new Set();
function bytesFor(name){return requests.filter(r=>r.name===name).reduce((n,r)=>n+r.bytes,0);}
const directory = `<!doctype html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/directories.css"><link rel="stylesheet" href="/assets/directory-preview.css"><link rel="stylesheet" href="/assets/media-preview.css"><link rel="stylesheet" href="/assets/theme.css"><script src="/assets/web-i18n.js"></script><script src="/assets/media-preview.js"></script><script src="/assets/directory-preview.js"></script></head><body><button id="trigger">Preview</button><dialog id="directory-preview"><div class="preview-heading"><div><span id="directory-preview-kind"></span><h2 id="directory-preview-title"></h2></div><button id="directory-preview-close"></button></div><p id="directory-preview-status"></p><div id="directory-preview-support"></div><div id="directory-preview-content"></div><button id="directory-preview-retry" hidden></button><a id="directory-preview-download"></a></dialog><script>window.preview=LegnaDirectoryPreview.create({onInvalid:function(){}});window.openFile=function(name,lang){return preview.open({name:name,size:${JSON.stringify(Object.fromEntries(Object.entries(files).map(([k,v])=>[k,v.size])))}[name]},'/content?name='+encodeURIComponent(name),lang||'en');};</script></body></html>`;
const server=http.createServer((req,res)=>{
 const u=new URL(req.url,'http://fixture');
 if(u.pathname==='/directory'){res.setHeader('Content-Type','text/html');return res.end(directory);}
 if(u.pathname==='/'){res.setHeader('Content-Type','text/html');return res.end(fs.readFileSync(assets+'/download.html'));}
 if(u.pathname.startsWith('/assets/')){const file=path.join(assets,path.basename(u.pathname));if(!fs.existsSync(file)){res.statusCode=404;return res.end();}res.setHeader('Content-Type',file.endsWith('.css')?'text/css; charset=utf-8':'text/javascript; charset=utf-8');return res.end(fs.readFileSync(file));}
 if(u.pathname==='/i18n.json'){res.setHeader('Content-Type','application/json');return res.end('{}');}
 if(u.pathname.endsWith('/prepare-download')){res.setHeader('Content-Type','application/json');return res.end(JSON.stringify({sessionId:'fixture',files}));}
 if(u.pathname==='/content'||u.pathname.endsWith('/download')){
  const name=u.searchParams.get('name')||u.searchParams.get('fileId'),file=files[name];if(!file){res.statusCode=404;return res.end();}
  res.setHeader('Content-Type',file.fileType);res.setHeader('Accept-Ranges','bytes');res.setHeader('ETag',tag);res.setHeader('Cache-Control','no-store');
  let start=0,end=file.size-1;const range=/^bytes=(\d+)-(\d*)$/.exec(req.headers.range||'');if(range){start=Number(range[1]);if(range[2])end=Math.min(end,Number(range[2]));res.statusCode=206;res.setHeader('Content-Range',`bytes ${start}-${end}/${file.size}`);}
  res.setHeader('Content-Length',end-start+1);if(req.method==='HEAD')return res.end();
  const record={name,range:req.headers.range||null,start,bytes:0,closed:false};requests.push(record);active.add(record);
  const fd=fs.openSync(fixture+'/'+name,'r');let offset=start,closed=false;
  const timer=setInterval(()=>{if(res.destroyed||offset>end)return finish();const n=Math.min(8192,end-offset+1),b=Buffer.alloc(n),read=fs.readSync(fd,b,0,n,offset);offset+=read;record.bytes+=read;res.write(b.subarray(0,read));if(offset>end){res.end();finish();}},20);
  function finish(){if(closed)return;closed=true;clearInterval(timer);fs.closeSync(fd);record.closed=true;active.delete(record);}
  res.on('close',finish);return;
 }
 res.statusCode=404;res.end();
});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function run(){
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const results=[];const errors=[];
 const context=await browser.newContext({viewport:{width:1000,height:780},locale:'en'});const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 for(const surface of ['directory','temporary']){
  await page.goto(`http://127.0.0.1:${server.address().port}/${surface==='directory'?'directory':''}`);
  if(surface==='temporary')await page.waitForFunction(()=>Object.keys(window.previewFiles||{}).length>0);
  for(const name of baseline?['demo.mp4','demo.wav']:Object.keys(files)){
   const sourceStart=bytesFor(name);
   if(surface==='directory')await page.evaluate(name=>openFile(name,'en'),name);else await page.evaluate(name=>showPreview(name),name);
   const selector=surface==='directory'?'#directory-preview-content':'#preview-content';const media=page.locator(selector+' video,'+selector+' audio');
   let initial;
   if(baseline){
    await page.waitForFunction(sel=>{const m=document.querySelector(sel+' video,'+sel+' audio');return m&&m.duration>30;},selector);
    initial=await media.evaluate(m=>({preload:m.preload,autoplay:m.autoplay,time:m.currentTime,duration:m.duration,buffered:m.buffered.length}));
    await media.evaluate(async m=>{m.muted=true;await m.play();});
   }else{
    await page.locator(selector+' .media-preview-player[data-state="paused"]').waitFor();
    initial=await media.evaluate(m=>({preload:m.preload,autoplay:m.autoplay,src:m.getAttribute('src'),ready:m.readyState,buffered:m.buffered.length}));
    const initialBytes=bytesFor(name);await sleep(500);assert.equal(bytesFor(name),initialBytes,'initial metadata reads stop');
    initial.readBytes=initialBytes-sourceStart;initial.totalBytes=files[name].size;initial.noFurtherBytes=true;assert.equal([...active].filter(r=>r.name===name).length,0);
    await media.evaluate(m=>{m.muted=true;m.volume=.4;m.playbackRate=1.25;});
    // User preferences can be changed while released too.
    await page.locator(selector+' .media-preview-resume').click();
   }
   await page.waitForFunction(sel=>document.querySelector(sel+' video,'+sel+' audio').currentTime>.3,selector);
   if(!baseline)await media.evaluate(m=>{m.volume=.4;m.playbackRate=1.25;m.muted=true;});
   await media.evaluate(m=>m.pause());const pausedAt=bytesFor(name);await sleep(1500);
   const after=await media.evaluate(m=>({src:m.getAttribute('src'),currentSrc:m.currentSrc,time:m.currentTime,ready:m.readyState,buffered:m.buffered.length,paused:m.paused,poster:m.poster||null}));
   const result={surface,name,size:files[name].size,initial,pauseReceivedBytes:bytesFor(name)-pausedAt,after};
   if(!baseline){
    assert.equal(after.src,null);assert.equal(after.ready,0);assert.equal(after.buffered,0);assert.equal(after.paused,true);
    const stable=bytesFor(name);await sleep(500);assert.equal(bytesFor(name),stable,'no continuing paused media response');assert.equal([...active].filter(r=>r.name===name).length,0);
    const selected=Number(await page.locator(selector+' .media-preview-position').inputValue());assert(selected>.1);
    if(name.endsWith('.mp4')||name.endsWith('.webm')){
      assert(after.poster?.startsWith('data:image/jpeg'));
      result.poster=await page.evaluate(src=>new Promise(resolve=>{const i=new Image();i.onload=()=>resolve({width:i.width,height:i.height});i.src=src;}),after.poster);
      assert(result.poster.width<=640&&result.poster.height<=360);after.poster='bounded JPEG poster';
    }
    const target=name.endsWith('.mp4')||name.endsWith('.webm')?50:100;
    const marker=requests.length;
    await page.locator(selector+' .media-preview-position').evaluate((slider,target)=>{slider.value=target;slider.dispatchEvent(new Event('input'));},target);
    await page.locator(selector+' .media-preview-resume').click();
    await page.waitForFunction(({selector,target})=>{const m=document.querySelector(selector+' video,'+selector+' audio');return m.currentTime>target+.1&&!m.seeking;},{selector,target},{timeout:30000});
    result.lateRanges=requests.slice(marker).filter(r=>r.name===name&&r.start>files[name].size/2).map(r=>r.range);
    assert(result.lateRanges.length>0,'resume selected unbuffered position uses range');
    assert.equal(await page.locator('video[src],audio[src]').count(),1);
    assert.deepEqual(await media.evaluate(m=>[m.volume,m.playbackRate,m.muted]),[.4,1.25,true]);
    result.restoredPreferences=true;
    const old=await media.elementHandle();
    if(surface==='directory')await page.evaluate(()=>preview.close());else await page.evaluate(()=>closePreview());
    await sleep(250);assert(await old.evaluate(m=>m.readyState===0&&m.buffered.length===0&&!m.hasAttribute('src')&&!m.hasAttribute('poster')));await old.dispose();
    result.cleanup=true;
   }
   results.push(result);
   if(surface==='directory')await page.evaluate(()=>preview.close());else await page.evaluate(()=>closePreview());
   await sleep(100);
  }
 }
 if(!baseline){
  for(const surface of ['directory','temporary']){
   await page.goto(`http://127.0.0.1:${server.address().port}/${surface==='directory'?'directory':''}`);
   if(surface==='temporary')await page.waitForFunction(()=>Object.keys(window.previewFiles||{}).length>0);
   const selector=surface==='directory'?'#directory-preview-content':'#preview-content';
   for(const [index,locale] of ['en','zh-CN','zh-TW','zh-HK'].entries()){
    await page.setViewportSize({width:320,height:740});
    await page.evaluate(dark=>{document.documentElement.dataset.theme=dark?'dark':'light';},index%2);
    if(surface==='directory')await page.evaluate(locale=>openFile('demo.mp4',locale),locale);
    else await page.evaluate(locale=>{i18n=LegnaWebLocales[locale];uiLabels=i18n.webUi;showPreview('demo.mp4');},locale);
    await page.locator(selector+' .media-preview-player[data-state="paused"]').waitFor();
    const expected=await page.evaluate(locale=>LegnaWebLocales[locale].webUi.mediaPlay,locale);
    assert.equal(await page.locator(selector+' .media-preview-resume').textContent(),expected);
    await page.locator(selector+' .media-preview-resume').click();
    await page.waitForFunction(sel=>document.querySelector(sel+' video').currentTime>.2,selector);
    await page.locator(selector+' video').evaluate(m=>m.pause());
    await page.locator(selector+' .media-preview-player[data-state="paused"]').waitFor();
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'320px horizontal overflow');
    const sizes=await page.locator(selector+' .media-preview-resume,'+selector+' .media-preview-position').evaluateAll(ns=>ns.map(n=>({w:n.getBoundingClientRect().width,h:n.getBoundingClientRect().height})));
    assert(sizes.every(n=>n.w>=44&&n.h>=44));
    const contrast=await page.locator(selector+' .media-preview-resume').evaluate(n=>{
     function lum(s){const a=s.match(/[\d.]+/g).slice(0,3).map(Number).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;});return .2126*a[0]+.7152*a[1]+.0722*a[2];}
     const css=getComputedStyle(n),a=lum(css.color),b=lum(css.backgroundColor);return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
    });assert(contrast>=4.5);
    await page.screenshot({path:path.join(evidence,`${surface}-${locale}-paused.png`)});
    results.push({surface,locale,width:320,theme:index%2?'dark':'light',touchTargets:sizes,textContrast:contrast,pausedPoster:true});
    if(surface==='directory')await page.evaluate(()=>preview.close());else await page.evaluate(()=>closePreview());
   }
  }
  // Native fullscreen retains native controls while paused: the sibling resume
  // button is not reachable there. Exiting that presentation releases resources.
  await page.setViewportSize({width:1000,height:780});await page.goto(`http://127.0.0.1:${server.address().port}/directory`);
  await page.evaluate(()=>openFile('demo.mp4','en'));await page.locator('.media-preview-player[data-state="paused"]').waitFor();
  await page.locator('.media-preview-resume').click();await page.waitForFunction(()=>document.querySelector('video').currentTime>.2);
  await page.locator('video').evaluate(m=>m.requestFullscreen());await page.locator('video').evaluate(m=>m.pause());await sleep(300);
  assert(await page.locator('video').evaluate(m=>m.hasAttribute('src')&&m.controls&&m.paused));
  await page.locator('video').evaluate(m=>m.play());await page.waitForFunction(()=>!document.querySelector('video').paused);
  await page.locator('video').evaluate(m=>m.pause());await page.evaluate(()=>document.exitFullscreen());
  await page.locator('.media-preview-player[data-state="paused"]').waitFor();assert.equal(await page.locator('video').getAttribute('src'),null);
  results.push({nativeFullscreenPauseResume:true,releaseAfterFullscreenExit:true});
  await page.evaluate(()=>preview.close());
  await page.evaluate(()=>openFile('demo.mp4','en'));await page.locator('.media-preview-player[data-state="paused"]').waitFor();
  const superseded=await page.locator('video').elementHandle();
  await page.locator('.media-preview-resume').click();
  await page.evaluate(()=>openFile('demo.wav','en'));await page.locator('.media-preview-player[data-state="paused"]').waitFor();
  await sleep(250);assert.equal(await page.locator('video').count(),0);assert.equal(await page.locator('audio').count(),1);
  assert(await superseded.evaluate(m=>!m.hasAttribute('src')&&m.readyState===0&&m.buffered.length===0));await superseded.dispose();
  results.push({switchWhileResuming:true,onePlayer:true,oldSourceReleased:true});await page.evaluate(()=>preview.close());
 }
 if(baseline)assert(results.some(r=>r.pauseReceivedBytes>32768),'baseline must reproduce extra bytes after pause');
 fs.writeFileSync(path.join(evidence,baseline?'baseline.json':'results.json'),JSON.stringify({browser:browser.version(),host:process.platform,serverThrottle:'8192 bytes / 20ms per response',results,errors},null,2)+'\n');
 console.log(JSON.stringify(results));assert.deepEqual(errors,[]);
}
run().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));fs.rmSync(fixture,{recursive:true,force:true});});
