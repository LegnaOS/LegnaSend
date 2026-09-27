// Real workspace selected ZIP: cross-page UI selections, short tickets, native download.
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn,execFileSync}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-large-workspace-selection-'));
const evidence=process.env.EVIDENCE_DIR||path.join(os.tmpdir(),'legnasend-large-workspace-selection-evidence');fs.mkdirSync(evidence,{recursive:true});
const count=5200;fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));
for(let i=0;i<count;i++)fs.writeFileSync(path.join(root,'a',String(i).padStart(5,'0')+'.txt'),'entry '+i+'\n');
let fixture,browser,page,output='';const errors=[],requests=[],responses=[];let oldBackend=false,holdPrepare=false,releasePrepare=null;const downloads=[];
async function until(fn){for(let i=0;i<1200;i++){if(await fn())return;await new Promise(r=>setTimeout(r,25));}throw Error('condition timed out');}
(async()=>{
 fixture=spawn(process.env.DIRECTORY_FIXTURE||path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root]);fixture.stdout.on('data',d=>output+=d);fixture.stderr.on('data',d=>process.stderr.write(d));
 await until(()=>/http:\/\/127\.0\.0\.1:\d+\//.test(output));const base=output.match(/http:\/\/127\.0\.0\.1:\d+\//)[0];
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 page=await browser.newPage({acceptDownloads:true,viewport:{width:1080,height:900},locale:'en'});page.on('pageerror',e=>errors.push(e.message));page.on('download',d=>downloads.push(d));page.on('response',async r=>{if(/\/(prepare-archive|cancel-archive)\?/.test(r.url())){let body=null;try{body=await r.json();}catch(_){}responses.push({url:r.url(),status:r.status(),body});}});
 await page.addInitScript(()=>{window.__archiveFetches=[];const original=window.fetch;window.fetch=function(input,...args){const url=typeof input==='string'?input:input.url;if(/\/archive\?/.test(url))window.__archiveFetches.push(url);return original.call(this,input,...args);};});
 await page.context().route('**/*',async route=>{
  const request=route.request();if(!request.url().startsWith(base))return route.abort();
  if(request.url().includes('/?meta')&&oldBackend){const response=await route.fetch(),data=await response.json();delete data.capabilities.archiveSelection;return route.fulfill({response,json:data});}
  if(/\/(prepare-archive|cancel-archive|archive)\?/.test(request.url()))requests.push({url:request.url(),method:request.method(),navigation:request.isNavigationRequest(),body:request.postData()});
  if(request.url().includes('/prepare-archive?')&&holdPrepare){holdPrepare=false;const response=await route.fetch();await new Promise(resolve=>releasePrepare=resolve);return route.fulfill({response});}
  return route.continue();
 });
 await page.goto(base+'design/');await page.locator('#language').selectOption('en');await page.locator('#select-loaded').waitFor();
 assert.equal(await page.locator('#select-loaded').textContent(),'Select loaded');
 let peakRows=0;
 // Each iteration is an explicit click on already loaded content, never an app-wide auto-enumeration.
 for(let n=0;n<100;n++){
  await until(async()=>!(await page.locator('#select-loaded').isDisabled()));await page.locator('#select-loaded').click();
  peakRows=Math.max(peakRows,await page.locator('#rows .row').count());
  const selected=parseInt(await page.locator('#selection-count').textContent(),10);if(selected===count)break;
  assert.ok(selected<count);const before=await page.locator('#count').textContent();await page.locator('#more').click();
  await until(async()=>(await page.locator('#count').textContent())!==before);
 }
 assert.equal(parseInt(await page.locator('#selection-count').textContent(),10),count);assert.ok(peakRows<=30);
 // Revisit a page after its virtual window was evicted; all choices remain bound to this folder.
 await page.locator('#previous').click();await until(async()=>!(await page.locator('#select-loaded').isDisabled()));
 assert.equal(parseInt(await page.locator('#selection-count').textContent(),10),count);
 assert.ok(await page.locator('#rows input.directory-select').first().isChecked());
 // Hold a real prepared receipt after server allocation, then cancel in-page.
 // Its late token must be revoked rather than launching a stale browser download.
 holdPrepare=true;await page.locator('#download-selection').click();await until(()=>releasePrepare!==null);
 assert.equal(await page.locator('#cancel-archive-selection').textContent(),'Cancel preparation');
 await page.locator('#cancel-archive-selection').click();releasePrepare();
 await until(()=>requests.some(r=>r.url.includes('/cancel-archive?')));await page.waitForTimeout(100);assert.equal(downloads.length,0);
 const cancelledBeforeDownload=requests.filter(r=>r.url.includes('/cancel-archive?')).length;
 const [download]=await Promise.all([page.waitForEvent('download',{timeout:120000}),page.locator('#download-selection').click()]);
 assert.equal(await download.failure(),null);assert.ok(download.url().length<250);assert.ok(download.url().includes('selection='));
 const zip=path.join(root,'selected.zip');await download.saveAs(zip);
 const verified=JSON.parse(execFileSync('/usr/bin/python3',['-c',`import sys,zipfile,json,hashlib
with zipfile.ZipFile(sys.argv[1]) as z:
 assert z.testzip() is None
 names=[item.filename for item in z.infolist() if not item.is_dir()]
 directories=[item.filename for item in z.infolist() if item.is_dir()]
 assert directories==['files/'],directories
 assert len(names)==5200,len(names)
 assert set(names)=={'files/'+str(i).zfill(5)+'.txt' for i in range(5200)}
 for name in names:
  assert z.read(name)==('entry '+str(int(name.rsplit('/',1)[-1][:-4]))+'\\n').encode()
 print(json.dumps({'files':len(names),'entries':len(z.infolist()),'directories':directories,'sha256':hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()}))`,zip],{encoding:'utf8'}));
 const prepared=requests.filter(r=>r.url.includes('/prepare-archive?'));assert.equal(prepared.length,2);assert.equal(JSON.parse(prepared[0].body).ids.length,count);assert.equal(prepared[0].navigation,false);
 // Chromium may bypass Playwright routing for native browser downloads. The
 // actual saved ZIP comes from a Rust endpoint serving only GET/HEAD; assert
 // native download plus no fetch of archive bytes, not a fabricated route event.
 assert.equal(downloads.length,1);assert.deepEqual(await page.evaluate(()=>window.__archiveFetches),[]);
 for(const request of requests.filter(r=>r.url.includes('/archive?'))){assert.equal(request.method,'GET');assert.equal(request.navigation,true);}
 await page.locator('#refresh').click();await page.locator('#select-loaded').waitFor();assert.equal(requests.filter(r=>r.url.includes('/cancel-archive?')).length,cancelledBeforeDownload,'refresh must not silently cancel native browser download');
 await page.setViewportSize({width:320,height:844});for(const language of['en','zh-CN','zh-TW','zh-HK']){await page.locator('#language').selectOption(language);await page.waitForTimeout(30);assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));}
 await page.screenshot({path:path.join(evidence,'selection-320.png')});
 // Actual old GET path remains reachable when an older server omits the capability.
 oldBackend=true;await page.reload();await page.locator('#language').selectOption('en');await page.locator('#rows input.directory-select').first().check();
 assert.match(await page.locator('#select-loaded').textContent(),/128/);
 const [legacy]=await Promise.all([page.waitForEvent('download'),page.locator('#download-selection').click()]);assert.equal(await legacy.failure(),null);assert.ok(legacy.url().includes('ids='));
 assert.equal(requests.filter(r=>r.url.includes('/prepare-archive?')).length,2);assert.deepEqual(errors,[]);
 const summary={...verified,selected:count,peakRows,shortUrl:download.url().length,legacyGet:true,latePrepareCancelled:true,nativeDownloads:downloads.length,pageArchiveFetches:await page.evaluate(()=>window.__archiveFetches),errors,responses,requestShapes:requests.map(r=>({method:r.method,navigation:r.navigation,urlLength:r.url.length,kind:r.url.includes('prepare-archive')?'prepare':r.url.includes('cancel-archive')?'cancel':'archive'}))};
 fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary));
})().catch(async e=>{console.error(e);if(page){await page.screenshot({path:path.join(evidence,'failure.png'),fullPage:true}).catch(()=>{});const state=await page.evaluate(()=>({status:document.querySelector('#selection-status')?.textContent,selection:document.querySelector('#selection-count')?.textContent,disabled:document.querySelector('#download-selection')?.disabled})).catch(()=>null);fs.writeFileSync(path.join(evidence,'failure.json'),JSON.stringify({state,responses,errors,requests:requests.map(r=>({...r,body:r.body?{ids:JSON.parse(r.body).ids?.length,selection:JSON.parse(r.body).selection}:null}))},null,2));}process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();if(fixture)fixture.kill();fs.rmSync(root,{recursive:true,force:true});});
