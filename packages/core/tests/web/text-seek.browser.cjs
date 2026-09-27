// Real Chromium production text reader; isolated controllable range fixture.
const assert=require('node:assert/strict'),fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const assets=path.resolve(__dirname,'../../assets/web'),evidence=process.env.EVIDENCE_DIR||'/tmp/legnasend-text-seek';
fs.mkdirSync(evidence,{recursive:true});
const text=Buffer.from(Array.from({length:220000},(_,i)=>`ROW_${i+1} 中文🙂 ${'readable '.repeat(5)}\r\n`).join(''));
const wide=Buffer.concat([Buffer.from([255,254]),Buffer.from('长🙂'.repeat(80000)+'\r\nSECOND_LOGICAL_LINE\r\nthird','utf16le')]);
const markdown=Buffer.from('# Heading\n\n'+'line in paragraph\n\n'.repeat(60000));
let delay=0,version='"seek-v1"',browser;
const requests=[],errors=[],external=[];
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://localhost');
  if(url.pathname==='/text'||url.pathname==='/wide'||url.pathname==='/markdown'){
    const bytes=url.pathname==='/wide'?wide:url.pathname==='/markdown'?markdown:text;
    const headers={'Content-Length':bytes.length,'Accept-Ranges':'bytes',ETag:version};
    if(req.method==='HEAD'){res.writeHead(200,headers);res.end();return;}
    const m=/bytes=(\d+)-(\d+)/.exec(req.headers.range||'');if(!m){res.writeHead(400);res.end();return;}
    const start=+m[1],end=+m[2];requests.push({start,end});
    setTimeout(()=>{if(req.headers['if-match']!==version){res.writeHead(412);res.end();return;}
      res.writeHead(206,{...headers,'Content-Length':end-start+1,'Content-Range':`bytes ${start}-${end}/${bytes.length}`});res.end(bytes.subarray(start,end+1));},delay);return;
  }
  if(url.pathname.startsWith('/assets/')){const p=url.pathname.slice(8);if(p.includes('..')||!fs.existsSync(path.join(assets,p))){res.writeHead(404);res.end();return;}
    res.setHeader('Content-Type',p.endsWith('.css')?'text/css':'text/javascript');res.end(fs.readFileSync(path.join(assets,p)));return;}
  const file=['wide','markdown'].includes(url.searchParams.get('file'))?url.searchParams.get('file'):'text';
  const size=file==='wide'?wide.length:file==='markdown'?markdown.length:text.length;
  res.setHeader('Content-Type','text/html;charset=utf-8');res.end(`<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/assets/text-reader.css"><link rel="stylesheet" href="/assets/theme.css"><style>body{margin:10px;font:14px sans-serif}button,select,input{max-width:100%;box-sizing:border-box}#content{width:100%}</style><div id="content"></div><p id="status"></p>${['web-i18n.js','text-search.js','markdown-preview.js','markdown-stream.js','text-preview.js'].map(p=>`<script src="/assets/${p}"></script>`).join('')}<script>const l=LegnaWebLocales[new URL(location).searchParams.get('lang')||'en'];window.instance=LegnaTextPreview.mount({container:document.querySelector('#content'),status:document.querySelector('#status'),url:'/${file}',size:${size},markdown:${file==='markdown'},labels:Object.assign({},l.webUi,l.textPreview)});</script>`);
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const base=`http://127.0.0.1:${server.address().port}`;
 browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844}});page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',r=>{if(!r.request().url().startsWith(base)){external.push(r.request().url());return r.abort();}return r.continue();});
 async function ready(params=''){await page.goto(base+'/'+params);await page.locator('.text-row').first().waitFor();}
 async function go(line){await page.locator('.text-jump-input').fill(String(line));await page.locator('.text-jump-go').click();}
 async function state(value){await page.waitForFunction(value=>document.querySelector('#content').dataset.textSeekState===value,value,{timeout:120000});}
 await ready();const initialRequests=requests.length;assert.ok(initialRequests<=2);
 const started=Date.now();await go(180000);await state('found');
 await page.locator('[data-line-target="180000"]').waitFor();
 assert.ok((await page.locator('[data-line-target="180000"]').textContent()).includes('ROW_180000'));
 assert.ok(await page.locator('.text-row').count()<60);assert.ok(await page.locator('.text-line-target').count()===1);
 const firstSeekMs=Date.now()-started;const firstBytes=await page.locator('#content').getAttribute('data-text-seek-bytes');
 assert.ok(+firstBytes<text.length);assert.ok(+firstBytes>1000000);
 await page.locator('.text-query').fill('ROW_12 ');await page.getByRole('button',{name:'Find',exact:true}).click();
 await page.locator('[data-current-match]').waitFor();assert.equal(await page.locator('[data-current-match]').textContent(),'ROW_12 ');
 // Actual cancellation during delayed I/O does not move or tear down the viewport.
 await ready();delay=35;const before=await page.locator('.text-viewport').evaluate(v=>v.scrollTop);
 await go(210000);await page.waitForFunction(()=>+document.querySelector('#content').dataset.textSeekBytes>180000);
 await page.locator('.text-jump-cancel').click();await state('cancelled');
 const count=requests.length;await page.waitForTimeout(160);assert.ok(requests.length<=count+1);
 assert.equal(await page.locator('.text-viewport').evaluate(v=>v.scrollTop),before);assert.ok((await page.locator('.text-row').first().textContent()).includes('ROW_1'));
 // Version changes midway through an unindexed seek are reported, never mixed.
 await ready();await go(210000);await page.waitForFunction(()=>+document.querySelector('#content').dataset.textSeekBytes>180000);version='"seek-v2"';
 await state('error');assert.match(await page.locator('.text-jump-status').textContent(),/changed/);assert.equal(await page.locator('[data-line-target]').count(),0);delay=0;
 // New source version can be reopened; EOF total is only exposed after scanning.
 await ready();await go(999999);await state('missing');assert.match(await page.locator('.text-jump-status').textContent(),/220,001/);
 // UTF16 giant physical first line is not confused with virtual continuation rows.
 await ready('?file=wide');await go(2);await state('found');await page.locator('[data-line-target="2"]').waitFor();
 assert.ok((await page.locator('[data-line-target="2"]').textContent()).includes('SECOND_LOGICAL_LINE'));
 await ready('?file=markdown');await page.locator('.markdown-viewport:not([hidden])').waitFor();
 await go(90000);await state('found');await page.locator('[data-line-target="90000"]').waitFor();assert.ok(await page.locator('.markdown-viewport').evaluate(n=>n.hidden));
 for(const language of ['en','zh-CN','zh-TW','zh-HK']){
  await page.setViewportSize({width:320,height:844});await ready('?lang='+language);await page.evaluate(()=>document.documentElement.dataset.theme='dark');
  const labels=require('../../assets/web/i18n/'+language+'.json');assert.equal(await page.locator('.text-jump-input').getAttribute('aria-label'),labels.textJumpLine);
  await go(0);assert.equal(await page.locator('.text-jump-status').textContent(),labels.textJumpInvalid);
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 }
 await page.screenshot({path:path.join(evidence,'seek-mobile-dark.png')});
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);assert.ok(requests.every(r=>r.end-r.start+1<=65536));
 const result={sourceBytes:text.length,lateLine:180000,firstSeekMs,firstIndexedBytes:+firstBytes,initialRequests,requests:requests.length,cancelled:true,sourceChanged:true,utf16LongLine:true,markdownSourceJump:true,locales:4,errors,external};
 fs.writeFileSync(path.join(evidence,'results.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();server.close();});
