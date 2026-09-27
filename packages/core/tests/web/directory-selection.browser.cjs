'use strict';
// Actual Rust filesystem workspace + browser-native ZIP saves; no page byte cache.
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn,execFileSync}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-directory-selection-'));
const evidence=process.env.EVIDENCE_DIR||path.join(root,'evidence');fs.mkdirSync(evidence,{recursive:true});
let browser,fixture,output='',errors=[],results=[];
async function until(fn){for(let i=0;i<400;i++){const result=await fn();if(result)return result;await new Promise(r=>setTimeout(r,25));}throw Error('condition timed out');}
(async()=>{
  fs.mkdirSync(path.join(root,'a','文件夹','空目录'),{recursive:true});fs.mkdirSync(path.join(root,'b'));
  fs.writeFileSync(path.join(root,'a','中文 % # &.txt'),'选择单文件\n');
  fs.writeFileSync(path.join(root,'a','unselected.txt'),'not selected');
  fs.writeFileSync(path.join(root,'a','文件夹','nested.txt'),'nested bytes');
  fixture=spawn(path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root],{stdio:['pipe','pipe','pipe']});
  fixture.stdout.on('data',d=>output+=d);fixture.stderr.on('data',d=>process.stderr.write(d));
  const url=await until(()=>output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const context=await browser.newContext({acceptDownloads:true,viewport:{width:1100,height:800},locale:'zh-CN'});
  const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
  await page.goto(url+'design/');await page.locator('#select-loaded:enabled').waitFor();
  await page.locator('.row[title="中文 % # &.txt"] .directory-select').check();
  await page.locator('.row[title="文件夹"] .directory-select').check();
  assert.match(await page.locator('#selection-count').innerText(),/^2 /);
  async function download(name,trigger){
    const [file]=await Promise.all([page.waitForEvent('download'),trigger()]);assert.equal(await file.failure(),null);
    const dest=path.join(root,name+'.zip');await file.saveAs(dest);
    const parsed=JSON.parse(execFileSync('python3',['-c',`import json,zipfile,sys
with zipfile.ZipFile(sys.argv[1]) as z:
 assert z.testzip() is None
 print(json.dumps({i.filename:None if i.is_dir() else z.read(i).decode('utf-8') for i in z.infolist()},ensure_ascii=False))`,dest],{encoding:'utf8'}));
    results.push({name,entries:parsed});return parsed;
  }
  const selected=await download('selected',()=>page.locator('#download-selection').click());
  assert.equal(Object.keys(selected).filter(k=>k.endsWith('中文 % # &.txt')).length,1);
  assert.equal(Object.keys(selected).some(k=>k.endsWith('unselected.txt')),false);
  assert.equal(Object.keys(selected).some(k=>k.endsWith('文件夹/空目录/')),true);
  assert.equal(Object.entries(selected).find(([k])=>k.endsWith('/nested.txt'))[1],'nested bytes');
  assert.equal(await page.locator('.directory-select:checked').count(),2);
  await page.screenshot({path:path.join(evidence,'selection-desktop-light.png')});
  await page.setViewportSize({width:390,height:844});
  await page.evaluate(()=>document.documentElement.dataset.theme='dark');
  await page.locator('#language').selectOption('zh-TW');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  const colors=await page.locator('.directory-selection').evaluate(el=>({background:getComputedStyle(el).backgroundColor,color:getComputedStyle(el).color}));
  assert.notEqual(colors.background,'rgb(237, 244, 238)');
  await page.screenshot({path:path.join(evidence,'selection-mobile-dark-hant.png')});
  await page.locator('#clear-selection').click();assert.equal(await page.locator('#download-selection').isDisabled(),true);
  await page.locator('#select-loaded').click();assert.equal(await page.locator('.directory-select:checked').count(),3);
  await page.locator('#refresh').click();await page.locator('#select-loaded:enabled').waitFor();
  assert.equal(await page.locator('.directory-select:checked').count(),0);
  await page.locator('.row[title="文件夹"] .file-link').click();await page.locator('.row[title="nested.txt"]').waitFor();
  const folder=await download('folder',()=>page.locator('#download-folder').click());
  assert.equal(Object.entries(folder).find(([k])=>k.endsWith('nested.txt'))[1],'nested bytes');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(evidence,'result.json'),JSON.stringify({results,colors,errors},null,2));
  console.log(JSON.stringify({passed:true,results,colors}));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();if(fixture)fixture.stdin.end();});
