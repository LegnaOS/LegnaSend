'use strict';
// Regression for the temporary sharing reader after extracting shared styles.
const assert=require('node:assert/strict');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-legacy-reader-'));
const evidence=process.env.EVIDENCE_DIR || path.join(os.tmpdir(),'legnasend-legacy-reader-evidence');
fs.mkdirSync(evidence,{recursive:true});
fs.writeFileSync(path.join(root,'demo.md'),'# Legacy sharing\n\n**Original** temporary sharing still works.\n\n- reader\n- search\n' + (process.env.LEGNASEND_QA_LARGE_MARKDOWN ? ('\n## Large section\n\n' + 'Long body '.repeat(20) + '\n').repeat(3000) : ''));
fs.writeFileSync(path.join(root,'demo.txt'),'Original LocalSend-compatible session\n'+'Wrapping text content '.repeat(100)+'\nLEGACY-NEEDLE\n');
const env={...process.env,LEGNASEND_FIXTURE_MODE:'download',LEGNASEND_FIXTURE_COUNT:'0'};delete env.LEGNASEND_FIXTURE_PIN;
const fixture=spawn(path.resolve(__dirname,'../../../../target/debug/examples/web_preview_fixture'),[root],{env,stdio:['ignore','pipe','pipe']});
let output='',browser,errors=[],sharedCss=false;
fixture.stdout.on('data',bytes=>output+=bytes);fixture.stderr.on('data',bytes=>process.stderr.write(bytes));
(async()=>{
  let url;for(let i=0;i<200;i++){url=output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0];if(url)break;await new Promise(r=>setTimeout(r,25));}assert.ok(url);
  browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const page=await browser.newPage({viewport:{width:390,height:844},locale:'en'});page.on('pageerror',e=>errors.push(e.message));
  page.on('response',r=>{if(r.url().endsWith('/assets/text-reader.css')&&r.status()===200)sharedCss=true;});
  await page.goto(url);await page.locator('[data-preview-id="markdown"]').click();await page.locator('.markdown-document h1').waitFor();
  assert.equal(await page.locator('.markdown-document h1').innerText(),'Legacy sharing');
  if(process.env.LEGNASEND_QA_LARGE_MARKDOWN) assert.ok(await page.locator('.markdown-virtual-block').count() <= 24 && await page.locator('.markdown-virtual-block').count() > 0);
  await page.locator('#preview-close').click();await page.locator('[data-preview-id="text"]').click();await page.locator('.text-row').first().waitFor();
  const style=await page.locator('.text-row').first().evaluate(el=>({whiteSpace:getComputedStyle(el).whiteSpace,fontSize:getComputedStyle(el).fontSize}));
  assert.deepEqual(style,{whiteSpace:'pre-wrap',fontSize:'14px'});assert.equal(sharedCss,true);
  await page.keyboard.press('Control+f');assert.equal(await page.locator('.text-query').evaluate(el=>el===document.activeElement),true);
  await page.locator('.text-query').fill('LEGACY-NEEDLE');
  await page.waitForFunction(()=>document.querySelector('[data-current-match]')?.textContent==='LEGACY-NEEDLE');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  await page.screenshot({path:path.join(evidence,'directory-preview-legacy-reader.png')});
  await page.locator('#preview-close').click();assert.equal(await page.locator('#preview-content').innerText(),'');assert.deepEqual(errors,[]);
  const result={browser:browser.version(),host:process.platform,temporarySharing:true,sharedStyles:true,markdown:true,largeMarkdown:!!process.env.LEGNASEND_QA_LARGE_MARKDOWN,textSearch:true,wrap:true,width:390,pageErrors:errors};
  fs.writeFileSync(path.join(evidence,'directory-preview-legacy-results.json'),JSON.stringify(result,null,2)+'\n');console.log(result);
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{
  if(browser)await browser.close();fixture.kill('SIGINT');
  await new Promise(resolve=>{fixture.once('exit',resolve);setTimeout(()=>{fixture.kill('SIGTERM');resolve();},3000).unref();});
  fs.rmSync(root,{recursive:true,force:true});
});
