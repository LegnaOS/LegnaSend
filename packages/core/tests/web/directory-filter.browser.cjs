'use strict';
// Actual core HTTP + isolated Chromium. The one delayed old response is deliberate.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-directory-filter-'));
const evidence=process.env.EVIDENCE_DIR||path.join(os.tmpdir(),'legnasend-directory-filter-evidence');
fs.mkdirSync(evidence,{recursive:true});fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));
for(let i=0;i<10000;i++)fs.writeFileSync(path.join(root,'a',`${i%2?'Beta中文':'ALPHA'}-${String(i).padStart(5,'0')}.txt`),'x');
fs.writeFileSync(path.join(root,'a','needle-only-one.txt'),'needle');
fs.mkdirSync(path.join(root,'a','child'));fs.writeFileSync(path.join(root,'a','child','needle-only-one.txt'),'not recursive');
const fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{stdio:['pipe','pipe','pipe']});
let browser,output='',errors=[],pages=[],releaseOld;
fixture.stdout.on('data',bytes=>output+=bytes);fixture.stderr.on('data',bytes=>process.stderr.write(bytes));
async function until(check){for(let i=0;i<400;i++){const value=await check();if(value)return value;await new Promise(r=>setTimeout(r,25));}throw Error('condition timed out');}
(async()=>{
 const url=await until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const context=await browser.newContext({viewport:{width:1100,height:800},locale:'en'}),page=await context.newPage();
 page.on('pageerror',error=>errors.push(error.message));
 page.on('response',async response=>{if(response.url().includes('/files?')&&response.status()===200){try{const body=await response.json();pages.push({filter:body.filter,entries:body.entries.length,scanned:body.scanned,cursor:body.cursor});}catch(_){}}});
 await page.goto(url+'design/');await page.waitForFunction(()=>document.querySelector('#count').textContent==='100 items loaded');
 const input=page.locator('#directory-filter');await input.fill('needle-only-one');
 await page.waitForFunction(()=>document.querySelector('#more').hidden&&document.querySelector('#count').textContent==='1 matches loaded',{},{timeout:15000});
 assert.equal(await page.locator('.row').count(),1);assert.equal(await page.locator('.row').getAttribute('title'),'needle-only-one.txt');
 assert.ok(pages.filter(p=>p.filter==='needle-only-one').length>=19,'Server scans beyond the originally loaded page');
 assert.ok(pages.every(p=>p.scanned<=512&&p.entries<=100));
 await input.fill('ALPHA');await page.waitForFunction(()=>document.querySelector('#count').textContent==='100 matches loaded');
 for(let n=2;n<=12;n++){await page.locator('#more').click();await page.waitForFunction(n=>{const expected=n>10?`${(n-10)*100+1}–${n*100} matches loaded`:`${n*100} matches loaded`;return document.querySelector('#count').textContent===expected;},n);}
 assert.ok(await page.locator('.row').count()<=25);assert.match(await page.locator('.row').first().getAttribute('title'),/^ALPHA-/);
 // Hold one real ALPHA response, then search a different condition. A late old
 // page must neither replace the new rows nor append old results to its cursor.
 let hold=true,seen=false;
 const gate=new Promise(resolve=>releaseOld=resolve);
 await page.route('**/files?*',async route=>{
   const request=new URL(route.request().url());
   if(hold&&request.searchParams.get('filter')==='alpha'){
     hold=false;const response=await route.fetch();seen=true;await gate;
     try{await route.fulfill({response});}catch(_){}
   }else await route.continue();
 });
 await input.fill('alpha');await until(()=>seen);
 await input.fill('Beta中文');await page.waitForFunction(()=>document.querySelector('#count').textContent==='100 matches loaded'&&document.querySelector('.row')?.title.startsWith('Beta中文-'));
 releaseOld();await page.waitForTimeout(250);
 assert.ok((await page.locator('.row').evaluateAll(rows=>rows.map(row=>row.title))).every(name=>name.startsWith('Beta中文-')));
 for(const locale of ['en','zh-CN','zh-TW','zh-HK']){
   await page.locator('#language').selectOption(locale);assert.ok((await page.locator('#directory-filter-label').innerText()).length>0);
 }
 await input.fill('not-present-anywhere');await page.waitForFunction(()=>document.querySelector('#more').hidden&&document.querySelector('#status').textContent.includes('沒有符合'),{},{timeout:15000});
 assert.equal(await page.locator('.row').count(),0);
 await page.locator('#directory-filter-clear').click();await page.waitForFunction(()=>document.querySelector('#count').textContent.startsWith('100 '));
 assert.equal(await input.inputValue(),'');
 await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark'});
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 await page.screenshot({path:path.join(evidence,'directory-filter-mobile-dark.png')});
 assert.deepEqual(errors,[]);
 const result={sourceEntries:10000,coreExactMatchingEntries:5000,sparseFilterScansWholeCurrentDirectory:true,noRecursiveSearch:true,lateResponseIgnored:true,metadataWindow:1000,maxVisibleRows:25,requestMaxScan:512,languages:['en','zh-CN','zh-TW','zh-HK'],emptyResult:true,clearRestoresList:true,pageErrors:errors};
 fs.writeFileSync(path.join(evidence,'directory-filter-results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{if(releaseOld)releaseOld();if(browser)await browser.close();fixture.stdin.write('quit\n');await new Promise(resolve=>{fixture.once('exit',resolve);setTimeout(()=>{fixture.kill('SIGTERM');resolve();},3000).unref();});fs.rmSync(root,{recursive:true,force:true});});
