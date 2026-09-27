'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legna-live-window-'));
const evidence=process.env.EVIDENCE_DIR||root;fs.mkdirSync(evidence,{recursive:true});fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));
for(let i=0;i<1200;i++)fs.writeFileSync(path.join(root,'a',`file-${String(i).padStart(4,'0')}.txt`),'original content\n');
const fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{stdio:['pipe','pipe','pipe']});let output='',browser;fixture.stdout.on('data',b=>output+=b);fixture.stderr.on('data',b=>process.stderr.write(b));
async function until(fn){for(let i=0;i<300;i++){let value=await fn();if(value)return value;await new Promise(r=>setTimeout(r,20));}throw Error('condition timed out');}
(async()=>{
 const url=await until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH});
 const context=await browser.newContext({viewport:{width:1000,height:800},locale:'en'}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const lists=[];page.on('response',r=>{if(r.url().includes('/files?'))lists.push(r.url());});
 await page.goto(url+'design/');await page.locator('.row').first().waitFor();
 for(let i=0;i<8;i++){await page.locator('#more').click();await page.waitForFunction(()=>!document.querySelector('#more').disabled);}
 await page.locator('#viewport').evaluate(e=>e.scrollTop=700*52+13);await page.waitForTimeout(100);
 const anchor=await page.locator('#viewport').evaluate(v=>{let rows=Array.from(v.querySelectorAll('.row'));let target=rows.find(r=>r.getBoundingClientRect().top<=v.getBoundingClientRect().top+2&&r.getBoundingClientRect().bottom>v.getBoundingClientRect().top+2);return {id:target.dataset.id,name:target.title};});
 const before=lists.length;fs.writeFileSync(path.join(root,'a','new-file.txt'),'new');
 await page.evaluate(()=>window.dispatchEvent(new Event('online')));
 await page.waitForFunction(id=>document.querySelector('#rows .row')?.dataset.id===id,anchor.id,{timeout:15000});
 assert.ok(lists.length-before<=3,'Refresh fetches bounded anchor continuations, not all retained pages');
 assert.equal(await page.locator('#viewport').evaluate(e=>e.scrollTop),13);
 assert.ok(await page.locator('#rows .row').count()<30);
 // Offline and synthetic BFCache restore preserve the actual current anchor.
 await context.setOffline(true);fs.writeFileSync(path.join(root,'a','offline-new.txt'),'new');await context.setOffline(false);
 await page.evaluate(()=>window.dispatchEvent(new Event('online')));await page.waitForTimeout(500);
 assert.equal(await page.locator('#rows .row').first().getAttribute('data-id'),anchor.id);
 await page.evaluate(()=>{window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});
 await page.waitForTimeout(500);assert.equal(await page.locator('#rows .row').first().getAttribute('data-id'),anchor.id);
 await page.locator('#rows .row').first().locator('.preview-button').click();await page.locator('#directory-preview .text-row').first().waitFor();
 fs.writeFileSync(path.join(root,'a',anchor.name),'replacement content with another size\n');
 await page.waitForFunction(()=>document.querySelector('#directory-preview-status').textContent.includes('file changed'),null,{timeout:10000});
 assert.equal(await page.locator('#directory-preview[open]').count(),1);assert.equal(await page.locator('#directory-preview-content').innerText(),'');
 await page.locator('#directory-preview-retry').click();await page.waitForFunction(()=>document.querySelector('#directory-preview-content').textContent.includes('replacement content'));
 assert.ok(!(await page.locator('#directory-preview-content').innerText()).includes('original content'));
 fs.unlinkSync(path.join(root,'a',anchor.name));await page.waitForFunction(()=>document.querySelector('#directory-preview-status').textContent.includes('removed'),null,{timeout:10000});
 assert.equal(await page.locator('#directory-preview[open]').count(),1);assert.equal(await page.locator('#directory-preview-content').innerText(),'');
 fs.writeFileSync(path.join(root,'a',anchor.name),'restored clean version\n');await page.locator('#directory-preview-retry').click();
 await page.waitForFunction(()=>document.querySelector('#directory-preview-content').textContent.includes('restored clean version'));
 assert.deepEqual(errors,[]);
 const result={anchor:anchor.name,anchorRefreshRequests:lists.slice(before).filter(u=>u.includes('anchor=')).length,initialRefreshBound:3,offlineReconnect:true,syntheticBFCacheRetainsAnchor:true,replacementStopsOldReader:true,retryFreshVersion:true,deletionNotice:true,recreatedFileRetry:true,errors};
 fs.writeFileSync(path.join(evidence,'browser-results.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();fixture.stdin.write('quit\n');await new Promise(resolve=>{fixture.once('exit',resolve);setTimeout(()=>{fixture.kill('SIGTERM');resolve();},2000).unref();});fs.rmSync(root,{recursive:true,force:true});});
