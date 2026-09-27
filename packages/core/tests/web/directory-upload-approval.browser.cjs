const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn}=require('node:child_process');const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-upload-approval-'));
const COUNT=Number(process.env.APPROVAL_FILE_COUNT||5000);assert.ok(Number.isSafeInteger(COUNT)&&COUNT>0&&COUNT<=5000);
const evidence=process.env.EVIDENCE_DIR||'/tmp/legnasend-upload-approval';fs.mkdirSync(evidence,{recursive:true});
for(const name of ['a','b','batch'])fs.mkdirSync(path.join(root,name));
for(let i=0;i<COUNT;i++)fs.writeFileSync(path.join(root,'batch',`${i}.txt`),`bytes-${i}`);
let browser,fixture,output='',partial='';const approvals=[],aborted=[],requests=[],clientIds=[],errors=[],external=[];
async function until(fn,limit=120000){const end=Date.now()+limit;while(Date.now()<end){if(await fn())return;await new Promise(r=>setTimeout(r,30));}throw Error('timeout '+fn.toString());}
(async()=>{
 fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{env:{...process.env,LEGNASEND_FIXTURE_UPLOAD:'1',LEGNASEND_FIXTURE_APPROVAL:'1'}});
 fixture.stdout.on('data',d=>{output+=d;partial+=d;let line;while((line=partial.indexOf('\n'))>=0){const value=partial.slice(0,line);partial=partial.slice(line+1);try{const json=JSON.parse(value);if(json.approval)approvals.push(json);if(json.aborted)aborted.push(json.aborted);}catch{}}});fixture.stderr.on('data',d=>process.stderr.write(d));
 await until(()=>/http:\/\/127\.0\.0\.1:\d+\//.test(output));const url=output.match(/http:\/\/127\.0\.0\.1:\d+\//)[0];
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});const page=await browser.newPage({viewport:{width:1100,height:850}});
 page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.url().includes('/upload?'))requests.push(r);if(r.url().endsWith('/prepare-upload'))clientIds.push(r.postDataJSON().requestId);});
 await page.route('**/*',route=>{if(!route.request().url().startsWith(url)){external.push(route.request().url());return route.abort();}return route.continue();});
 await page.goto(url+'design/');await page.locator('#workspace-upload:not([hidden])').waitFor();
 // Real directory picker: 5000 small files produce exactly one host approval.
 async function choose(button,files){const event=page.waitForEvent('filechooser');await page.getByRole('button',{name:button,exact:true}).click();await(await event).setFiles(files);}
 await choose('Choose folder',path.join(root,'batch'));
 await until(()=>approvals.length===1);assert.equal(approvals[0].count,COUNT);assert.equal(requests.length,0);assert.deepEqual(fs.readdirSync(root+'/a'),[]);
 await page.waitForFunction(()=>document.querySelector('.workspace-upload-row')?.dataset.state==='approving');assert.ok(await page.locator('.workspace-upload-row').count()<=24);
 fixture.stdin.write('approve '+approvals[0].approval+'\n');
 await until(()=>fs.existsSync(root+'/a/batch')&&fs.readdirSync(root+'/a/batch').length===COUNT,180000);
 await page.waitForFunction(count=>document.querySelector('.workspace-upload-counts').textContent.includes('Complete '+count),COUNT,{timeout:180000});
 assert.equal(approvals.length,1);assert.equal(requests.length,COUNT);
 for(let i=0;i<COUNT;i++)assert.equal(fs.readFileSync(path.join(root,'a','batch',`${i}.txt`),'utf8'),`bytes-${i}`);
 assert.ok(requests.every(r=>/^[a-f0-9]{64}$/.test(r.headers()['x-legnasend-upload-token']||'')));
 assert.ok(requests.every(r=>!r.url().includes(r.headers()['x-legnasend-upload-token'])));
 const tokens=new Set(requests.map(r=>r.headers()['x-legnasend-upload-token']));assert.equal(tokens.size,1);
 await page.getByRole('button',{name:'Clear finished',exact:true}).click();
 // Explicit host rejection leaves writes disabled for this batch, not the workspace.
 const input=page.locator('#workspace-upload input[type=file]:not([webkitdirectory])');
 await choose('Choose files',{name:'rejected.txt',mimeType:'text/plain',buffer:Buffer.from('rejected')});await until(()=>approvals.length===2);
 fixture.stdin.write('reject '+approvals[1].approval+'\n');
 await page.waitForFunction(()=>document.querySelector('.workspace-upload-row')?.dataset.state==='failed');
 assert.equal(fs.existsSync(root+'/a/rejected.txt'),false);assert.equal(requests.length,COUNT);
 assert.equal(await page.getByRole('button',{name:'Choose files',exact:true}).isVisible(),true);
 await page.getByRole('button',{name:'Retry whole file',exact:true}).click();await until(()=>approvals.length===3);
 assert.notEqual(approvals[1].approval,approvals[2].approval);fixture.stdin.write('approve '+approvals[2].approval+'\n');
 await until(()=>fs.existsSync(root+'/a/rejected.txt'));assert.equal(fs.readFileSync(root+'/a/rejected.txt','utf8'),'rejected');
 await page.waitForFunction(()=>document.querySelector('.workspace-upload-row')?.dataset.state==='succeeded');
 await page.getByRole('button',{name:'Clear finished',exact:true}).click();
 // User cancellation removes pending core decision and never writes on a late approve.
 await choose('Choose files',{name:'cancelled.txt',mimeType:'text/plain',buffer:Buffer.from('cancel')});await until(()=>approvals.length===4);
 await page.getByRole('button',{name:'Cancel batch',exact:true}).click();await until(()=>aborted.includes(approvals[3].approval));fixture.stdin.write('approve '+approvals[3].approval+'\n');
 await page.waitForTimeout(200);assert.equal(fs.existsSync(root+'/a/cancelled.txt'),false);assert.equal(requests.length,COUNT+1);
 await page.getByRole('button',{name:'Clear finished',exact:true}).click();
 // HTTP-compatible picker + multilingual pending state at phone width.
 await page.setViewportSize({width:320,height:844});
 for(const language of ['en','zh-CN','zh-TW','zh-HK']){
  await page.locator('#language').selectOption(language);const count=approvals.length;
  const labels=require('../../assets/web/directory-upload.js').messages[language];
  await choose(labels.files,{name:`${language}.txt`,mimeType:'text/plain',buffer:Buffer.from(language)});
  await until(()=>approvals.length>count);
  await page.waitForFunction(()=>document.querySelector('.workspace-upload-row')?.dataset.state==='approving');
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  if(language==='zh-HK')await page.screenshot({path:path.join(evidence,'approval-mobile-hk.png')});
  await page.getByRole('button',{name:labels.cancelAll,exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.workspace-upload-row')?.dataset.state==='cancelled');await page.getByRole('button',{name:labels.clear,exact:true}).click();
 }
 assert.equal(clientIds.length,approvals.length);assert.ok(approvals.every((entry,i)=>entry.approval!==clientIds[i]));
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
 const result={smallFiles:COUNT,batchApprovals:1,uploadRequests:COUNT+1,sourceBytesVerified:true,rejection:true,retryNewApproval:true,cancelNoWrite:true,hostIdentityIsolated:true,locales:4,viewport:320,errors,external};
 fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();if(fixture)fixture.kill();fs.rmSync(root,{recursive:true,force:true});});
