// Real raster images, core authorization, pointer input and deterministic cleanup.
const assert = require('node:assert/strict'),
  fs = require('node:fs'),
  os = require('node:os'),
  path = require('node:path'),
  { spawn, spawnSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..'),
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-image-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-image-evidence');
fs.mkdirSync(evidence, { recursive: true });
fs.mkdirSync(root + '/a');
fs.mkdirSync(root + '/b');
const generate = spawnSync(
  process.env.FFMPEG_PATH || 'ffmpeg',
  ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=2400x1600:rate=1', '-frames:v', '1', root + '/demo.png'],
  { encoding: 'utf8', timeout: 30000 }
);
assert.equal(generate.status, 0, generate.stderr);
fs.copyFileSync(root + '/demo.png', root + '/a/large.png');
fs.writeFileSync(root + '/a/broken.png', 'not an image');
fs.writeFileSync(root + '/b/independent.txt', 'independent');
const fixtures = [];
let browser;
const errors = [],
  network = [];
async function until(fn) {
  for (let i = 0; i < 600; i++) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw Error('timeout');
}
async function server(example, env = {}) {
  const process = spawn(path.join(repo, 'target/debug/examples/' + example), [root], { env: { ...global.process.env, ...env } });
  fixtures.push(process);
  let output = '';
  process.stdout.on('data', (d) => (output += d));
  process.stderr.on('data', (d) => global.process.stderr.write(d));
  const url = await until(() => output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  return { url, process };
}
(async () => {
  const directory = await server('directory_workspace_fixture');
  const legacy = await server('web_preview_fixture', { LEGNASEND_FIXTURE_MODE: 'download', LEGNASEND_FIXTURE_COUNT: '0' });
  browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  const context = await browser.newContext({ viewport: { width: 1120, height: 860 }, locale: 'en', hasTouch: true });
  const page = await context.newPage();
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('response', (r) => {
    if (r.url().includes('/content?') || r.url().includes('/download?'))
      network.push({ url: r.url(), status: r.status(), method: r.request().method() });
  });
  await page.goto(directory.url + 'design/');
  await page.locator('.row[title="large.png"] .preview-button').click();
  await page.locator('.image-preview[data-state="ready"]').waitFor();
  const stage = page.locator('.image-stage'),
    img = page.locator('.image-stage img');
  const fitted = Number(await stage.getAttribute('data-scale'));
  assert.ok(fitted < 1 && fitted > 0);
  assert.equal(await img.evaluate((n) => n.naturalWidth), 2400);
  await page.getByRole('button', { name: 'Actual size', exact: true }).click();
  assert.equal(Number(await stage.getAttribute('data-scale')), 1);
  const box = await stage.boundingBox(),
    before = Number(await stage.getAttribute('data-x'));
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 90, box.y + box.height / 2 + 40, { steps: 5 });
  await page.mouse.up();
  assert.ok(Number(await stage.getAttribute('data-x')) > before);
  await stage.focus();
  await page.keyboard.press('ArrowRight');
  await page.keyboard.press('+');
  assert.ok(Number(await stage.getAttribute('data-scale')) > 1);
  await page.keyboard.press('0');
  assert.equal(Number(await stage.getAttribute('data-scale')), fitted);
  await page.getByRole('button', { name: 'Zoom in', exact: true }).click();
  assert.ok(Number(await stage.getAttribute('data-scale')) > fitted);
  await page.getByRole('button', { name: 'Fit', exact: true }).click();
  await stage.dblclick();
  assert.equal(Number(await stage.getAttribute('data-scale')), 1);
  await page.setViewportSize({ width: 650, height: 800 });
  await page.waitForTimeout(100);
  assert.equal(Number(await stage.getAttribute('data-scale')), 1);
  await page.setViewportSize({ width: 1120, height: 860 });
  await stage.focus();
  await page.keyboard.press('0');
  await until(async () => Math.abs(Number(await stage.getAttribute('data-scale')) - fitted) < 0.00001);
  await stage.hover();
  await page.keyboard.down('Control');
  await page.mouse.wheel(0, -80);
  await page.keyboard.up('Control');
  await until(async () => Number(await stage.getAttribute('data-scale')) > fitted);
  await page.keyboard.press('0');
  await page.screenshot({ path: path.join(evidence, 'image-preview-desktop.png') });
  const cdp = await context.newCDPSession(page);
  const center = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  await cdp.send('Input.dispatchTouchEvent', {
    type: 'touchStart',
    touchPoints: [
      { x: center.x - 40, y: center.y, id: 1 },
      { x: center.x + 40, y: center.y, id: 2 }
    ]
  });
  for (let i = 0; i < 5; i++)
    await cdp.send('Input.dispatchTouchEvent', {
      type: 'touchMove',
      touchPoints: [
        { x: center.x - 45 - i * 8, y: center.y, id: 1 },
        { x: center.x + 45 + i * 8, y: center.y, id: 2 }
      ]
    });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  const pinch = Number(await stage.getAttribute('data-scale'));
  assert.ok(pinch > fitted * 1.5);
  const handle = await img.elementHandle();
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('.image-stage').count(), 0);
  assert.equal(await handle.evaluate((n) => n.hasAttribute('src')), false);
  await handle.dispose();
  await page.locator('#language').selectOption('zh-TW');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.locator('.row[title="large.png"] .preview-button').click();
  await page.locator('.image-preview[data-state="ready"]').waitFor();
  assert.equal(await page.getByRole('button', { name: '適應視窗', exact: true }).count(), 1);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  const touchSizes = await page
    .locator('.image-toolbar button')
    .evaluateAll((ns) => ns.map((n) => ({ width: n.getBoundingClientRect().width, height: n.getBoundingClientRect().height })));
  assert.ok(touchSizes.every((n) => n.width >= 44 && n.height >= 44));
  await page.screenshot({ path: path.join(evidence, 'image-preview-mobile-hant.png') });
  await page.locator('#directory-preview-close').click();
  await page.locator('.row[title="broken.png"] .preview-button').click();
  await page.locator('#directory-preview-retry:not([hidden])').waitFor();
  assert.equal(await page.locator('.image-stage').count(), 0);
  fs.copyFileSync(root + '/demo.png', root + '/a/broken.png');
  await page.locator('#directory-preview-retry').click();
  await page.locator('#directory-preview[open]').waitFor({ state: 'hidden' }); // changed size correctly invalidates the stale listing
  await page.locator('#refresh').click();
  await page.locator('.row[title="broken.png"] .preview-button').click();
  await page.locator('.image-preview[data-state="ready"]').waitFor();
  fs.appendFileSync(root + '/a/broken.png', 'changed');
  await page.locator('#directory-preview[open]').waitFor({ state: 'hidden', timeout: 10000 });
  assert.equal(await page.locator('.image-stage').count(), 0);
  await page.goto(legacy.url);
  await page.locator('[data-preview-id="image"]').click();
  await page.locator('.image-preview[data-state="ready"]').waitFor();
  await page.getByRole('button', { name: 'Actual size', exact: true }).click();
  assert.equal(Number(await stage.getAttribute('data-scale')), 1);
  const legacyHandle = await img.elementHandle();
  await page.locator('#preview-close').click();
  assert.equal(await legacyHandle.evaluate((n) => n.hasAttribute('src')), false);
  assert.equal(await page.locator('.image-stage').count(), 0);
  await legacyHandle.dispose();
  assert.deepEqual(errors, []);
  assert.ok(network.some((r) => r.url.includes('version=') && r.method === 'GET' && r.status === 200));
  const result = {
    browser: browser.version(),
    host: global.process.platform,
    width: 2400,
    height: 1600,
    sourceBytes: fs.statSync(root + '/demo.png').size,
    fittedScale: fitted,
    pinchScale: pinch,
    touchSizes,
    legacy: true,
    customResize: true,
    modifiedWheel: true,
    doubleClick: true,
    sourceChangeCleanup: true,
    errors
  };
  fs.writeFileSync(path.join(evidence, 'image-preview-results.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
})()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (browser) await browser.close();
    fixtures.forEach((p) => p.kill());
    fs.rmSync(root, { recursive: true, force: true });
  });
