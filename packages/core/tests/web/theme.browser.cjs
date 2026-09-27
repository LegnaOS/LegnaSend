'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-theme-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-theme-evidence');
let fixture, directoryFixture, browser, output = '', directoryOutput = ''; let uploadPreserved = false; const results = [], errors = [];
function contrastAudit() {
  const rgb = value => { const n = value.match(/[\d.]+/g)?.map(Number); return n?.length >= 3 ? [n[0],n[1],n[2],n[3] ?? 1] : [0,0,0,0]; };
  const over = (a,b) => [0,1,2].map(i => a[i]*a[3]+b[i]*(1-a[3])).concat(1);
  const light = c => c.slice(0,3).map(v => v/255).map(v => v <= .04045 ? v/12.92 : ((v+.055)/1.055)**2.4).reduce((s,v,i) => s+v*[.2126,.7152,.0722][i],0);
  const ratio = (a,b) => { const x=light(a),y=light(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05); };
  const rows=[];
  const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
  for(let text;text=walker.nextNode();) {
    if(!text.textContent.trim())continue;
    const el=text.parentElement;if(!el||el.closest('script,style,noscript,option,svg,[hidden],[inert]'))continue;
    const range=document.createRange();range.selectNodeContents(text);const rect=range.getBoundingClientRect();
    if(!rect.width||!rect.height||rect.bottom<0||rect.top>innerHeight||rect.right<0||rect.left>innerWidth)continue;
    const style=getComputedStyle(el);if(style.visibility!=='visible')continue;
    let opacity=1,stack=[];for(let n=el;n;n=n.parentElement){const s=getComputedStyle(n);opacity*=Number(s.opacity);stack.push(rgb(s.backgroundColor));}
    if(opacity===0)continue;
    let bg=[255,255,255,1];stack.reverse().forEach(c=>bg=over(c,bg));
    let fg=rgb(style.color);fg[3]*=opacity;fg=over(fg,bg);
    const value=ratio(fg,bg);rows.push({text:text.textContent.trim().slice(0,90),selector:el.id||el.className||el.tagName,ratio:value,fg,bg});
  }
  return {count:rows.length,samples:rows,min:Math.min(...rows.map(r=>r.ratio)),failures:rows.filter(r=>r.ratio<4.5)};
}
async function ready(check) { for(let i=0;i<400;i++){const value=await check();if(value)return value;await new Promise(r=>setTimeout(r,25));}throw Error('condition timed out'); }
(async()=>{
  fs.mkdirSync(evidence,{recursive:true});
  fs.writeFileSync(path.join(root,'demo.txt'),'Readable text preview\n'+'LegnaSend theme contrast and wrapping. '.repeat(250));
  fs.writeFileSync(path.join(root,'demo.md'),'# Theme preview\n\nA paragraph with a [link](https://example.invalid).\n\n> Quoted content\n\n| Name | Value |\n| --- | --- |\n| contrast | 4.5 |\n\n```txt\nreadable code\n```\n');
  fixture=spawn(path.join(repo,'target/debug/examples/web_preview_fixture'),[root],{env:{...process.env,LEGNASEND_FIXTURE_MODE:'duplex'},stdio:['pipe','pipe','pipe']});
  fixture.stdout.on('data',d=>output+=d);fixture.stderr.on('data',d=>output+=d);
  const base=await ready(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  browser=await chromium.launch({executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  const context=await browser.newContext({viewport:{width:1120,height:900},colorScheme:'dark',locale:'en-US'});
  const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
  for(const width of [1120,390]) {
    await page.setViewportSize({width,height:900});
    for(const route of ['share','upload','download']) {
      await page.goto(base+route);await page.waitForSelector('.theme-selector');
      if(route==='share') {await page.waitForSelector('#pane-download iframe');await page.locator('#tab-upload').click();await page.waitForSelector('#pane-upload iframe');}
      if(route==='download') await page.waitForSelector('.file-row');
      for(const theme of ['light','dark']) {
        await page.locator('.theme-selector').selectOption(theme);
        await page.waitForFunction(v=>document.documentElement.dataset.theme===v,theme);
        for(const frame of page.frames()) {
          if(frame!==page.mainFrame()&&!await (await frame.frameElement()).isVisible())continue;
          await frame.waitForFunction(v=>document.documentElement.dataset.theme===v,theme);
          const audit=await frame.evaluate(contrastAudit);results.push({width,route,theme,frame:frame.url().replace(base,''),...audit});
        }
        await page.screenshot({path:path.join(evidence,`${route}-${width}-${theme}.png`)});
      }
      if(route==='share') {
        const original=page.frames().map(f=>f.url());
        await page.locator('#tab-download').click();await page.locator('.theme-selector').selectOption('light');
        assert.deepEqual(page.frames().map(f=>f.url()),original,'theme switches must not replace frames');
        const child=page.frames().find(f=>f.url().includes('/download?'));
        await child.waitForSelector('.file-row');results.push({width,route:'share-download',theme:'light',...(await child.evaluate(contrastAudit))});
      }
    }
  }
  await page.goto(base+'download');await page.waitForSelector('.file-row');
  for(const kind of ['demo.txt','demo.md']) {
    const row=page.locator('.file-row').filter({hasText:kind});await row.locator('button').first().click();
    await page.waitForSelector('#preview-overlay[style*="flex"], #preview-overlay[style*="block"], .text-viewport, .markdown-document');
    for(const theme of ['light','dark']) {
      await page.evaluate(value=>LegnaTheme.set(value),theme);
      await page.waitForTimeout(60);
      results.push({route:'preview-'+kind,theme,...await page.evaluate(contrastAudit)});
    }
    await page.locator('#preview-close').click();
  }
  // Preference persists; explicit light wins over a dark OS and system mode follows changes.
  await page.evaluate(()=>LegnaTheme.set('light'));await page.reload();
  assert.equal(await page.evaluate(()=>LegnaTheme.resolved()),'light');
  await page.locator('.theme-selector').selectOption('system');await page.emulateMedia({colorScheme:'light'});
  await page.waitForFunction(()=>LegnaTheme.resolved()==='light');
  await page.emulateMedia({colorScheme:'dark'});await page.waitForFunction(()=>LegnaTheme.resolved()==='dark');
  // Theme changes while a real iframe upload is in flight retain the same frame and file bytes.
  await page.goto(base+'share');await page.waitForSelector('#pane-download iframe');
  await page.locator('#tab-upload').click();await page.waitForSelector('#pane-upload iframe');
  const uploadFrame=page.frames().find(f=>f.url().includes('/upload?'));await uploadFrame.waitForSelector('#file-input',{state:'attached'});
  const cdp=await context.newCDPSession(page);await cdp.send('Network.enable');
  await cdp.send('Network.emulateNetworkConditions',{offline:false,latency:20,downloadThroughput:256*1024,uploadThroughput:128*1024});
  const binary=Buffer.alloc(1024*1024,71);
  await uploadFrame.locator('#file-input').setInputFiles({name:'theme-upload.bin',mimeType:'application/octet-stream',buffer:binary});
  await uploadFrame.waitForFunction(()=>{const p=document.querySelector('#transfer-progress');return p.value>0&&p.value<1;});
  for(const theme of ['light','dark','light']) {await page.locator('.theme-selector').selectOption(theme);await uploadFrame.waitForFunction(v=>document.documentElement.dataset.theme===v,theme);}
  assert.ok(page.frames().includes(uploadFrame));
  await ready(()=>output.includes('Received '));
  const sent=fs.readdirSync(path.join(root,'received')).flatMap(name=>{const file=path.join(root,'received',name,'theme-upload.bin');return fs.existsSync(file)?[file]:[];});
  assert.equal(sent.length,1);assert.deepEqual(fs.readFileSync(sent[0]),binary);uploadPreserved=true;
  await cdp.send('Network.emulateNetworkConditions',{offline:false,latency:0,downloadThroughput:-1,uploadThroughput:-1});
  // The directory index, list and password modal share the manual palette.
  fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));fs.writeFileSync(path.join(root,'a','readable.txt'),'A readable directory entry');
  directoryFixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{stdio:['pipe','pipe','pipe']});
  directoryFixture.stdout.on('data',d=>directoryOutput+=d);directoryFixture.stderr.on('data',d=>directoryOutput+=d);
  const directoryBase=await ready(()=>directoryOutput.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  for(const width of [1120,390]) {
    await page.setViewportSize({width,height:900});
    for(const route of ['','design/']) {
      await page.goto(directoryBase+route);await page.waitForSelector(route?'.row':'#index .card');
      for(const theme of ['light','dark']){await page.locator('.theme-selector').selectOption(theme);results.push({width,route:'directory-'+route,theme,...await page.evaluate(contrastAudit)});}
    }
  }
  directoryFixture.stdin.write('protect-a\n');await ready(()=>directoryOutput.includes('"revision":2'));
  await page.locator('#refresh').click();await page.waitForSelector('#auth[open]');
  for(const theme of ['light','dark']) {await page.evaluate(value=>LegnaTheme.set(value),theme);results.push({route:'directory-pin',theme,...await page.evaluate(contrastAudit)});}
  await page.screenshot({path:path.join(evidence,'directory-pin-390-dark.png')});
  fs.writeFileSync(path.join(evidence,'contrast.json'),JSON.stringify({results,errors,uploadPreserved},null,2));
  const failures=results.flatMap(r=>r.failures.map(f=>({route:r.route,width:r.width,theme:r.theme,...f})));
  console.log(JSON.stringify({checks:results.length,textNodes:results.reduce((n,r)=>n+r.count,0),min:Math.min(...results.map(r=>r.min)),failures,errors,uploadPreserved},null,2));
  assert.equal(failures.length,0);assert.deepEqual(errors,[]);
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();if(directoryFixture){directoryFixture.stdin.write('quit\n');await new Promise(r=>directoryFixture.once('exit',r));}if(fixture){fixture.kill('SIGINT');await new Promise(r=>fixture.once('exit',r));}fs.rmSync(root,{recursive:true,force:true});});
