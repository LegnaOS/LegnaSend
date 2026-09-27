// Actual Chromium + production worker/reader/render assets; isolated HTTP range fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const os = require('node:os');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../../assets/web');
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-markdown-oversize-child');
fs.mkdirSync(evidence, {recursive:true});
const body = 'word 中文🙂 &amp; **inline** <img src=x onerror=window.pwned=1> '.repeat(160000);
const item = Buffer.from('1. **Before item**\n1. **'+body+'FINAL_ITEM_MATCH**\n1. **After item**\n\n# After document\n');
const cell = Buffer.from('| **Key** | Value |\n|:---|---:|\n| '+body+'FINAL_CELL_MATCH | tail |\n| final | **After row** |\n\n# After document\n');
const multiline = Buffer.from('1. **Before item**\n1. beginning\n'+('   block 中文🙂 &amp;\n\n').repeat(180000)+'   FINAL_MULTILINE_MATCH\n1. **After item**\n\n# After document\n');
const files = {'/item.md':item,'/cell.md':cell,'/multiline.md':multiline};
const requests = [], errors = [], external = [];
const server = http.createServer((req,res)=>{
  const url = new URL(req.url,'http://localhost');
  const data = files[url.pathname];
  if(data) {
    const headers = {'Accept-Ranges':'bytes', ETag:'"large-v1"','Content-Type':'text/markdown; charset=utf-8'};
    if(req.method === 'HEAD') {res.writeHead(200,{...headers,'Content-Length':data.length});res.end();return;}
    assert.equal(req.headers['if-match'],'"large-v1"');
    const match = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range || '');
    if(!match) {res.writeHead(400);res.end();return;}
    const start=+match[1], end=Math.min(+match[2],data.length-1);requests.push(end-start+1);
    res.writeHead(206,{...headers,'Content-Length':end-start+1,'Content-Range':`bytes ${start}-${end}/${data.length}`});res.end(data.subarray(start,end+1));return;
  }
  if(url.pathname.startsWith('/assets/')) {
    const relative = url.pathname.slice(8);
    if(relative.includes('..') || !fs.existsSync(path.join(assets,relative))) {res.writeHead(404);res.end();return;}
    res.setHeader('Content-Type',relative.endsWith('.css')?'text/css':'text/javascript');res.end(fs.readFileSync(path.join(assets,relative)));return;
  }
  const selected = files[url.searchParams.get('file')] ? url.searchParams.get('file') : '/item.md';
  const language = ['en','zh-CN','zh-TW','zh-HK'].includes(url.searchParams.get('language')) ? url.searchParams.get('language') : 'en';
  res.setHeader('Content-Type','text/html; charset=utf-8');
  res.end(`<!doctype html><meta charset="utf-8"><style>:root{--ink:#17261b;--muted:#4a594f;--line:#cfdbd1;--green:#54b865}body{margin:8px;font:14px sans-serif}button,input,select{max-width:100%;box-sizing:border-box}#preview{width:100%}</style><link rel="stylesheet" href="/assets/text-reader.css"><div id="preview"></div><p id="status"></p>${['web-i18n.js','text-preview.js','text-search.js','markdown-preview.js','markdown-stream.js'].map(p=>`<script src="/assets/${p}"></script>`).join('')}<script>window.reader=LegnaTextPreview.mount({container:document.querySelector('#preview'),status:document.querySelector('#status'),url:${JSON.stringify(selected)},size:${files[selected].length},markdown:true,labels:Object.assign({},LegnaWebLocales[${JSON.stringify(language)}].webUi,LegnaWebLocales[${JSON.stringify(language)}].textPreview)});</script>`);
});
let browser;
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const page=await browser.newPage({viewport:{width:1080,height:900}});
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{if(!route.request().url().startsWith(base)){external.push(route.request().url());return route.abort();}return route.continue();});
  const summary={sourceBytes:Object.fromEntries(Object.entries(files).map(([k,v])=>[k,v.length])),sections:{},peakNodes:0,peakBlocks:0,sourceTailSearch:{}};
  for(const file of Object.keys(files)) {
    await page.goto(base+'/?file='+encodeURIComponent(file));
    const view=page.locator('.markdown-viewport');
    await view.locator('.markdown-source-window').first().waitFor({timeout:120000});
    assert.equal(await page.locator('.markdown-stream-error').textContent(),'');
    assert.match(await view.locator('.markdown-source-window').first().textContent(),/complete source in reading windows/);
    if(file==='/cell.md') assert.equal(await view.locator('table th strong').first().textContent(),'Key');
    else assert.equal(await view.locator('ol strong').first().textContent(),'Before item');
    for(let i=0;i<6;i++) {
      await view.evaluate((v,i)=>v.scrollTop=Math.min(v.scrollHeight-v.clientHeight,i*1400),i);
      await page.waitForTimeout(80);
      const state=await view.evaluate(v=>({nodes:v.querySelectorAll('*').length,blocks:v.querySelectorAll('.markdown-virtual-block').length,cache:+v.dataset.markdownCacheBytes,height:v.scrollHeight}));
      summary.peakNodes=Math.max(summary.peakNodes,state.nodes);summary.peakBlocks=Math.max(summary.peakBlocks,state.blocks);
      assert.ok(state.blocks<=24);assert.ok(state.nodes<7000);assert.ok(state.cache<=4*1024*1024);assert.ok(state.height<8*1024*1024);
    }
    await view.locator('.markdown-scan').click();
    await page.waitForFunction(()=>document.querySelector('.markdown-viewport').dataset.markdownDone==='true',null,{timeout:120000});
    const sections=+(await view.getAttribute('data-markdown-sections'));summary.sections[file]=sections;assert.ok(sections>5);
    const next=view.locator('.markdown-navigation button').nth(1),previous=view.locator('.markdown-navigation button').first();
    for(let i=0;i<5;i++){await next.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),i+2);}
    for(let i=0;i<5;i++){await previous.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),5-i);}
    await view.locator('.markdown-source-window').first().waitFor();assert.equal(await page.locator('.markdown-stream-error').textContent(),'');
    await page.setViewportSize({width:320,height:844});await page.waitForTimeout(200);
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    assert.equal(await view.locator('img,script,iframe').count(),0);assert.equal(await page.evaluate(()=>window.pwned),undefined);
    await page.screenshot({path:path.join(evidence,file.slice(1,-3)+'-320.png')});
    await page.setViewportSize({width:1080,height:900});
    for(let n=2;n<=sections;n++){await next.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),n);}
    for(let i=0;i<15;i++){await view.evaluate(v=>v.scrollTop=v.scrollHeight);await page.waitForTimeout(60);}
    await view.locator('h1').filter({hasText:'After document'}).waitFor();
    if(file==='/cell.md'){await view.locator('table td strong').filter({hasText:'After row'}).waitFor();}
    else {const last=view.locator('ol').last();assert.equal(await last.getAttribute('start'),'3');assert.equal(await last.locator('strong').textContent(),'After item');}
    const marker=file==='/cell.md'?'FINAL_CELL_MATCH':file==='/item.md'?'FINAL_ITEM_MATCH':'FINAL_MULTILINE_MATCH';
    await page.getByRole('combobox',{name:'Search scope',exact:true}).selectOption('full');await page.locator('.text-query').fill(marker);await page.getByRole('button',{name:'Find',exact:true}).click();
    await page.locator('mark.text-match-current').waitFor({timeout:120000});assert.equal(await page.locator('mark.text-match-current').textContent(),marker);assert.ok(await page.locator('.text-row').count()<60);summary.sourceTailSearch[file]=true;
    await page.evaluate(()=>window.reader.close());
  }
  summary.locales=[];
  await page.setViewportSize({width:320,height:844});
  for(const language of ['en','zh-CN','zh-TW','zh-HK']) {
    await page.goto(base+'/?file=/cell.md&language='+language);
    await page.locator('.markdown-source-window .markdown-stream-note').first().waitFor({timeout:120000});
    const expected=await page.evaluate(lang=>LegnaWebLocales[lang].textPreview.markdownSourceWindow,language);
    assert.ok(expected);assert.equal(await page.locator('.markdown-source-window .markdown-stream-note').first().textContent(),expected);
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    if(language==='zh-CN') await page.screenshot({path:path.join(evidence,'cell-source-zh-320.png')});
    summary.locales.push(language);await page.evaluate(()=>window.reader.close());
  }
  assert.deepEqual(errors,[]);assert.deepEqual(external,[]);assert.ok(requests.every(n=>n<=65536));
  Object.assign(summary,{requests:requests.length,maxRange:Math.max(...requests),errors,external});
  fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();server.close();});
