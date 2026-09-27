// Real Rust workspace HTTP + production Markdown reader/worker/renderer, not a mocked Index.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-list-children-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-list-children-evidence');
fs.mkdirSync(evidence, {recursive:true});
fs.mkdirSync(path.join(root,'a'));fs.mkdirSync(path.join(root,'b'));
const marker = 'FINAL_LIST_CHILD_SEARCH_16000';
const paragraphs = Array.from({length:16000}, (_,i)=>`   paragraph ${i} **bold 中文🙂** [reference][late]${i===15999?' '+marker:''}\n\n`).join('');
const item = '3. **First logical item**\n\n'+paragraphs;
const source = item+'4. **Following logical item**\n\n# After list\n\n[late]: https://example.invalid/reference "Reference title"\n';
assert.ok(item.length>256*1024);
fs.writeFileSync(path.join(root,'a','large.md'),source);
fs.writeFileSync(path.join(root,'b','other.txt'),'other');
let fixture,browser,output='';
const errors=[],external=[],ranges=[];
const summary={sourceUnits:source.length,sourceBytes:Buffer.byteLength(source),peakBlocks:0,peakNodes:0,peakCache:0,viewports:[],assetMode:'Rust embedded assets'};
async function until(fn){for(let i=0;i<600;i++){if(await fn())return;await new Promise(r=>setTimeout(r,25));}throw Error('fixture startup timeout: '+output);}
(async()=>{
 fixture=spawn(process.env.DIRECTORY_FIXTURE || path.join(repo,'target/debug/examples/directory_workspace_fixture'),[root]);
 fixture.stdout.on('data',d=>output+=d);fixture.stderr.on('data',d=>process.stderr.write(d));
 await until(()=>/http:\/\/127\.0\.0\.1:\d+\//.test(output));
 const base=output.match(/http:\/\/127\.0\.0\.1:\d+\//)[0];
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const page=await browser.newPage({viewport:{width:1080,height:900},locale:'en'});
 page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(r.headers().range)ranges.push({range:r.headers().range,match:r.headers()['if-match']||null});});
 await page.route('**/*',route=>{if(!route.request().url().startsWith(base)){external.push(route.request().url());return route.abort();}return route.continue();});
 await page.goto(base+'design/');
 await page.locator('#language').selectOption('en');
 await page.locator('.preview-button').click();
 const view=page.locator('.markdown-viewport');
 await view.locator('ol strong').filter({hasText:'First logical item'}).waitFor();
 assert.equal(await view.locator('ol').first().getAttribute('start'),'3');
 assert.equal(await view.locator('.markdown-source-window').count(),0);
 await view.locator('.markdown-scan').click();
 await page.waitForFunction(()=>document.querySelector('.markdown-viewport').dataset.markdownDone==='true',null,{timeout:120000});
 summary.sections=+(await view.getAttribute('data-markdown-sections'));assert.ok(summary.sections>5);
 async function budget(){
  const state=await view.evaluate(v=>({blocks:v.querySelectorAll('.markdown-virtual-block').length,nodes:v.querySelectorAll('*').length,cache:+v.dataset.markdownCacheBytes,height:v.scrollHeight,error:v.querySelector('.markdown-stream-error')?.textContent||''}));
  summary.peakBlocks=Math.max(summary.peakBlocks,state.blocks);summary.peakNodes=Math.max(summary.peakNodes,state.nodes);summary.peakCache=Math.max(summary.peakCache,state.cache);
  assert.ok(state.blocks<=24,JSON.stringify(state));assert.ok(state.nodes<7000,JSON.stringify(state));assert.ok(state.cache<=4*1024*1024);assert.ok(state.height<8*1024*1024);assert.equal(state.error,'');
  assert.equal(await view.locator('.markdown-source-window').count(),0);
  assert.ok(!(await view.textContent()).includes('LegnaContinuation'));
 }
 for(const width of[1080,320]){
  await page.setViewportSize({width,height:900});
  for(let i=0;i<8;i++){await view.evaluate((v,i)=>v.scrollTop=i*700,i);await page.waitForTimeout(90);await budget();}
  await view.locator('li.markdown-list-continuation').first().waitFor();
  const continuing=await view.locator('li.markdown-list-continuation').first().evaluate(li=>({marker:getComputedStyle(li).listStyleType,start:li.parentElement.start,strong:!!li.querySelector('p strong'),href:li.querySelector('p a')?.href}));
  assert.equal(continuing.marker,'none');assert.equal(continuing.start,3);assert.ok(continuing.strong);assert.equal(continuing.href,'https://example.invalid/reference');
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  summary.viewports.push({width,...continuing});await page.screenshot({path:path.join(evidence,'semantic-list-'+width+'.png')});
 }
 await page.setViewportSize({width:1080,height:900});
 const next=view.locator('.markdown-navigation button').nth(1),previous=view.locator('.markdown-navigation button').first();
 async function section(n,button){await button.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),n);await budget();}
 for(let n=2;n<=7;n++)await section(n,next);
 for(let n=6;n>=1;n--)await section(n,previous);
 await view.evaluate(v=>v.scrollTop=0);
 await view.locator('strong').filter({hasText:'First logical item'}).waitFor();
 assert.equal(await view.locator('ol').first().getAttribute('start'),'3');summary.evictedRevisit=true;
 for(let n=2;n<=summary.sections;n++)await section(n,next);
 for(let i=0;i<18;i++){await view.evaluate(v=>v.scrollTop=v.scrollHeight);await page.waitForTimeout(60);await budget();}
 await view.locator('h1').filter({hasText:'After list'}).waitFor();
 const following=view.locator('ol').filter({has:page.locator('strong',{hasText:'Following logical item'})});
 assert.equal(await following.getAttribute('start'),'4');
 assert.equal(await following.locator('li').evaluate(li=>getComputedStyle(li).listStyleType),'decimal');
 await page.locator('.text-search select').selectOption('full');await page.locator('.text-query').fill(marker);
 await page.locator('.text-search').getByRole('button',{name:'Find',exact:true}).click();
 await page.locator('mark.text-match-current').waitFor({timeout:120000});
 assert.equal(await page.locator('mark.text-match-current').textContent(),marker);
 assert.ok((await page.locator('.text-row').count())<60);
 summary.search={marker,sourceOffset:source.indexOf(marker),visibleRows:await page.locator('.text-row').count()};
 await page.screenshot({path:path.join(evidence,'semantic-list-search.png')});
 await page.locator('.text-view-button').click();await view.locator('.markdown-virtual-block').first().waitFor();await budget();
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);assert.ok(ranges.length>1);
 assert.ok(ranges.every(r=>{const m=/^bytes=(\d+)-(\d+)$/.exec(r.range);return m&&+m[2]-+m[1]+1<=65536&&r.match;}));
 summary.rangeRequests=ranges.length;summary.errors=errors;summary.external=external;
 fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();if(fixture)fixture.kill();fs.rmSync(root,{recursive:true,force:true});});
