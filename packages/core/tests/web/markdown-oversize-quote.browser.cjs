// Actual Chromium, production reader + dedicated worker + renderer. No mocked DOM.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../../assets/web');
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-markdown-oversize-quote');
fs.mkdirSync(evidence, { recursive: true });
const sample = 'word 中文🙂 &amp; **inline** <img src="https://example.invalid/trap.png" onerror="window.pwned=1"> <script>window.pwned=1</script> ';
const size = 2 * 1024 * 1024;
const repeated = sample.repeat(Math.ceil(size / Buffer.byteLength(sample)) + 1);
const repeatedLines = ('> ' + sample + '\n').repeat(Math.ceil(size / Buffer.byteLength('> ' + sample + '\n')) + 1);
const files = {
  '/singleline.md': Buffer.from('# Before quote\n\n> ' + repeated + 'FINAL_SINGLELINE_MATCH\n\n# After quote\n'),
  '/multiline.md': Buffer.from('# Before quote\n\n' + repeatedLines + '> FINAL_MULTILINE_MATCH\n\n# After quote\n'),
};
const errors = [], external = [], unexpected = [], ranges = [], workers = new Set(), assetRequests = new Set();
const summary = {
  sourceBytes: Object.fromEntries(Object.entries(files).map(([name, data]) => [name, data.length])),
  sections: {}, replay: {}, sourceTailSearch: {}, locales: [], peakNodes: 0, peakBlocks: 0,
  peakCacheBytes: 0, peakWindowCodeUnits: 0, physicalMobileAcceptance: false,
};
const server = http.createServer((req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const data = files[url.pathname];
    if (data) {
      const headers = { 'Accept-Ranges': 'bytes', ETag: '"quote-v1"', 'Content-Type': 'text/markdown; charset=utf-8' };
      if (req.method === 'HEAD') { res.writeHead(200, { ...headers, 'Content-Length': data.length }); res.end(); return; }
      assert.equal(req.method, 'GET');
      assert.equal(req.headers['if-match'], '"quote-v1"');
      const match = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range || '');
      assert.ok(match, 'Every source GET is bounded, never a whole-file fallback');
      const start = +match[1], end = Math.min(+match[2], data.length - 1);
      assert.ok(start >= 0 && start <= end);
      ranges.push(end - start + 1);
      res.writeHead(206, { ...headers, 'Content-Length': end - start + 1, 'Content-Range': `bytes ${start}-${end}/${data.length}` });
      res.end(data.subarray(start, end + 1)); return;
    }
    if (url.pathname.startsWith('/assets/')) {
      const relative = url.pathname.slice(8), file = path.resolve(assets, relative);
      assert.ok(file.startsWith(assets + path.sep) && fs.statSync(file).isFile());
      assetRequests.add(relative);
      res.setHeader('Content-Type', relative.endsWith('.css') ? 'text/css' : 'text/javascript');
      res.end(fs.readFileSync(file)); return;
    }
    if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
    if (url.pathname !== '/') { unexpected.push(url.pathname); res.writeHead(404); res.end(); return; }
    const selected = files[url.searchParams.get('file')] ? url.searchParams.get('file') : '/singleline.md';
    const language = ['en', 'zh-CN', 'zh-TW', 'zh-HK'].includes(url.searchParams.get('language')) ? url.searchParams.get('language') : 'en';
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>:root{--ink:#17261b;--muted:#4a594f;--line:#cfdbd1;--green:#54b865}body{margin:8px;font:14px sans-serif}button,input,select{max-width:100%;box-sizing:border-box}#preview{width:100%}</style><link rel="stylesheet" href="/assets/text-reader.css"><div id="preview"></div><p id="status"></p>${['web-i18n.js', 'text-preview.js', 'text-search.js', 'markdown-preview.js', 'markdown-stream.js'].map(name => `<script src="/assets/${name}"></script>`).join('')}<script>window.reader=LegnaTextPreview.mount({container:document.querySelector('#preview'),status:document.querySelector('#status'),url:${JSON.stringify(selected)},size:${files[selected].length},markdown:true,labels:Object.assign({},LegnaWebLocales[${JSON.stringify(language)}].webUi,LegnaWebLocales[${JSON.stringify(language)}].textPreview)});</script>`);
  } catch (error) { errors.push('fixture: ' + error.message); res.writeHead(500); res.end(); }
});
let browser, page;
async function bounded(view) {
  assert.equal(await page.locator('.markdown-stream-error').textContent(), '');
  const state = await view.evaluate(view => ({
    nodes: view.querySelectorAll('*').length,
    blocks: view.querySelectorAll('.markdown-virtual-block').length,
    cache: +view.dataset.markdownCacheBytes,
    height: view.scrollHeight,
    sourceLengths: Array.from(view.querySelectorAll('.markdown-source-window > p:not(.markdown-stream-note)')).map(node => node.textContent.length),
    unsafe: view.querySelectorAll('img,script,iframe,object,embed').length,
  }));
  summary.peakNodes = Math.max(summary.peakNodes, state.nodes);
  summary.peakBlocks = Math.max(summary.peakBlocks, state.blocks);
  summary.peakCacheBytes = Math.max(summary.peakCacheBytes, state.cache);
  summary.peakWindowCodeUnits = Math.max(summary.peakWindowCodeUnits, ...state.sourceLengths);
  assert.ok(state.blocks <= 24, JSON.stringify(state));
  assert.ok(state.nodes < 7000, JSON.stringify(state));
  assert.ok(state.cache <= 4 * 1024 * 1024, JSON.stringify(state));
  assert.ok(state.height < 8 * 1024 * 1024, JSON.stringify(state));
  assert.ok(state.sourceLengths.every(length => length <= 16384), JSON.stringify(state));
  assert.equal(state.unsafe, 0);
  assert.equal(await page.evaluate(() => window.pwned), undefined);
}
async function section(view, n, forward) {
  await view.locator('.markdown-navigation button').nth(forward ? 1 : 0).click();
  await page.waitForFunction(n => document.querySelector('.markdown-navigation span').textContent.startsWith('Section ' + n + ' '), n);
  await view.locator('.markdown-virtual-block').first().waitFor();
  await bounded(view);
}
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  const context = await browser.newContext({ viewport: { width: 1080, height: 900 } });
  await context.route('**/*', route => {
    if (!route.request().url().startsWith(base + '/')) { external.push(route.request().url()); return route.abort(); }
    return route.continue();
  });
  page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));
  page.on('worker', worker => workers.add(new URL(worker.url()).pathname));
  for (const file of Object.keys(files)) {
    console.log('Begin ' + file);
    await page.goto(base + '/?file=' + encodeURIComponent(file));
    const view = page.locator('.markdown-viewport');
    await page.waitForFunction(() => document.querySelector('.markdown-source-window') || document.body.textContent.includes(LegnaWebLocales.en.textPreview.markdownFailed), null, { timeout: 120000 });
    assert.equal(await page.locator('.markdown-source-window').count() > 0, true, 'Production Markdown fell back instead of opening quote source windows');
    await view.locator('.markdown-source-window > p:not(.markdown-stream-note)').first().waitFor();
    assert.equal(await page.locator('.markdown-stream-error').textContent(), '');
    const initial = await view.locator('.markdown-source-window > p:not(.markdown-stream-note)').first().textContent();
    assert.ok(initial.includes('&amp;'), 'Source window must retain literal entity spelling');
    assert.ok(initial.includes('<img'), 'Unsafe markup remains inert literal text');
    assert.equal(await view.locator('h1').first().textContent(), 'Before quote');
    for (let i = 0; i < 6; i++) {
      await view.evaluate((view, i) => { view.scrollTop = Math.min(view.scrollHeight - view.clientHeight, i * 1400); }, i);
      await page.waitForTimeout(80); await bounded(view);
    }
    await view.locator('.markdown-scan').click();
    await page.waitForFunction(() => document.querySelector('.markdown-viewport').dataset.markdownDone === 'true', null, { timeout: 120000 });
    const sections = +(await view.getAttribute('data-markdown-sections'));
    summary.sections[file] = sections;
    console.log('Scanned ' + file + ': ' + sections + ' sections');
    assert.ok(sections >= 2, 'Fixture must cross a replay section boundary');
    for (let n = 2; n <= sections; n++) await section(view, n, true);
    for (let n = sections - 1; n >= 1; n--) await section(view, n, false);
    await view.evaluate(view => { view.scrollTop = 0; });
    await view.locator('.markdown-source-window > p:not(.markdown-stream-note)').first().waitFor();
    assert.equal(await view.locator('.markdown-source-window > p:not(.markdown-stream-note)').first().textContent(), initial, 'Replay must preserve the exact source window');
    summary.replay[file] = true;
    await page.setViewportSize({ width: 320, height: 844 });
    await page.waitForTimeout(200); await bounded(view);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.screenshot({ path: path.join(evidence, file.slice(1, -3) + '-320.png') });
    await page.setViewportSize({ width: 1080, height: 900 });
    for (let n = 2; n <= sections; n++) await section(view, n, true);
    for (let i = 0; i < 15; i++) { await view.evaluate(view => { view.scrollTop = view.scrollHeight; }); await page.waitForTimeout(60); }
    await view.locator('h1').filter({ hasText: 'After quote' }).waitFor();
    const marker = file === '/singleline.md' ? 'FINAL_SINGLELINE_MATCH' : 'FINAL_MULTILINE_MATCH';
    await page.getByRole('combobox', { name: 'Search scope', exact: true }).selectOption('full');
    await page.locator('.text-query').fill(marker);
    await page.getByRole('button', { name: 'Find', exact: true }).click();
    await page.locator('mark.text-match-current').waitFor({ timeout: 120000 });
    assert.equal(await page.locator('mark.text-match-current').textContent(), marker);
    await page.waitForFunction(() => {
      const mark = document.querySelector('mark.text-match-current'), view = document.querySelector('.text-viewport');
      if (!mark || !view) return false;
      const hit = mark.getBoundingClientRect(), box = view.getBoundingClientRect();
      return hit.bottom > box.top && hit.top < box.bottom;
    }, null, { timeout: 10000 });
    for (let settled = 0; settled < 5; settled++) {
      await page.waitForTimeout(200);
      assert.ok(await page.evaluate(() => {
        const hit = document.querySelector('mark.text-match-current').getBoundingClientRect();
        const view = document.querySelector('.text-viewport').getBoundingClientRect();
        return hit.bottom > view.top && hit.top < view.bottom;
      }), 'Search hit must remain visible after asynchronous row measurement settles');
    }
    assert.ok(await page.locator('.text-row').count() < 60);
    assert.equal(await page.locator('#preview img,#preview script,#preview iframe').count(), 0);
    summary.sourceTailSearch[file] = true;
    await page.screenshot({ path: path.join(evidence, file.slice(1, -3) + '-tail-search.png') });
    await page.evaluate(() => window.reader.close());
  }
  await page.setViewportSize({ width: 320, height: 844 });
  for (const language of ['en', 'zh-CN', 'zh-TW', 'zh-HK']) {
    for (const file of Object.keys(files)) {
      await page.goto(base + '/?file=' + encodeURIComponent(file) + '&language=' + language);
      const view = page.locator('.markdown-viewport');
      await view.locator('.markdown-source-window .markdown-stream-note').first().waitFor({ timeout: 120000 });
      const expected = await page.evaluate(lang => LegnaWebLocales[lang].textPreview.markdownSourceWindow, language);
      assert.ok(expected);
      assert.equal(await view.locator('.markdown-source-window .markdown-stream-note').first().textContent(), expected);
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      await bounded(view);
      await page.screenshot({ path: path.join(evidence, file.slice(1, -3) + '-' + language + '-320.png') });
      summary.locales.push({ language, file, width: 320 });
      await page.evaluate(() => window.reader.close());
    }
  }
  assert.ok(workers.has('/assets/markdown-stream-worker.js'), 'Production parsing worker must actually run');
  assert.ok(assetRequests.has('markdown-blocks.js') && assetRequests.has('vendor/marked.umd.js'), 'Worker parser assets must load');
  assert.deepEqual(errors, []); assert.deepEqual(external, []); assert.deepEqual(unexpected, []);
  assert.ok(ranges.length && ranges.every(bytes => bytes <= 65536));
  const hashes = {};
  for (const name of Array.from(assetRequests).sort()) hashes['packages/core/assets/web/' + name] = crypto.createHash('sha256').update(fs.readFileSync(path.join(assets, name))).digest('hex');
  hashes['packages/core/tests/web/' + path.basename(__filename)] = crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex');
  Object.assign(summary, { success: true, browserVersion: browser.version(), requests: ranges.length, maxRange: Math.max(...ranges), errors, external, unexpected, workers: Array.from(workers), sourceSha256: hashes });
  fs.writeFileSync(path.join(evidence, 'results.json'), JSON.stringify(summary, null, 2) + '\n');
  console.log(JSON.stringify(summary));
})().catch(async error => {
  console.error(error); process.exitCode = 1;
  if (page) {
    summary.failureView = await page.evaluate(() => {
      const view = document.querySelector('.text-viewport'), mark = document.querySelector('mark.text-match-current');
      const box = node => node && JSON.parse(JSON.stringify(node.getBoundingClientRect()));
      return { scrollTop: view?.scrollTop, scrollHeight: view?.scrollHeight, clientHeight: view?.clientHeight,
        view: box(view), mark: box(mark), row: box(mark?.closest('.text-row')), rows: document.querySelectorAll('.text-row').length };
    }).catch(() => null);
    await page.screenshot({ path: path.join(evidence, 'failure.png') }).catch(() => {});
  }
  fs.writeFileSync(path.join(evidence, 'failure.json'), JSON.stringify({ ...summary, error: String(error), errors, external, unexpected }, null, 2) + '\n');
}).finally(async () => { if (browser) await browser.close(); server.close(); });
