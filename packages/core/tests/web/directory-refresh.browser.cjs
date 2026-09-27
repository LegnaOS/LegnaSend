'use strict';
// Actual Chromium/HTTP/temporary filesystem. Visibility events are deliberately simulated.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-refresh-'));
const evidence=process.env.EVIDENCE_DIR||path.join(os.tmpdir(),'legnasend-refresh-evidence');fs.mkdirSync(evidence,{recursive:true});
fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));
for(let i=0;i<1200;i++)fs.writeFileSync(path.join(root,'a',`文件-${String(i).padStart(4,'0')}.txt`),'x');
fs.writeFileSync(path.join(root,'b','private.txt'),'private');fs.mkdirSync(path.join(root,'b','only-cache'));for(let i=0;i<600;i++)fs.writeFileSync(path.join(root,'b','only-cache',i+'.ls'),'fixture');fs.mkdirSync(path.join(root,'b','child'));fs.writeFileSync(path.join(root,'b','child','note.txt'),'note');
const fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{stdio:['pipe','pipe','pipe']});
let output='',browser;const errors=[],contrast=[];fixture.stdout.on('data',b=>output+=b);fixture.stderr.on('data',b=>process.stderr.write(b));
async function until(fn){for(let i=0;i<240;i++){let result=await fn();if(result)return result;await new Promise(r=>setTimeout(r,25));}throw Error('condition timed out');}
async function command(text){const before=output.length;fixture.stdin.write(text+'\n');await until(()=>output.slice(before).includes('revision'));}
(async()=>{
 const url=await until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const context=await browser.newContext({viewport:{width:1100,height:800},locale:'zh-CN'}),page=await context.newPage();
 page.on('pageerror',e=>errors.push(e.message));let lists=0,probes=0;
 page.on('request',r=>{if(r.url().includes('/files?'))lists++;if(r.url().includes('/state?'))probes++;});
 await page.goto(url+'design/');await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('100 '));assert.equal(lists,1);
 for(let n=2;n<=12;n++){const before=lists;await page.locator('#more').click();await until(()=>lists>before);await page.waitForFunction(()=>!document.querySelector('#more').disabled);}
 assert.match(await page.locator('#count').innerText(),/^201–1200 /);assert.ok(await page.locator('#rows .row').count()<=25);
 await page.locator('#previous').click();await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('101–200 '));
 await page.locator('#start').click();await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('100 '));
 await page.locator('#more').click();await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('200 '));
 await page.locator('#viewport').evaluate(e=>e.scrollTop=600);
 await page.waitForTimeout(100);
 const name=await page.locator('#rows .row').first().getAttribute('title');
 fs.writeFileSync(path.join(root,'a',name),Buffer.alloc(2500));
 // Let the real five-second foreground timer find the size change.
 await page.waitForFunction(name=>document.querySelector('.row[title="'+name+'"] .size')?.textContent==='2.4 KiB',name,{timeout:15000});
 const anchor=await page.locator('#viewport').evaluate(v=>Array.from(v.querySelectorAll('.row')).find(r=>r.getBoundingClientRect().top<=v.getBoundingClientRect().top+2&&r.getBoundingClientRect().bottom>v.getBoundingClientRect().top+2).dataset.id);
 const within=await page.locator('#viewport').evaluate(e=>e.scrollTop%52);
 fs.writeFileSync(path.join(root,'a','追加.txt'),'new');
 await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));
 await page.waitForFunction(id=>document.querySelector('#rows .row')?.dataset.id===id,anchor);
 assert.equal(await page.locator('#viewport').evaluate(e=>e.scrollTop),within);
 await page.screenshot({path:path.join(evidence,'directory-update-desktop.png')});
 async function sampleContrast(){return page.locator('#refresh').evaluate(el=>{const c=getComputedStyle(el);function lum(v){const x=v.match(/[\d.]+/g).slice(0,3).map(Number).map(x=>{x/=255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4;});return x[0]*.2126+x[1]*.7152+x[2]*.0722;}const a=lum(c.color),b=lum(c.backgroundColor);return {foreground:c.color,background:c.backgroundColor,ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)};});}
 contrast.push(await sampleContrast());await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);contrast.push(await sampleContrast());
 assert.ok(contrast.every(c=>c.ratio>=4.5));
 await page.screenshot({path:path.join(evidence,'directory-update-mobile-dark.png')});
 await page.setViewportSize({width:1100,height:800});await page.emulateMedia({colorScheme:'light'});
 await page.locator('#refresh').click();await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('100 '));
 await page.evaluate(()=>{window.__testHidden=true;Object.defineProperty(document,'hidden',{configurable:true,get:()=>window.__testHidden});document.dispatchEvent(new Event('visibilitychange'));});
 const paused=probes;await page.waitForTimeout(11000);assert.equal(probes,paused);
 const resumed=page.waitForResponse(r=>r.url().includes('/state?')&&r.status()===200);
 await page.evaluate(()=>{window.__testHidden=false;document.dispatchEvent(new Event('visibilitychange'));});await resumed;
 // The interrupted listing controller must be reusable after foreground restoration.
 await page.locator('#more').click();await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('200 '));
 const child=await context.newPage();child.on('pageerror',e=>errors.push(e.message));await child.goto(url+'private/');await child.locator('.row[title="only-cache"] .file-link').click();await child.waitForFunction(()=>document.querySelector('#status').textContent.includes('全部'));await child.locator('#path button').click();await child.locator('.row[title="child"] .file-link').click();await child.locator('.row[title="note.txt"]').waitFor();
 fs.rmSync(path.join(root,'b','child'),{recursive:true});await child.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));await child.locator('.row[title="private.txt"]').waitFor();await child.close();
 const index=await context.newPage();await index.goto(url);await index.locator('#index .card').waitFor();
 await command('close-a');await index.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));await index.waitForFunction(()=>!document.querySelector('#index .card'));
 await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));await page.waitForFunction(()=>document.querySelector('#viewport').hidden);assert.equal(await page.locator('.row').count(),0);
 await command('restore');await page.locator('#refresh').click();await page.locator('.row').first().waitFor();
 await command('protect-a');await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));await page.locator('#unlock').waitFor({state:'visible'});assert.equal(await page.locator('#auth[open]').count(),0);await page.locator('#unlock').click();await page.locator('#auth[open]').waitFor();
 await page.locator('#auth-password').fill('fixture-password');await page.locator('#auth-submit').click();await page.locator('.row').first().waitFor();
 await command('rotate-a');await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));await page.locator('#unlock').waitFor({state:'visible'});assert.equal(await page.locator('#auth[open]').count(),0);assert.equal(await page.locator('.row').count(),0);
 await page.locator('#unlock').click();await page.locator('#auth[open]').waitFor();await page.locator('#auth-password').fill('changed-password');
 // Foreground and network restoration must preserve an in-progress PIN form.
 await page.evaluate(()=>{document.dispatchEvent(new Event('visibilitychange'));window.dispatchEvent(new Event('online'));});await page.waitForTimeout(200);
 assert.equal(await page.locator('#auth[open]').count(),1);assert.equal(await page.locator('#auth-password').inputValue(),'changed-password');
 await page.locator('#auth-submit').click();await page.locator('.row').first().waitFor();
 const id='11111111-1111-4111-8111-111111111111';
 const logout=await context.request.post(url+`api/legnasend/v1/workspaces/${id}/logout`,{data:{}});assert.equal(logout.status(),200);
 await page.evaluate(()=>document.dispatchEvent(new Event('visibilitychange')));await page.locator('#unlock').waitFor({state:'visible'});assert.equal(await page.locator('.row').count(),0);assert.equal(await page.locator('#auth[open]').count(),0);
 await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});await page.locator('#language').selectOption('zh-TW');
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);await page.screenshot({path:path.join(evidence,'directory-locked-mobile.png')});
 assert.deepEqual(errors,[]);
 const result={entries:1200,windowEntries:1000,previousWindow:true,returnToStart:true,visibleSizeUpdateByRealTimer:true,deepChangePreservesScroll:true,syntheticHiddenPauseMs:11000,foregroundResume:true,reusableController:true,emptyContinuationAutofill:true,removedChildReturnsToParent:true,indexChange:true,closureClearsRows:true,revocationClearsWithoutModal:true,generationChangeDoesNotOpenModal:true,foregroundPreservesPasswordModal:true,networkRestorePreservesPasswordInput:true,maxRows:25,viewports:[1100,390],updateTagContrast:contrast,pageErrors:errors};
 fs.writeFileSync(path.join(evidence,'directory-refresh-results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();fixture.stdin.write('quit\n');await new Promise(resolve=>{fixture.once('exit',resolve);setTimeout(()=>{fixture.kill('SIGTERM');resolve();},3000).unref();});fs.rmSync(root,{recursive:true,force:true});});
