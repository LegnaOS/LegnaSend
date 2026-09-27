// Real core HTTP temporary-share and named-workspace dialogs, isolated Chromium profile.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawn}=require('node:child_process');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'legnasend-preview-support-'));
const repo=path.resolve(__dirname,'../../../..');
const evidence=process.env.EVIDENCE_DIR||path.join(os.tmpdir(),'legnasend-preview-support-evidence');
fs.mkdirSync(evidence,{recursive:true});fs.mkdirSync(root+'/a');fs.mkdirSync(root+'/b');
const broken=Buffer.from('This is deliberately not an MP4 bitstream.');
for(const p of [root,root+'/a']){fs.writeFileSync(p+'/demo.mp4',broken);fs.writeFileSync(p+'/demo.txt','Preview guidance 中文');}
fs.writeFileSync(root+'/a/download-only.pdf','PDF download-only fixture');
const children=[],errors=[],external=[];let browser;
async function fixture(example){
  const child=spawn(path.join(repo,'target/debug/examples/'+example),[root]);children.push(child);let output='';
  child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>process.stderr.write(d));
  for(let i=0;i<600;i++){const match=output.match(/http:\/\/127\.0\.0\.1:\d+\//);if(match)return match[0];await new Promise(r=>setTimeout(r,25));}
  throw Error('fixture startup');
}
(async()=>{
  const urls=[await fixture('web_preview_fixture'),await fixture('directory_workspace_fixture')];
  browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const page=await browser.newPage({acceptDownloads:true,viewport:{width:320,height:844}});
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{if(!urls.some(url=>route.request().url().startsWith(url))){external.push(route.request().url());return route.abort();}return route.continue();});
  let cases=0;
  for(const [i,url] of urls.entries()){
    const directory=i===1,prefix=directory?'directory-preview':'preview';
    await page.goto(url+(directory?'design/':'share'));
    await page.locator(directory?'.preview-button':'[data-preview-id="video"]').first().waitFor();
    for(const language of ['en','zh-CN','zh-TW','zh-HK']) for(const theme of ['light','dark']){
      await page.locator(directory?'#language':'#web-language').selectOption(language);
      await page.evaluate(t=>document.documentElement.dataset.theme=t,theme);
      await page.locator(directory?'.row[title="demo.mp4"] .preview-button':'[data-preview-id="video"]').click();
      const support=page.locator('#'+prefix+'-support');
      await support.locator('summary').waitFor();
      const catalog=require('../../assets/web/i18n/'+language+'.json');
      assert.equal(await support.locator('summary').textContent(),catalog.previewSupportTitle);
      await support.locator('summary').click();
      assert.ok((await support.textContent()).includes(catalog.previewSupportVideo));
      await page.waitForFunction(([id,text])=>document.getElementById(id).textContent===text,
        [prefix+'-status',await page.evaluate(lang=>window.LegnaWebLocales[lang].previewError,language)]);
      assert.equal(await support.locator('details').getAttribute('open'),'');
      assert.ok(await page.locator('#'+prefix+'-download').getAttribute('href'));
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
      const color=await support.evaluate(node=>({color:getComputedStyle(node).color,bg:getComputedStyle(node.closest('dialog')||node.closest('.preview-dialog')).backgroundColor}));
      function lum(value){const rgb=value.match(/[\d.]+/g).slice(0,3).map(Number).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;});return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;}
      const a=lum(color.color),b=lum(color.bg);assert.ok((Math.max(a,b)+.05)/(Math.min(a,b)+.05)>=4.5,JSON.stringify(color));
      if(language==='zh-HK'&&theme==='dark')await page.screenshot({path:path.join(evidence,(directory?'workspace':'share')+'-support-mobile.png')});
      if(language==='en'&&theme==='light'){
        const downloaded=page.waitForEvent('download');
        // Modifier uses the genuine original-file anchor, not a test-only endpoint.
        await page.locator('#'+prefix+'-download').click({modifiers:['Alt']});
        const item=await downloaded;assert.equal(await item.failure(),null);assert.deepEqual(fs.readFileSync(await item.path()),broken);
      }
      await page.locator('#'+prefix+'-close').click();cases++;
    }
    if(directory){assert.equal(await page.locator('.row[title="download-only.pdf"] .preview-button').count(),0);assert.ok(await page.locator('.row[title="download-only.pdf"] .file-link').getAttribute('href'));}
  }
  assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
  const result={cases,viewports:[320],languages:['en','zh-CN','zh-TW','zh-HK'],themes:['light','dark'],decodeFailureDownloads:2,errors,external};
  fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();children.forEach(c=>c.kill());fs.rmSync(root,{recursive:true,force:true});});
