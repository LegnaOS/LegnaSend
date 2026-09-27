'use strict';
const assert = require('node:assert/strict'),
  fs = require('node:fs'),
  os = require('node:os'),
  path = require('node:path');
const { spawn } = require('node:child_process'),
  { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..'),
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-raw-batch-')),
  count = Number(process.env.BATCH_COUNT || 5000),
  directoryCount = Number(process.env.DIRECTORY_BATCH_COUNT || 5000);
const evidence = process.env.EVIDENCE_DIR || path.join(root, 'evidence');
fs.mkdirSync(evidence, { recursive: true });
const fixtures = [],
  errors = [],
  requests = [],
  results = [];
let browser;
async function start(name, env = {}) {
  const child = spawn(path.join(repo, 'target/debug/examples', name), [root], { env: { ...process.env, ...env } });
  fixtures.push(child);
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  child.stderr.on('data', (d) => (out += d));
  for (let i = 0; i < 300; i++) {
    const url = out.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0];
    if (url) return url;
    if (child.exitCode !== null) throw Error(out);
    await new Promise((r) => setTimeout(r, 30));
  }
  throw Error(out);
}
async function waitRegistry(page, predicate, timeout = 60000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const records = await page.evaluate(async () => (window.__qaRegistry || (window.__qaRegistry = new LegnaDownloadRegistry())).batches());
    if (predicate(records)) return records;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw Error('Timed out waiting for durable batch state');
}
(async () => {
  fs.writeFileSync(path.join(root, 'demo.txt'), 'content\n');
  fs.mkdirSync(path.join(root, 'a', 'sub', 'empty'), { recursive: true });
  fs.mkdirSync(path.join(root, 'b'), { recursive: true });
  for (let i = 0; i < directoryCount; i++) {
    const group = path.join(root, 'a', 'sub', 'group-' + i % 20);
    fs.mkdirSync(group, { recursive: true });
    fs.writeFileSync(path.join(group, Math.floor(i / 20) + ' 中文 %.txt'), 'content\n');
  }
  const base = await start('web_preview_fixture', { LEGNASEND_FIXTURE_COUNT: String(count - 1) });
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: ['--no-proxy-server'],
  });
  const context = await browser.newContext({ viewport: { width: 1120, height: 850 }, locale: 'en-US' });
  // Real browser storage and HTTP; replacing the picker with OPFS does not prove
  // a platform Downloads grant. Actual user directory acceptance is separate.
  await context.addInitScript(() => {
    window.showDirectoryPicker = () => navigator.storage.getDirectory();
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('request', (r) => {
    if (r.url().includes('/download?') && r.method() === 'GET') requests.push(r.url());
  });
  await context.route(base + 'migration-setup', (route) =>
    route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>Storage fixture</title>' }),
  );
  await page.goto(base + 'migration-setup');
  await page.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const request = indexedDB.open('legnasend-downloads-v1', 1);
        request.onupgradeneeded = () => {
          request.result.createObjectStore('tasks', { keyPath: 'id' });
          request.result.createObjectStore('settings');
        };
        request.onerror = reject;
        request.onsuccess = () => {
          const db = request.result,
            tx = db.transaction('settings', 'readwrite');
          tx.objectStore('settings').put('preserved', 'migration-fixture');
          tx.oncomplete = () => {
            db.close();
            resolve();
          };
        };
      }),
  );
  await page.goto(base);
  await page.locator('.file-row').first().waitFor();
  await page.evaluate(async () => {
    const db = await new LegnaDownloadRegistry().open();
    window.__dbVersion = db.version;
  });
  assert.equal(await page.evaluate(() => __dbVersion), 2);
  assert.equal(
    await page.evaluate(() => new LegnaDownloadRegistry().run('settings', 'readonly', (s) => s.get('migration-fixture'))),
    'preserved',
  );
  await page.getByRole('button', { name: 'Save location', exact: true }).click();
  await page.getByRole('button', { name: 'Download all · files', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Download all · files', exact: true }).click();
  await page.waitForFunction(() => activeDownloads.batches.batches[0]?.record.savedFiles >= 10, {}, { timeout: 60000 });
  await page.locator('.download-task[data-batch=true]').getByRole('button', { name: 'Pause', exact: true }).click();
  await page.waitForFunction(() => activeDownloads.batches.batches[0]?.state === 'paused' && !activeDownloads.batches.batches[0]?.promise);
  const paused = await page.evaluate(() => {
    const b = activeDownloads.batches.batches[0];
    return { saved: b.record.savedFiles, id: b.id, cursor: b.record.cursor };
  });
  assert.ok(paused.saved >= 10 && paused.saved < count);
  console.log(JSON.stringify({ paused }));
  const completedUrls = new Set(requests);
  requests.length = 0;
  await page.reload();
  await page.locator('.file-row').first().waitFor();
  await page.evaluate(() => {
    window.__batchSpeed = { positiveSamples: 0, fastFileSamples: 0, maxBytesPerSecond: 0 };
    window.__batchSpeedTimer = setInterval(() => {
      const b = activeDownloads.batches.batches[0], speed = b?.speed;
      if (b?.state !== 'downloading' || !(speed > 0)) return;
      __batchSpeed.positiveSamples++;
      if (activeDownloads.manager.tasks.length && activeDownloads.manager.tasks.every((task) => task.speed == null))
        __batchSpeed.fastFileSamples++;
      __batchSpeed.maxBytesPerSecond = Math.max(__batchSpeed.maxBytesPerSecond, speed);
    }, 50);
  });
  await page.locator('.download-task[data-batch=true]').getByRole('button', { name: 'Continue', exact: true }).click();
  await page.waitForFunction(() => activeDownloads.batches.batches[0]?.state === 'complete', {}, { timeout: 600000 });
  const temporary = await page.evaluate(async () => {
    const b = activeDownloads.batches.batches[0],
      target = b.record.target;
    let files = 0,
      cache = 0,
      bad = 0;
    for await (const [name, handle] of target) {
      if (handle.kind !== 'file') continue;
      files++;
      if (name.endsWith('.ls')) cache++;
      if ((await (await handle.getFile()).text()) !== 'content\n') bad++;
    }
    clearInterval(__batchSpeedTimer);
    return {
      speed: __batchSpeed,
      saved: b.record.savedFiles,
      files,
      cache,
      bad,
      activeTasks: activeDownloads.manager.tasks.length,
      rows: document.querySelectorAll('.download-task').length,
    };
  });
  assert.ok(temporary.speed.positiveSamples > 0, JSON.stringify(temporary.speed));
  assert.ok(temporary.speed.fastFileSamples > 0, 'batch speed must survive tiny files without a per-file sample');
  assert.equal(temporary.files, count);
  assert.equal(temporary.cache, 0);
  assert.equal(temporary.bad, 0);
  assert.equal(temporary.activeTasks, 0);
  assert.equal(temporary.rows, 1);
  const repeated = requests.filter((url) => completedUrls.has(url));
  assert.ok(repeated.length <= 2, 'repeated downloads: ' + repeated.length);
  results.push({ scope: 'temporary', ...temporary, paused, repeated: repeated.length });
  console.log(JSON.stringify({ temporary }));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#web-language').selectOption('zh-CN');
  await page.evaluate(() => LegnaTheme.set('dark'));
  await page.evaluate(()=>activeFileList.ready);
  await page.screenshot({ path: path.join(evidence, 'batch-390.png'), fullPage: true });
  await page.locator('.download-panel').screenshot({path:path.join(evidence,'batch-panel-390.png')});
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
  const dir = await start('directory_workspace_fixture');
  await page.goto(dir + 'design/');
  await page.locator('.row').first().waitFor();
  await page.getByRole('button', { name: 'Save location', exact: true }).click();
  const directoryRequests = [];
  let failRanges = false;
  await context.route(dir + '**/content?**', async (route) => {
    if (route.request().method() === 'GET') {
      directoryRequests.push(route.request().url());
      await new Promise((resolve) => setTimeout(resolve, 10));
      if (failRanges) return route.fulfill({ status: 503, body: 'Injected transient transfer failure' });
    }
    return route.continue();
  });
  await page.locator('#download-folder').filter({ hasText: 'Download folder · files' }).click();
  const directoryBatch = page.locator('.download-task[data-batch=true]');
  await waitRegistry(page, (records) => records[0]?.savedFiles >= 10);
  await directoryBatch.getByRole('button', { name: 'Pause', exact: true }).click();
  await waitRegistry(page, (records) => records[0]?.state === 'paused');
  const directoryPaused = await page.evaluate(async () => {
    const record = (await (window.__qaRegistry || (window.__qaRegistry = new LegnaDownloadRegistry())).batches())[0];
    return { saved: record.savedFiles, cursor: record.cursor, id: record.id };
  });
  assert.ok(directoryPaused.saved >= 10 && directoryPaused.saved < directoryCount, JSON.stringify({ directoryPaused, directoryCount }));
  const completedDirectoryUrls = new Set(directoryRequests);
  directoryRequests.length = 0;
  await page.reload();
  await page.locator('.row').first().waitFor();
  failRanges = true;
  await directoryBatch.getByRole('button', { name: 'Continue', exact: true }).click();
  await waitRegistry(page, (records) => records[0]?.state === 'failed');
  const failedDirectory = await page.evaluate(async () => {
    const record = (await (window.__qaRegistry || (window.__qaRegistry = new LegnaDownloadRegistry())).batches())[0];
    return { saved: record.savedFiles, error: record.error };
  });
  assert.ok(failedDirectory.saved >= directoryPaused.saved);
  assert.equal(failedDirectory.error, 'network');
  failRanges = false;
  await directoryBatch.getByRole('button', { name: 'Try again', exact: true }).click();
  await waitRegistry(page, (records) => records[0]?.state !== 'failed');
  for (let attempt = 0; attempt < 12000; attempt++) {
    const records = await page.evaluate(async () => {
      const r = await (window.__qaRegistry || (window.__qaRegistry = new LegnaDownloadRegistry())).batches();
      return r.map((b) => ({ id: b.id, state: b.state, error: b.error, count: b.count, saved: b.savedFiles, target: !!b.target }));
    });
    if (attempt % 500 === 0) console.log(JSON.stringify({ directoryRecords: records, errors }));
    if (records.some((b) => b.state === 'failed')) throw Error(JSON.stringify(records));
    if (records.length && records.every((b) => b.state === 'complete')) break;
    if (attempt === 11999) throw Error('directory timeout');
    await new Promise((r) => setTimeout(r, 50));
  }
  const directory = await page.evaluate(async () => {
    const r = (await (window.__qaRegistry || (window.__qaRegistry = new LegnaDownloadRegistry())).batches())[0];
    if (!r.target) throw Error(JSON.stringify({ keys: Object.keys(r), source: r.source, state: r.state, error: r.error, count: r.count }));
    let files = 0,
      empty = 0,
      bad = 0,
      cache = 0;
    async function walk(dir) {
      let n = 0;
      for await (const [name, h] of dir) {
        n++;
        if (h.kind === 'directory') await walk(h);
        else {
          files++;
          if (name.endsWith('.ls')) cache++;
          if ((await (await h.getFile()).text()) !== 'content\n') bad++;
        }
      }
      if (!n) empty++;
    }
    await walk(r.target);
    return { files, empty, bad, cache, saved: r.savedFiles };
  });
  assert.equal(directory.files, directoryCount);
  assert.equal(directory.empty, 1);
  assert.equal(directory.bad, 0);
  assert.equal(directory.cache, 0);
  const repeatedDirectory = directoryRequests.filter((url) => completedDirectoryUrls.has(url));
  assert.ok(repeatedDirectory.length <= 4, 'repeated committed directory downloads: ' + repeatedDirectory.length);
  results.push({ scope: 'directory', ...directory, paused: directoryPaused, failed: failedDirectory, repeated: repeatedDirectory.length, retryWithLiveSource: true });
  await page.screenshot({ path: path.join(evidence, 'directory-390.png'), fullPage: true });
  assert.deepEqual(errors, []);
  fs.writeFileSync(
    path.join(evidence, 'browser.json'),
    JSON.stringify({ results, errors, count, directoryCount, root, destination: 'OPFS replacing picker only', physicalMobile: false }, null, 2) + '\n',
  );
  console.log(JSON.stringify({ results, evidence }));
})()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (browser) await browser.close();
    for (const child of fixtures) {
      child.stdin.end();
      child.kill();
    }
  });
