'use strict';
// Generated media/documents against the real Rust server in an isolated browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const {createHash} = require('node:crypto');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..');
const root = fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-directory-preview-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(),'legnasend-directory-preview-evidence');
let fixture, browser, output = '', errors = [], responses = [];
const sha = data => createHash('sha256').update(data).digest('hex');
async function until(check) { for(let i=0;i<400;i++){let value=await check();if(value)return value;await new Promise(r=>setTimeout(r,25));}throw new Error('condition timed out'); }
async function command(value) {const at=output.length;fixture.stdin.write(value+'\n');await until(()=>output.slice(at).includes('revision'));}
function ffmpeg(args) {const result=spawnSync(process.env.FFMPEG_PATH || 'ffmpeg',['-hide_banner','-loglevel','error','-y',...args],{encoding:'utf8',timeout:30000});assert.equal(result.status,0,result.stderr || String(result.error));}
(async()=>{
  fs.mkdirSync(evidence,{recursive:true});fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));
  const notes=Buffer.from('<script>literal text, not markup</script>\n'+'碧绿阅读器 · wrapping content '.repeat(3)+'\n'+('普通行 LegnaSend readable text\n'.repeat(90000))+'END-NEEDLE-LEGNA\n');
  fs.writeFileSync(path.join(root,'a','notes.txt'),notes);
  fs.writeFileSync(path.join(root,'a','readme.md'),'# LegnaSend 阅读体验\n\nA **compact** Markdown document.\n\n- 保留正文搜索\n- 自动换行\n\n| File | Status |\n| --- | --- |\n| TXT | Ready |\n\n<script>window.previewXss=1</script>\n\n![external](https://example.invalid/remote.png)\n\n[unsafe](javascript:alert(1))\n');
  fs.writeFileSync(path.join(root,'a','active.svg'),'<svg onload="alert(1)"/>');
  fs.writeFileSync(path.join(root,'a','active.html'),'<script>alert(1)</script>');
  fs.writeFileSync(path.join(root,'b','isolated.txt'),'unrelated workspace');
  ffmpeg(['-f','lavfi','-i','testsrc2=size=320x180:rate=24','-t','10','-c:v','libx264','-preset','ultrafast','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',path.join(root,'a','sample.mp4')]);
  ffmpeg(['-f','lavfi','-i','sine=frequency=440:sample_rate=16000','-t','5',path.join(root,'a','tone.wav')]);
  ffmpeg(['-i',path.join(root,'a','sample.mp4'),'-frames:v','1',path.join(root,'a','image.png')]);
  fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{stdio:['pipe','pipe','pipe']});
  fixture.stdout.on('data',data=>output+=data);fixture.stderr.on('data',data=>process.stderr.write(data));
  const url=await until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const context=await browser.newContext({viewport:{width:1100,height:850},locale:'zh-CN'});
  const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
  page.on('response',response=>{if(response.url().includes('/content?'))responses.push({url:response.url(),method:response.request().method(),range:response.request().headers().range,status:response.status()});});
  await page.goto(url+'design/');await page.locator('.preview-button').first().waitFor();
  assert.equal(await page.locator('.preview-button').count(),5);
  for(const name of ['active.svg','active.html'])assert.equal(await page.locator(`.row[title="${name}"] .preview-button`).count(),0);
  const dialog=page.locator('#directory-preview');
  async function open(name){await page.locator(`.row[title="${name}"] .preview-button`).click();await page.locator('#directory-preview[open]').waitFor();}
  async function close(){await page.locator('#directory-preview-close').click();await page.locator('#directory-preview[open]').waitFor({state:'hidden'});assert.equal(await page.locator('#directory-preview-content').innerText(),'');}
  async function reader(){await page.waitForFunction(()=>document.querySelectorAll('#directory-preview .text-row').length>0);}
  await open('notes.txt');await reader();
  const virtualRows=await page.locator('#directory-preview .text-row').count();assert.ok(virtualRows<=40);
  const noteId=Buffer.from('notes.txt').toString('base64url');
  const firstReads=responses.filter(r=>r.method==='GET'&&r.url.includes('/'+noteId+'/content')&&r.range);
  assert.ok(firstReads.length>0);
  const firstTextBytes=firstReads.reduce((sum,r)=>{const [,a,b]=r.range.match(/^bytes=(\d+)-(\d+)$/);return sum+Number(b)-Number(a)+1;},0);
  assert.ok(firstTextBytes<=65536);
  assert.equal(await page.locator('#directory-preview .text-nowrap').count(),0);
  assert.equal(await page.locator('#directory-preview-content script').count(),0);
  assert.match(await page.locator('#directory-preview-content').innerText(),/<script>literal text/);
  await page.keyboard.press('Control+f');assert.equal(await page.locator('.text-query').evaluate(e=>e===document.activeElement),true);
  await page.locator('.text-search select').selectOption('full');
  await page.locator('.text-query').fill('END-NEEDLE-LEGNA');
  await page.waitForFunction(()=>document.querySelector('[data-current-match]')?.textContent==='END-NEEDLE-LEGNA');
  await page.screenshot({path:path.join(evidence,'directory-preview-text-desktop.png')});
  const downloadEvent=page.waitForEvent('download');await page.locator('#directory-preview-download').click();
  const download=await downloadEvent;assert.equal(await download.failure(),null);assert.equal(sha(fs.readFileSync(await download.path())),sha(notes));
  await close();
  const headsAfterClose=responses.filter(r=>r.method==='HEAD').length;
  await page.waitForTimeout(3300);assert.equal(responses.filter(r=>r.method==='HEAD').length,headsAfterClose);
  await open('readme.md');await page.locator('.markdown-document h1').waitFor();
  assert.equal(await page.locator('.markdown-document h1').innerText(),'LegnaSend 阅读体验');
  assert.equal(await page.locator('.markdown-document table').count(),1);
  assert.equal(await page.locator('.markdown-document script,.markdown-document img,.markdown-document [href^="javascript:"]').count(),0);
  assert.equal(await page.evaluate(()=>window.previewXss),undefined);
  await page.locator('.text-query').fill('保留正文搜索');
  await page.waitForFunction(()=>document.querySelector('[data-current-match]')?.textContent==='保留正文搜索');
  await close();
  await open('image.png');await page.waitForFunction(()=>document.querySelector('#directory-preview img')?.naturalWidth===320);await close();
  for(const [name,type,duration] of [['sample.mp4','video',9],['tone.wav','audio',4]]){
    await open(name);
    await page.waitForFunction(([type,duration])=>document.querySelector('#directory-preview '+type)?.duration>duration,[type,duration]);
    const media=page.locator('#directory-preview '+type);
    assert.equal(await media.getAttribute('preload'),'metadata');
    await media.evaluate(async el=>{el.muted=true;await el.play();});
    await page.waitForFunction(type=>document.querySelector('#directory-preview '+type)?.currentTime>0.05,type);
    await media.evaluate(el=>{el.pause();el.currentTime=2;});
    await page.waitForFunction(type=>document.querySelector('#directory-preview '+type)?.currentTime>=1.9,type);
    if(type==='video')await page.screenshot({path:path.join(evidence,'directory-preview-video-desktop.png')});
    const handle=await media.elementHandle();await close();
    assert.equal(await handle.evaluate(el=>!el.hasAttribute('src')&&el.paused),true);await handle.dispose();
  }
  for(const name of ['sample.mp4','tone.wav']){const id=Buffer.from(name).toString('base64url');assert.ok(responses.some(r=>r.range&&r.status===206&&r.url.includes('/'+id+'/content')&&r.url.includes('version=')));}
  // Failed reads show an in-page retry and do not leave stale cached content behind.
  async function resumeProtection(){
    await page.waitForFunction(()=>document.querySelector('#auth').open||!document.querySelector('#unlock').hidden||document.querySelector('#directory-preview').open&&!document.querySelector('#directory-preview-retry').hidden,null,{timeout:10000});
    await page.evaluate(()=>{if(!document.querySelector('#auth').open&&document.querySelector('#directory-preview').open)document.querySelector('#directory-preview-retry').click();});
    await page.waitForFunction(()=>document.querySelector('#auth').open||!document.querySelector('#unlock').hidden);
    await page.evaluate(()=>{if(!document.querySelector('#auth').open)document.querySelector('#unlock').click();});
    await page.locator('#auth[open]').waitFor();
  }
  let injected=false;
  await page.route('**/content?**',route=>{
    if(!injected&&route.request().headers().range){injected=true;return route.fulfill({status:503,body:'temporary failure'});}return route.continue();
  });
  await open('notes.txt');await page.locator('#directory-preview-retry:not([hidden])').waitFor();assert.equal(await page.locator('#directory-preview-content').innerText(),'');
  await page.unroute('**/content?**');await page.locator('#directory-preview-retry').click();await reader();
  const pinned=responses.findLast(r=>r.method==='GET'&&r.url.includes('version='))?.url;
  fs.appendFileSync(path.join(root,'a','notes.txt'),'source changed\n');
  await page.waitForFunction(()=>document.querySelector('#directory-preview-retry').hidden===false&&document.querySelector('#directory-preview-content').textContent==='',null,{timeout:10000});
  assert.equal((await context.request.get(pinned)).status(),412);
  assert.equal(await page.locator('#directory-preview-content').innerText(),'');
  await close();
  // Protection changes revoke a fully loaded reader without a user refresh.
  await page.locator('.preview-button').first().waitFor();await open('readme.md');await page.locator('.markdown-document h1').waitFor();
  await command('protect-a');await resumeProtection();
  assert.equal(await dialog.getAttribute('open'),null);assert.equal(await page.locator('#directory-preview-content').innerText(),'');
  await page.locator('#auth-password').fill('fixture-password');await page.locator('#auth-submit').click();await page.locator('#auth[open]').waitFor({state:'hidden'});
  await open('readme.md');await page.locator('.markdown-document h1').waitFor();
  await command('rotate-a');await resumeProtection();
  assert.equal(await page.locator('#directory-preview-content').innerText(),'');
  await page.locator('#auth-password').fill('changed-password');await page.locator('#auth-submit').click();await page.locator('#auth[open]').waitFor({state:'hidden'});
  await open('readme.md');await page.locator('.markdown-document h1').waitFor();
  const logout=await context.request.post(url+'api/legnasend/v1/workspaces/11111111-1111-4111-8111-111111111111/logout',{data:{}});assert.equal(logout.status(),200);
  await page.locator('#auth[open]').waitFor({timeout:10000});assert.equal(await page.locator('#directory-preview-content').innerText(),'');
  await page.locator('#auth-password').fill('changed-password');await page.locator('#auth-submit').click();await page.locator('#auth[open]').waitFor({state:'hidden'});
  await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});await page.locator('#language').selectOption('zh-TW');
  await open('readme.md');await page.locator('.markdown-document h1').waitFor();
  assert.equal(await page.locator('#directory-preview-close').innerText(),'關閉預覽');
  assert.equal(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth),true);
  assert.equal(await page.locator('#directory-preview-download').evaluate(el=>el.getBoundingClientRect().bottom<=innerHeight),true);
  await page.screenshot({path:path.join(evidence,'directory-preview-markdown-mobile-hant.png')});
  await close();await page.locator('#language').selectOption('en');await open('notes.txt');await reader();
  assert.equal(await page.locator('#directory-preview-close').innerText(),'Close preview');
  assert.equal(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth),true);
  assert.equal(await page.locator('.text-search').evaluate(el=>Math.abs(el.querySelector('.text-query').getBoundingClientRect().top-el.querySelector('.text-search-clear').getBoundingClientRect().top)<5),true);
  await page.screenshot({path:path.join(evidence,'directory-preview-text-mobile-en.png')});
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
  assert.equal(await dialog.getAttribute('open'),null);assert.equal(await page.locator('#directory-preview-content').innerText(),'');
  await page.evaluate(()=>{delete document.hidden;});
  await open('readme.md');await page.locator('.markdown-document h1').waitFor();await command('close-a');
  await page.waitForFunction(()=>!document.querySelector('#directory-preview').open||!document.querySelector('#directory-preview-retry').hidden&&document.querySelector('#directory-preview-content').textContent==='',null,{timeout:10000});
  if(await page.locator('#directory-preview[open]').count())await close();
  assert.equal((await context.request.get(url+'private/?meta')).status(),200);
  const fallback=await context.newPage();fallback.on('pageerror',e=>errors.push(e.message));
  await fallback.route('**/assets/directory-preview.js',route=>route.abort());
  await fallback.goto(url+'private/');await fallback.locator('.file-link').waitFor();
  assert.equal(await fallback.locator('.preview-button').count(),0);
  const fallbackEvent=fallback.waitForEvent('download');await fallback.locator('.file-link').click();
  const original=await fallbackEvent;assert.equal(await original.failure(),null);
  assert.equal(fs.readFileSync(await original.path(),'utf8'),'unrelated workspace');await fallback.close();
  assert.deepEqual(errors,[]);
  const result={browser:browser.version(),host:process.platform,firstTextBytes,txtBytes:notes.length,txtDownloadSha256:sha(notes),virtualRows,fullContentSearch:true,markdownFormatting:true,markdownSourceSearch:true,activeContentExcluded:true,media:['MP4','WAV','PNG'],range206:true,sourceVersion412:true,retry:true,passwordChangeRevokesPreview:true,logoutRevokesPreview:true,closeStopsHeadPolling:true,hiddenPageClearsPreview:true,independentWorkspaceRetained:true,missingPreviewAssetRetainsDownloads:true,languages:['zh-CN','zh-TW','en'],viewports:[1100,390],pageErrors:errors};
  fs.writeFileSync(path.join(evidence,'directory-preview-results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{
  if(browser)await browser.close();
  if(fixture){fixture.stdin.write('quit\n');await new Promise(resolve=>{fixture.once('exit',resolve);setTimeout(()=>{fixture.kill('SIGTERM');resolve();},3000).unref();});}
  fs.rmSync(root,{recursive:true,force:true});
});
