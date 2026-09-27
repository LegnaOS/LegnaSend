// Real HTTP /share iframe; block document POSTs to reproduce the failure mode.
// Archive bytes are saved by the browser, never accumulated in page JavaScript.
'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-selection-'));
const evidence = process.env.EVIDENCE_DIR || path.join(root, 'evidence');
fs.mkdirSync(evidence, { recursive: true });
let browser, fixture;
const results = [], requests = [], errors = [];
async function until(check) {
  for (let i = 0; i < 400; i++) { const value = await check(); if (value) return value; await new Promise(r => setTimeout(r, 25)); }
  throw Error('condition timed out');
}
(async () => {
  fs.writeFileSync(path.join(root, 'demo.txt'), 'content\n');
  let output = '';
  fixture = spawn(path.join(repo, 'target/debug/examples/web_preview_fixture'), [root], {env: {...process.env, LEGNASEND_FIXTURE_MODE:'duplex', LEGNASEND_FIXTURE_COUNT:'5000'}});
  fixture.stdout.on('data', d => output += d); fixture.stderr.on('data', d => output += d);
  const url = await until(() => output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  const lan = Object.values(os.networkInterfaces()).flat().find(n => n.family === 'IPv4' && !n.internal && n.address.startsWith('192.168.'))?.address;
  assert.ok(lan);
  browser = await chromium.launch({headless:true, executablePath:process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', args:['--no-proxy-server']});
  const context = await browser.newContext({acceptDownloads:true, locale:'en-US'});
  // This is an explicit test fault, not a claim about every browser's policy.
  await context.route('**/api/legnasend/v1/web/archive*', route => {
    const req = route.request();
    requests.push({method:req.method(), navigation:req.isNavigationRequest(), urlLength:req.url().length, prepared:req.url().includes('prepare=1')});
    if (req.method() === 'POST' && req.isNavigationRequest()) return route.abort('blockedbyclient');
    return route.continue();
  });
  const page = await context.newPage(); page.on('pageerror', e => errors.push(e.message));
  await page.goto(url.replace('127.0.0.1',lan) + 'share');
  const frame = await until(() => page.frames().find(f => f.url().includes('/download?')));
  await frame.locator('.file-row').first().waitFor();
  assert.equal(await frame.evaluate(() => isSecureContext), false);
  async function download(label, count, scope) {
    const selected = await frame.evaluate(() => Array.from(document.querySelectorAll('.file-select:checked')).map(n => n.dataset.selectId));
    const [file] = await Promise.all([page.waitForEvent('download', {timeout:60000}), frame.getByRole('button', {name:label, exact:true}).click()]);
    assert.equal(await file.failure(), null); assert.ok(file.url().includes('selection=')); assert.ok(file.url().length < 250);
    const dest = path.join(root, scope + '.zip'); await file.saveAs(dest);
    const result = JSON.parse(execFileSync('python3', ['-c', `import sys,zipfile,json,hashlib
with zipfile.ZipFile(sys.argv[1]) as z:
 assert z.testzip() is None
 assert all(z.read(n)==b'content\\n' for n in z.namelist())
 print(json.dumps({'entries':len(z.infolist()),'sha256':hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()}))`, dest], {encoding:'utf8'}));
    assert.equal(result.entries,count);
    assert.ok(frame.url().includes('/download?')); assert.ok(page.url().endsWith('/share'));
    assert.deepEqual(await frame.evaluate(() => Array.from(document.querySelectorAll('.file-select:checked')).map(n => n.dataset.selectId)),selected);
    results.push({scope,...result,rows:await frame.locator('.file-row').count(),pageRetained:true});
  }
  await frame.locator('.file-select').first().check(); await frame.locator('.file-select').nth(1).check();
  await download('Download selected · ZIP (2)',2,'selected-two');
  await download('Download selected · ZIP (2)',2,'selected-repeat');
  await frame.getByRole('button',{name:'Select filtered files',exact:true}).click();
  await download('Download selected · ZIP (5001)',5001,'selected-5001');
  await page.setViewportSize({width:390,height:844});
  await frame.getByRole('button',{name:'Clear selection',exact:true}).click();
  await download('Download all · ZIP',5001,'all-after-clear');
  await page.getByRole('tab',{name:'Send files',exact:true}).click();
  await page.getByRole('tab',{name:'Get files',exact:true}).click();
  assert.ok(await frame.locator('.file-row').count() <= 19);
  assert.equal(requests.filter(r => r.method==='POST' && r.navigation).length,0);
  assert.equal(requests.filter(r => r.prepared).length,4);
  assert.deepEqual(errors,[]);
  await page.screenshot({path:path.join(evidence,'share-390.png'),fullPage:true});
  fs.writeFileSync(path.join(evidence,'browser.json'), JSON.stringify({results,requests,errors,ordinaryHttp:true,physicalMobile:false},null,2)+'\n');
  console.log(JSON.stringify({results,evidence}));
})().catch(e => {console.error(e); process.exitCode=1;}).finally(async () => {
  if(browser) await browser.close(); if(fixture){fixture.stdin.write('quit\n');fixture.stdin.end(); setTimeout(()=>{if(fixture.exitCode===null)fixture.kill();},1000).unref();}
});
