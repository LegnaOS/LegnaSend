// Large Markdown through a real core server, with network/DOM evidence.
const assert = require('node:assert/strict'),
  fs = require('node:fs'),
  os = require('node:os'),
  path = require('node:path'),
  { spawn } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..'),
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-markdown-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-markdown-evidence');
fs.mkdirSync(evidence, { recursive: true });
fs.mkdirSync(root + '/a');
fs.mkdirSync(root + '/b');
const diagram = '```mermaid\nflowchart LR\n A[开始] --> B[完成]\n```\n\n';
const unit = (i) =>
  `## Section ${i}\n\n正文 ${i} 中文 **强调** [project][later] ${'流式阅读 '.repeat(45)}\n\n| A | B |\n| --- | --- |\n| ${i} | value |\n\n- first\n  - nested\n- second\n\n`;
const text =
  '# Large document\n\n' +
  diagram +
  Array.from({ length: 6000 }, (_, i) => unit(i)).join('') +
  '\n[later]: https://example.com\n\n# End marker\n';
fs.writeFileSync(root + '/a/large.md', text);
fs.writeFileSync(root + '/b/other.txt', 'other');
let fixture,
  browser,
  output = '';
const errors = [],
  ranges = [],
  external = [];
let peak = 0;
async function until(fn) {
  for (let i = 0; i < 600; i++) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw Error('timeout');
}
(async () => {
  fixture = spawn(path.join(repo, 'target/debug/examples/directory_workspace_fixture'), [root]);
  fixture.stdout.on('data', (d) => (output += d));
  fixture.stderr.on('data', (d) => process.stderr.write(d));
  await until(() => /http:\/\/127\.0\.0\.1:\d+\//.test(output));
  const url = output.match(/http:\/\/127\.0\.0\.1:\d+\//)[0];
  browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  const context = await browser.newContext({ viewport: { width: 1180, height: 880 }, locale: 'en' });
  await context.route('**/*', (route) => {
    if (!route.request().url().startsWith(url)) {
      external.push(route.request().url());
      return route.abort();
    }
    return route.continue();
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('request', (r) => {
    if (r.headers().range) ranges.push(r.headers().range);
  });
  await page.goto(url + 'design/');
  let start = Date.now();
  await page.locator('.preview-button').click();
  await page.locator('.markdown-virtual-block h1').waitFor();
  const firstVisibleMs = Date.now() - start,
    view = page.locator('.markdown-viewport');
  await page.waitForFunction(() => document.querySelector('.diagram-block')?.dataset.state === 'ready');
  let initial = await view.evaluate((v) => ({
    blocks: v.querySelectorAll('.markdown-virtual-block').length,
    nodes: v.querySelectorAll('*').length,
    index: v.querySelector('.markdown-navigation').textContent,
    sections: v.dataset.markdownSections,
    cache: Number(v.dataset.markdownCacheBytes)
  }));
  assert.ok(initial.blocks <= 24);
  assert.ok(initial.nodes < 7000);
  assert.ok(!initial.index.includes('End of file'));
  const firstRanges = ranges.slice();
  await page.screenshot({ path: path.join(evidence, 'markdown-large-desktop.png') });
  for (let i = 0; i < 16; i++) {
    await view.evaluate((v, i) => (v.scrollTop = i * 600), i);
    await page.waitForTimeout(80);
    const n = await view.locator('.markdown-virtual-block').count();
    peak = Math.max(peak, n);
    assert.ok(n <= 24);
  }
  await view.evaluate((v) => (v.scrollTop = 0));
  await page.locator('.markdown-virtual-block h1').waitFor();
  const nav = view.locator('.markdown-navigation');
  for (let i = 0; i < 8; i++) {
    await nav.getByRole('button', { name: 'Next section', exact: true }).click();
    await page.waitForFunction(
      (n) => document.querySelector('.markdown-navigation span').textContent.startsWith('Section ' + n + ' '),
      i + 2
    );
  }
  for (let i = 0; i < 8; i++) {
    await nav.getByRole('button', { name: 'Previous section', exact: true }).click();
    await page.waitForFunction(
      (n) => document.querySelector('.markdown-navigation span').textContent.startsWith('Section ' + n + ' '),
      8 - i
    );
  }
  await page.locator('.markdown-virtual-block h1').waitFor();
  assert.equal(await page.locator('.markdown-virtual-block h1').textContent(), 'Large document');
  await page.locator('.text-query').fill('End marker');
  await page.locator('.text-search select').selectOption('full');
  await page.locator('.text-search').getByRole('button', { name: 'Find', exact: true }).click();
  await page.waitForFunction(
    () =>
      document.querySelector('.text-search-status').textContent.includes('Search complete') &&
      !!document.querySelector('mark.text-match-current')
  );
  assert.equal(await page.locator('.diagram-block iframe').count(), 0);
  assert.ok(await page.locator('mark.text-match-current').textContent());
  await page.locator('.text-view-button').click();
  await page.locator('.markdown-virtual-block h1').waitFor();
  await view.getByRole('button', { name: 'Index references', exact: true }).click();
  await view.getByRole('button', { name: 'Stop indexing', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('.markdown-scan').disabled);
  const stoppedSections = Number(await view.getAttribute('data-markdown-sections'));
  assert.ok(stoppedSections < 240);
  await view.getByRole('button', { name: 'Index references', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('.markdown-viewport').dataset.markdownDone === 'true');
  await view.evaluate((v) => (v.scrollTop = 600));
  await page.locator('.markdown-virtual-block a').first().waitFor();
  assert.equal(await page.locator('.markdown-virtual-block a').first().getAttribute('href'), 'https://example.com/');
  const indexed = await view.evaluate((v) => ({
    sections: Number(v.dataset.markdownSections),
    checkpoints: Number(v.dataset.markdownCheckpoints),
    cache: Number(v.dataset.markdownCacheBytes)
  }));
  assert.ok(indexed.cache <= 4 * 1024 * 1024);
  await view.evaluate((v) => (v.scrollTop = 0));
  await page.locator('#directory-preview-close').click();
  await page.locator('#language').selectOption('zh-TW');
  await page.locator('.preview-button').click();
  await page.locator('.markdown-virtual-block h1').waitFor();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.waitForFunction(() => document.querySelector('.diagram-block')?.dataset.state === 'ready');
  assert.equal(await view.locator('.markdown-scan').textContent(), '索引參照定義');
  assert.equal(await view.locator('.markdown-navigation').evaluate((n) => getComputedStyle(n).backgroundColor), 'rgb(24, 35, 27)');
  await page.waitForTimeout(350);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.screenshot({ path: path.join(evidence, 'markdown-large-mobile.png') });
  await page.locator('#directory-preview-close').click();
  assert.equal(await page.locator('.diagram-block iframe').count(), 0);
  await page.locator('.preview-button').click();
  await page.locator('.markdown-virtual-block h1').waitFor();
  fs.appendFileSync(root + '/a/large.md', '\nchanged source\n');
  await page.waitForFunction(() => document.querySelectorAll('.markdown-virtual-block').length === 0);
  assert.equal(await page.locator('.diagram-block iframe').count(), 0);
  assert.deepEqual(errors, []);
  assert.deepEqual(external, []);
  assert.ok(
    ranges.every((r) => {
      const m = r.match(/bytes=(\d+)-(\d+)/);
      return !m || Number(m[2]) - Number(m[1]) + 1 <= 65536;
    })
  );
  const result = {
    sourceBytes: Buffer.byteLength(text),
    firstVisibleMs,
    stoppedSections,
    indexed,
    initial,
    firstRanges,
    peakBlocks: peak,
    rangeRequests: ranges.length,
    errors,
    external
  };
  fs.writeFileSync(path.join(evidence, 'markdown-stream-results.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
})()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (browser) await browser.close();
    if (fixture) fixture.kill();
    fs.rmSync(root, { recursive: true, force: true });
  });
