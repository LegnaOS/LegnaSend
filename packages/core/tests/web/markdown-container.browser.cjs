// Actual Chromium + production worker/reader/render assets; isolated HTTP range fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const os = require('node:os');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../../assets/web');
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-markdown-containers');
fs.mkdirSync(evidence, {recursive:true});
const paragraph = Buffer.from('**' + 'long 中文🙂 &amp; prose '.repeat(500000) + 'FINAL_PARAGRAPH_MATCH**\n\n# After paragraph\n');
const list = Buffer.from('1. **item** [ref]\n   continuation\n   - nested\n'.repeat(12000) + '\n# After list\n\n[ref]: https://example.com/ref\n');
const quote = Buffer.from('> **paragraph** [ref]\n>\n> ```js\n> code\n> ```\n>\n'.repeat(12000) + '\n# After quote\n\n[ref]: https://example.com/ref\n');
const references = Buffer.from('[last][ref11999] [first][ref0]\n\n' + Array.from({length:12000},(_,i)=>`[ref${i}]: https://example.com/${i} "Title ${i}"\n`).join('') + '\n[ref0]: javascript:bad\n\n' + '# next\n\ntext\n\n'.repeat(400));
const files = {'/paragraph.md':paragraph,'/list.md':list,'/quote.md':quote,'/references.md':references};
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
  const selected = files[url.searchParams.get('file')] ? url.searchParams.get('file') : '/paragraph.md';
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
  const summary={sourceBytes:Object.fromEntries(Object.entries(files).map(([k,v])=>[k,v.length])),sections:{},peakNodes:0,peakBlocks:0,peakReferences:0};
  for(const file of Object.keys(files)) {
    await page.goto(base+'/?file='+encodeURIComponent(file));
    const view=page.locator('.markdown-viewport');
    await view.locator('.markdown-virtual-block').first().waitFor({timeout:120000});
    assert.equal(await page.locator('.markdown-stream-error').textContent(),'');
    if(file==='/list.md') assert.equal(await view.locator('ol strong').first().textContent(),'item');
    if(file==='/quote.md') assert.equal(await view.locator('blockquote strong').first().textContent(),'paragraph');
    if(file==='/references.md') {
      await view.locator('a[href="https://example.com/11999"]').waitFor();
      assert.equal(await view.locator('a[href="https://example.com/0"]').count(),1);
      assert.equal(await view.locator('a[href^="javascript:"]').count(),0);
    }
    if(file==='/paragraph.md') {
      assert.match(await view.locator('.markdown-paragraph-window').first().textContent(),/complete source in reading windows/);
      assert.ok((await view.locator('.markdown-paragraph-window').first().textContent()).includes('&amp;'));
    }
    for(let i=0;i<6;i++) {
      await view.evaluate((v,i)=>v.scrollTop=Math.min(v.scrollHeight-v.clientHeight,i*1400),i);
      await page.waitForTimeout(100);
      const state=await view.evaluate(v=>({nodes:v.querySelectorAll('*').length,blocks:v.querySelectorAll('.markdown-virtual-block').length,cache:+v.dataset.markdownCacheBytes,refs:+v.dataset.markdownReferenceBytes,height:v.scrollHeight}));
      summary.peakNodes=Math.max(summary.peakNodes,state.nodes);summary.peakBlocks=Math.max(summary.peakBlocks,state.blocks);summary.peakReferences=Math.max(summary.peakReferences,state.refs);
      assert.ok(state.blocks<=24);assert.ok(state.nodes<7000);assert.ok(state.cache<=4*1024*1024);assert.ok(state.refs<=1024*1024);assert.ok(state.height<8*1024*1024);
    }
    await view.locator('.markdown-scan').click();
    await page.waitForFunction(()=>document.querySelector('.markdown-viewport').dataset.markdownDone==='true',null,{timeout:120000});
    summary.sections[file]=await view.getAttribute('data-markdown-sections');
    assert.ok(+summary.sections[file]>5);
    const next=view.locator('.markdown-navigation button').nth(1), previous=view.locator('.markdown-navigation button').first();
    for(let i=0;i<5;i++){await next.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),i+2);}
    for(let i=0;i<5;i++){await previous.click();await page.waitForFunction(n=>document.querySelector('.markdown-navigation span').textContent.startsWith('Section '+n+' '),5-i);}
    await view.locator('.markdown-virtual-block').first().waitFor();
    assert.equal(await page.locator('.markdown-stream-error').textContent(),'');
    if(file==='/paragraph.md') {
      await page.setViewportSize({width:320,height:844});await page.waitForTimeout(200);
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
      await page.screenshot({path:path.join(evidence,'large-paragraph-mobile.png')});
      await page.getByRole('combobox',{name:'Search scope',exact:true}).selectOption('full');
      await page.locator('.text-query').fill('FINAL_PARAGRAPH_MATCH');
      await page.getByRole('button',{name:'Find',exact:true}).click();
      await page.locator('mark.text-match-current').waitFor({timeout:120000});
      assert.equal(await page.locator('mark.text-match-current').textContent(),'FINAL_PARAGRAPH_MATCH');
      assert.ok(await page.locator('.text-row').count()<60);
      await page.setViewportSize({width:1080,height:900});
    }
    await page.evaluate(()=>window.reader.close());
  }
  assert.deepEqual(errors,[]);assert.deepEqual(external,[]);assert.ok(requests.every(n=>n<=65536));
  Object.assign(summary,{requests:requests.length,maxRange:Math.max(...requests),errors,external});
  fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();server.close();});
