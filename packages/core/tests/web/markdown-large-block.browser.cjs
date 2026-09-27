// Actual Chromium + production worker/reader/render assets; isolated HTTP range fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const os = require('node:os');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../../assets/web');
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-markdown-large-block');
fs.mkdirSync(evidence, {recursive:true});
const fence = Buffer.from('```html\n' + ('<img src=x onerror=window.pwned=1> 中文🙂 ' + 'wrapped '.repeat(10) + '\n').repeat(90000) + 'FINAL_FENCE_MATCH\n```\n# After fence\n');
const table = Buffer.from('| Key | Value |\n|:---|---:|\n' + Array.from({length:20000}, (_,i)=>`| **${i}** | value ${i} |\n`).join('') + '\n# After table\n');
const empty = Buffer.from('```txt\n' + '\n'.repeat(900000) + 'FINAL_EMPTY_MATCH\n```\n');
const files = {'/fence.md':fence,'/table.md':table,'/empty.md':empty};
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
  const selected = files[url.searchParams.get('file')] ? url.searchParams.get('file') : '/fence.md';
  res.setHeader('Content-Type','text/html; charset=utf-8');
  res.end(`<!doctype html><meta charset="utf-8"><style>:root{--ink:#17261b;--muted:#4a594f;--line:#cfdbd1;--green:#54b865}body{margin:8px;font:14px sans-serif}button,input,select{max-width:100%;box-sizing:border-box}#preview{width:100%}</style><link rel="stylesheet" href="/assets/text-reader.css"><div id="preview"></div><p id="status"></p>${['text-preview.js','text-search.js','markdown-preview.js','markdown-stream.js'].map(p=>`<script src="/assets/${p}"></script>`).join('')}<script>window.reader=LegnaTextPreview.mount({container:document.querySelector('#preview'),status:document.querySelector('#status'),url:${JSON.stringify(selected)},size:${files[selected].length},markdown:true});</script>`);
});
let browser;
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const page=await browser.newPage({viewport:{width:1080,height:900}});
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{if(!route.request().url().startsWith(base)){external.push(route.request().url());return route.abort();}return route.continue();});
  const summary={sourceBytes:{fence:fence.length,table:table.length,empty:empty.length},sections:{},peakNodes:0,peakBlocks:0};
  for(const file of ['/fence.md','/table.md','/empty.md']) {
    await page.goto(base+'/?file='+encodeURIComponent(file));
    const view=page.locator('.markdown-viewport');
    await view.locator('.markdown-virtual-block').first().waitFor();
    assert.equal(await page.locator('.markdown-stream-error').textContent(),'');
    if(file==='/table.md') {
      await view.locator('table strong').first().waitFor();
      assert.equal(await view.locator('table strong').first().textContent(),'0');
    } else assert.ok(await view.locator('pre code').count()>0);
    for(let i=0;i<6;i++) {
      await view.evaluate((v,i)=>v.scrollTop=Math.min(v.scrollHeight-v.clientHeight,i*1400),i);
      await page.waitForTimeout(80);
      const state=await view.evaluate(v=>({nodes:v.querySelectorAll('*').length,blocks:v.querySelectorAll('.markdown-virtual-block').length,cache:+v.dataset.markdownCacheBytes,height:v.scrollHeight}));
      summary.peakNodes=Math.max(summary.peakNodes,state.nodes);summary.peakBlocks=Math.max(summary.peakBlocks,state.blocks);
      assert.ok(state.blocks<=24);assert.ok(state.nodes<7000);assert.ok(state.cache<=4*1024*1024);assert.ok(state.height<8*1024*1024);
    }
    await view.locator('.markdown-scan').click();
    await page.waitForFunction(()=>document.querySelector('.markdown-viewport').dataset.markdownDone==='true',null,{timeout:120000});
    summary.sections[file]=await view.getAttribute('data-markdown-sections');
    assert.ok(+summary.sections[file]>4);
    // Force LRU eviction and replay from inside the same logical block.
    const next=view.locator('.markdown-navigation button').nth(1), previous=view.locator('.markdown-navigation button').first();
    for(let i=0;i<5;i++){await next.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),i+2);}
    for(let i=0;i<5;i++){await previous.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),5-i);}
    await view.locator('.markdown-virtual-block').first().waitFor();
    assert.equal(await page.locator('.markdown-stream-error').textContent(),'');
    if(file==='/empty.md') {
      const count=+summary.sections[file];
      for(let n=2;n<=count;n++) {
        await next.click();
        await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),n);
      }
      for(let n=0;n<8;n++) { await view.evaluate(v=>v.scrollTop=v.scrollHeight); await page.waitForTimeout(60); }
      await page.waitForFunction(()=>document.querySelector('.markdown-block-stage').textContent.includes('FINAL_EMPTY_MATCH'));
      assert.ok(await view.evaluate(v=>v.scrollHeight<8*1024*1024));
    }
    if(file==='/fence.md') {
      await page.setViewportSize({width:320,height:844});
      await page.waitForTimeout(200);
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
      assert.equal(await page.evaluate(()=>window.pwned),undefined);
      assert.equal(await view.locator('img,script,iframe').count(),0);
      await page.screenshot({path:path.join(evidence,'large-fence-mobile.png')});
      await page.getByRole('combobox',{name:'Search scope',exact:true}).selectOption('full');
      await page.locator('.text-query').fill('FINAL_FENCE_MATCH');
      await page.getByRole('button',{name:'Find',exact:true}).click();
      await page.locator('mark.text-match-current').waitFor({timeout:120000});
      assert.equal(await page.locator('mark.text-match-current').textContent(),'FINAL_FENCE_MATCH');
      assert.ok(await page.locator('.text-row').count()<60);
      await page.setViewportSize({width:1080,height:900});
    }
    await page.evaluate(()=>window.reader.close());
  }
  assert.deepEqual(errors,[]);assert.deepEqual(external,[]);assert.ok(requests.every(n=>n<=65536));
  Object.assign(summary,{requests:requests.length,maxRange:Math.max(...requests),errors,external});
  fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();server.close();});
