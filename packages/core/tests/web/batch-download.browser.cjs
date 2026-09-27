'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn,execFileSync}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const repo=path.resolve(__dirname,'../../../..'),root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-batch-browser-'));
const evidence=process.env.EVIDENCE_DIR||path.join(root,'evidence');fs.mkdirSync(evidence,{recursive:true});
let browser;const fixtures=[],errors=[],results=[],contrast=[];
async function start(example,env={}){
 const proc=spawn(path.join(repo,'target/debug/examples',example),[root],{env:{...process.env,...env},stdio:['pipe','pipe','pipe']});fixtures.push(proc);
 let out='',err='';proc.stdout.on('data',x=>out+=x);proc.stderr.on('data',x=>err+=x);
 for(let n=0;n<200;n++){const url=out.match(/http:\/\/127\.0\.0\.1:\d+\//);if(url)return url[0];if(proc.exitCode!==null)throw Error(err);await new Promise(r=>setTimeout(r,50));}throw Error('fixture timeout '+err);
}
function checkZip(file,expected){const result=JSON.parse(execFileSync('python3',['-c',`import zipfile,json,hashlib,sys
with zipfile.ZipFile(sys.argv[1]) as z:
 assert z.testzip() is None
 print(json.dumps({'entries':len(z.infolist()),'names':z.namelist()[:6],'sha256':hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest(),'allDataValid':all(z.read(i)==b'content\\n' for i in z.infolist() if not i.is_dir())}))`,file],{encoding:'utf8'}));assert.equal(result.entries,expected);assert.equal(result.allDataValid,true);return result;}
async function checkContrast(page,scope,selector){
 for(const theme of ['light','dark']){
  await page.evaluate(theme=>window.LegnaTheme.set(theme),theme);
  const pairs=await page.locator(selector).evaluateAll(nodes=>nodes.filter(n=>n.getClientRects().length).map(n=>{
   const style=getComputedStyle(n),rgb=s=>s.match(/[\d.]+/g).slice(0,3).map(Number),luma=c=>c.map(x=>{x/=255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4;}).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
   const a=luma(rgb(style.color)),b=luma(rgb(style.backgroundColor));return {text:n.textContent,foreground:style.color,background:style.backgroundColor,ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)};
  }));assert.ok(pairs.length);pairs.forEach(pair=>assert.ok(pair.ratio>=4.5,JSON.stringify(pair)));contrast.push({scope,theme,pairs});
 }
}
async function saveDownload(page,click,file){const [download]=await Promise.all([page.waitForEvent('download',{timeout:60000}),click()]);assert.equal(await download.failure(),null);await download.saveAs(file);return download.suggestedFilename();}
(async()=>{
 fs.writeFileSync(path.join(root,'demo.txt'),'content\n');fs.mkdirSync(path.join(root,'a','folder','empty'),{recursive:true});fs.mkdirSync(path.join(root,'b'),{recursive:true});
 for(let i=0;i<5000;i++){const dir=path.join(root,'a','folder',String(i%20));fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,`${Math.floor(i / 20)} 中文 %.txt`),'content\n');}
 const web=await start('web_preview_fixture',{LEGNASEND_FIXTURE_COUNT:'5000'}),directory=await start('directory_workspace_fixture');
 const lan=Object.values(os.networkInterfaces()).flat().find(n=>n.family==='IPv4'&&!n.internal&&n.address.startsWith('192.168.'))?.address;
 assert.ok(lan,'a current LAN interface is required for insecure-context HTTP acceptance');
 browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--no-proxy-server']});
 const context=await browser.newContext({acceptDownloads:true,locale:'en-US',viewport:{width:1120,height:850}}),page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(web.replace('127.0.0.1',lan));await page.locator('.file-row').first().waitFor();
 await checkContrast(page,'temporary','.batch-toolbar button:not(:disabled)');assert.equal(await page.evaluate(()=>isSecureContext),false);assert.equal(await page.locator('.managed-download').count(),0);
 await page.getByRole('button',{name:'Save location',exact:true}).click();await page.getByText(/ordinary LAN HTTP keeps browser-managed saving/).first().waitFor();
 const allFile=path.join(root,'all.zip');await saveDownload(page,()=>page.getByRole('button',{name:'Download all · ZIP',exact:true}).click(),allFile);
 results.push({scope:'insecure LAN HTTP all',...checkZip(allFile,5001),rowCount:await page.locator('.file-row').count()});assert.ok(results.at(-1).rowCount<=19);
 await page.locator('.file-select').first().check();await page.locator('.file-select').nth(1).check();
 await page.locator('#web-language').selectOption('zh-CN');await page.waitForFunction(()=>document.querySelectorAll('.file-select:checked').length===2);assert.equal(await page.locator('.file-select:checked').count(),2);
 const selected=path.join(root,'selected.zip');await saveDownload(page,()=>page.getByRole('button',{name:'下载选中项 · ZIP (2)',exact:true}).click(),selected);results.push({scope:'selected',...checkZip(selected,2)});
 await page.setViewportSize({width:390,height:844});await page.evaluate(()=>window.LegnaTheme?.set?.('dark'));
 await page.screenshot({path:path.join(evidence,'temporary-390.png'),fullPage:true});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
 const single=path.join(root,'single.txt');await saveDownload(page,()=>page.locator('.file-row .file-main').first().click(),single);assert.equal(fs.readFileSync(single,'utf8'),'content\n');
 await page.goto(directory.replace('127.0.0.1',lan)+'design/');await page.locator('.row').first().waitFor();await page.locator('#language').selectOption('zh-CN');
 const folder=path.join(root,'folder.zip');await saveDownload(page,()=>page.locator('.row .folder-download').click(),folder);results.push({scope:'HTTP recursive folder',...checkZip(folder,5022)});
 await checkContrast(page,'directory','.folder-download');await page.screenshot({path:path.join(evidence,'folder-390.png'),fullPage:true});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
 await page.setViewportSize({width:1120,height:850});await page.evaluate(()=>window.LegnaTheme.set('light'));await page.screenshot({path:path.join(evidence,'folder-1120.png'),fullPage:true});
 const current=path.join(root,'current.zip');await saveDownload(page,()=>page.locator('#download-folder').click(),current);results.push({scope:'HTTP entire workspace',...checkZip(current,5023)});
 assert.deepEqual(errors,[]);fs.writeFileSync(path.join(evidence,'browser.json'),JSON.stringify({results,contrast,errors,root,ordinaryHttp:true,physicalMobile:false},null,2)+'\n');console.log(JSON.stringify({results,evidence,root}));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();for(const proc of fixtures){proc.stdin.write('quit\n');proc.stdin.end();}setTimeout(()=>{for(const proc of fixtures)if(proc.exitCode===null)proc.kill();},1000).unref();});
