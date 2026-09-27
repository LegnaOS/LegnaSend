// Real Chromium drag data supplied through CDP, not a file picker or JS-created File.
// The filesystem bytes travel through production upload approval and HTTP routes.
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-directory-drop-'));
const evidence=process.env.EVIDENCE_DIR||path.join(os.tmpdir(),'legnasend-directory-drop-evidence');fs.mkdirSync(evidence,{recursive:true});
for(const name of ['a','b','source'])fs.mkdirSync(path.join(root,name));
const expected=new Map(),sources=[];
for(let i=0;i<64;i++){const name=`拖拽-${String(i).padStart(3,'0')}.txt`,bytes=Buffer.from(`drop bytes ${i} 中文\n`);fs.writeFileSync(path.join(root,'source',name),bytes);sources.push(path.join(root,'source',name));expected.set(name,bytes);}
fs.mkdirSync(path.join(root,'source','nested','child'),{recursive:true});fs.mkdirSync(path.join(root,'source','nested','empty'));
for(const [name,bytes] of [['nested/one.txt',Buffer.from('one\n')],['nested/child/two.bin',Buffer.from([0,1,2,128,255])]]){fs.writeFileSync(path.join(root,'source',name),bytes);expected.set(name,bytes);}
sources.push(path.join(root,'source','nested'));
let browser,fixture,output='',partial='',releaseFirst,held=false;const approvals=[],errors=[],requests=[];
async function until(fn,ms=60000){const end=Date.now()+ms;while(Date.now()<end){const result=await fn();if(result)return result;await new Promise(r=>setTimeout(r,25));}throw Error('Timed out: '+fn.toString());}
(async()=>{
 fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{env:{...process.env,LEGNASEND_FIXTURE_UPLOAD:'1',LEGNASEND_FIXTURE_APPROVAL:'1'}});
 fixture.stdout.on('data',chunk=>{output+=chunk;partial+=chunk;let end;while((end=partial.indexOf('\n'))>=0){const line=partial.slice(0,end);partial=partial.slice(end+1);try{const value=JSON.parse(line);if(value.approval)approvals.push(value);}catch{}}});fixture.stderr.on('data',chunk=>process.stderr.write(chunk));
 const url=await until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
 browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--no-proxy-server']});
 const context=await browser.newContext({viewport:{width:1100,height:900},locale:'en'}),page=await context.newPage();
 page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.url().includes('/upload?'))requests.push(r);});
 const firstGate=new Promise(resolve=>releaseFirst=resolve);
 await page.route('**/upload?**',async route=>{if(!held){held=true;await firstGate;}await route.continue();});
 await page.goto(url+'design/');await page.locator('#workspace-upload:not([hidden])').waitFor();
 await page.evaluate(()=>{window.__dragEvents=[];window.__dragFrames=[];window.__dragSampling=false;const surface=document.querySelector('main'),container=document.querySelector('#workspace-upload');for(const name of ['dragenter','dragover','dragleave','drop'])surface.addEventListener(name,e=>{const value={type:name,trusted:e.isTrusted,files:e.dataTransfer?.files.length,items:e.dataTransfer?.items.length,related:e.relatedTarget?.tagName||null};queueMicrotask(()=>{value.highlight=container.classList.contains('is-dragging');window.__dragEvents.push(value);});});function frame(){if(window.__dragSampling)window.__dragFrames.push(container.classList.contains('is-dragging'));requestAnimationFrame(frame);}requestAnimationFrame(frame);});
 const cdp=await context.newCDPSession(page),data={items:[],files:sources,dragOperationsMask:1};
 async function point(selector){const box=await page.locator(selector).first().boundingBox();assert.ok(box);return{x:box.x+Math.min(box.width/2,80),y:box.y+box.height/2};}
 const first=await point('.workspace-upload-hint');
 await cdp.send('Input.dispatchDragEvent',{type:'dragEnter',...first,data});await cdp.send('Input.dispatchDragEvent',{type:'dragOver',...first,data});
 await page.waitForFunction(()=>document.querySelector('#workspace-upload').classList.contains('is-dragging'));
 await page.evaluate(()=>window.__dragSampling=true);
 for(const selector of ['.workspace-upload-top h2','.workspace-upload-tools button','.workspace-upload-target','.workspace-upload-hint']){await cdp.send('Input.dispatchDragEvent',{type:'dragOver',...await point(selector),data});await page.waitForTimeout(75);assert.equal(await page.locator('#workspace-upload').evaluate(n=>n.classList.contains('is-dragging')),true);}
 await page.evaluate(()=>window.__dragSampling=false);
 const frames=await page.evaluate(()=>window.__dragFrames);assert.ok(frames.length>=8);assert.ok(frames.every(Boolean),'nested child transitions must not remove highlight for a rendered frame');
 await page.screenshot({path:path.join(evidence,'drag-multiple-files.png')});
 await cdp.send('Input.dispatchDragEvent',{type:'drop',...first,data});
 await until(()=>approvals.length===1);assert.equal(approvals[0].count,expected.size+1);assert.equal(requests.length,0);assert.deepEqual(fs.readdirSync(root+'/a'),[]);
 assert.equal(await page.locator('#workspace-upload').evaluate(n=>n.classList.contains('is-dragging')),false);
 assert.ok(await page.locator('.workspace-upload-row').count()<=24);
 fixture.stdin.write('approve '+approvals[0].approval+'\n');
 await until(()=>held);await page.waitForFunction(()=>!!document.querySelector('.workspace-upload-row[data-state="uploading"]'));
 const additional='while-uploading.txt';fs.writeFileSync(path.join(root,'source',additional),'second independent batch\n');expected.set(additional,Buffer.from('second independent batch\n'));
 async function nativeDrop(files){const p=await point('.workspace-upload-hint'),drag={items:[],files:files,dragOperationsMask:1};await cdp.send('Input.dispatchDragEvent',{type:'dragEnter',...p,data:drag});await cdp.send('Input.dispatchDragEvent',{type:'dragOver',...p,data:drag});await cdp.send('Input.dispatchDragEvent',{type:'drop',...p,data:drag});}
 await nativeDrop([path.join(root,'source',additional)]);await until(()=>approvals.length===2);assert.equal(approvals[1].count,1);assert.notEqual(approvals[0].approval,approvals[1].approval);
 assert.equal(fs.existsSync(path.join(root,'a',additional)),false);await page.waitForFunction(()=>document.querySelector('.workspace-upload-counts').textContent.includes('Waiting for host approval'));
 fixture.stdin.write('approve '+approvals[1].approval+'\n');releaseFirst();
 await until(()=>fs.existsSync(path.join(root,'a','nested','empty'))&&[...expected.keys()].every(name=>fs.existsSync(path.join(root,'a',name))));
 await page.waitForFunction(count=>document.querySelector('.workspace-upload-counts').textContent.includes('Complete '+count),expected.size+1);
 for(const [name,bytes] of expected)assert.deepEqual(fs.readFileSync(path.join(root,'a',name)),bytes,name);
 assert.ok(fs.statSync(path.join(root,'a','nested','empty')).isDirectory());assert.equal(requests.length,expected.size+1);
 await page.getByRole('button',{name:'Clear finished',exact:true}).click();
 fs.writeFileSync(sources[0],'replacement must not overwrite');await nativeDrop([sources[0]]);await until(()=>approvals.length===3);fixture.stdin.write('approve '+approvals[2].approval+'\n');
 await page.waitForFunction(()=>document.querySelector('.workspace-upload-row')?.dataset.state==='failed');
 assert.match(await page.locator('.workspace-upload-row').textContent(),/Name exists|workspace changed/);
 assert.equal(await page.getByRole('button',{name:'Retry whole file',exact:true}).isVisible(),true);assert.equal(await page.getByRole('button',{name:'Rename & retry',exact:true}).isVisible(),true);
 assert.deepEqual(fs.readFileSync(path.join(root,'a',path.basename(sources[0]))),expected.get(path.basename(sources[0])));

 const events=await page.evaluate(()=>window.__dragEvents);assert.ok(events.some(e=>e.type==='drop'&&e.trusted&&e.files===sources.length));assert.ok(events.filter(e=>e.type==='dragleave').length>=3);assert.ok(events.filter(e=>e.type==='dragleave').every(e=>e.highlight));assert.deepEqual(errors,[]);
 const result={browser:browser.version(),cdpNativeDragData:true,osDesktopDrag:false,filePickerUsed:false,droppedSources:sources.length,verifiedFiles:expected.size,verifiedEmptyDirectories:1,hostApprovals:3,noWritesBeforeApproval:true,dropDuringUploadVisible:true,secondBatchIndependentApproval:true,duplicateConflictVisible:true,duplicateDoesNotOverwrite:true,uploadRequests:requests.length,nestedHighlightFrames:frames.length,nestedHighlightStable:true,maxQueueRows:24,events,errors};
 fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(releaseFirst)releaseFirst();if(browser)await browser.close();if(fixture)fixture.kill();fs.rmSync(root,{recursive:true,force:true});});
