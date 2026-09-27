'use strict';
// Real Chromium storage/locks and HTTP bodies. OPFS stands in for an already
// authorized directory; this does not claim OS Downloads picker acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../../assets/web');
const scripts = ['sha256.js', 'ls-cache.js', 'download-registry.js', 'persistent-downloads.js', 'batch-downloads.js'];
let status = 503, browser;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://fixture');
  if (scripts.includes(url.pathname.slice(1))) {
    res.setHeader('Content-Type', 'text/javascript');
    return res.end(fs.readFileSync(path.join(assets, url.pathname.slice(1))));
  }
  if (url.pathname.endsWith('/download')) {
    if (url.searchParams.get('fileId') === 'c' && req.method !== 'HEAD') {
      res.writeHead(status); return res.end();
    }
    res.setHeader('ETag', '"v1"'); res.setHeader('Accept-Ranges', 'bytes'); res.setHeader('Content-Length', '8');
    if (req.method === 'HEAD') return res.end();
    res.writeHead(206, { 'Content-Range': 'bytes 0-7/8' }); return res.end('content\n');
  }
  res.setHeader('Content-Type', 'text/html');
  res.end('<!doctype html><title>Batch retention fixture</title>' + scripts.map(s => `<script src="/${s}"></script>`).join(''));
});
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });
  const context = await browser.newContext();
  await context.addInitScript(() => { window.showDirectoryPicker = () => navigator.storage.getDirectory(); });
  const page = await context.newPage(), errors = [];
  page.on('pageerror', e => errors.push(e.message));
  const url = `http://127.0.0.1:${server.address().port}/`;
  async function init() {
    await page.goto(url);
    await page.evaluate(async () => {
      window.files = new LegnaPersistentDownloads.Manager();
      files.attachSession('fixture', {
        a: { fileName: 'folder/a.txt', size: 8 }, b: { fileName: 'b.txt', size: 8 }, c: { fileName: 'folder/c.txt', size: 8 },
      });
      window.batches = new LegnaBatchDownloads.Manager({ manager: files });
      await batches.ready;
    });
  }
  await init();
  const first = await page.evaluate(async () => {
    const b = await batches.create({ kind: 'web', ids: ['a', 'b', 'c'], name: 'Retained' });
    await b.promise;
    if (b.state !== 'failed' || b.record.savedFiles !== 2) throw Error('Expected partial batch');
    const child = await b.record.target.getDirectoryHandle('folder');
    const user = await child.getFileHandle('user.ls', { create: true });
    const writer = await user.createWritable(); await writer.write('user file'); await writer.close();
    const records = await files.registry.all();
    const old = Date.now() - 8 * 86400000;
    for (const record of records) { record.updatedUnixMs = old; await files.registry.put(record); }
    const record = await files.registry.batch(b.id); record.updatedUnixMs = old; await files.registry.putBatch(record);
    await files.registry.retention(7);
    return { id: b.id, saved: b.record.savedFiles };
  });
  // A second tab actively owns the old batch: startup cleanup must retain it.
  const holder = await context.newPage(); await holder.goto(url);
  await holder.evaluate(id => {
    window.lockReady = new Promise(resolve => {
      navigator.locks.request('legnasend-batch:' + id, async () => {
        resolve(); await new Promise(release => { window.release = release; });
      });
    });
    return window.lockReady;
  }, first.id);
  await init();
  assert.equal(await page.evaluate(() => batches.batches.length), 1);
  assert.equal(await page.evaluate(() => files.cleanupReport.retained), 1);
  await holder.evaluate(() => release());
  await holder.close();
  const cleaned = await page.evaluate(async () => {
    await files.cleanupExpired();
    const root = await navigator.storage.getDirectory();
    const out = await root.getDirectoryHandle('Retained'), folder = await out.getDirectoryHandle('folder');
    const names = []; for await (const [name] of folder.entries()) names.push(name);
    return {
      batchCount: (await files.registry.batches()).length,
      childCount: (await files.registry.all()).length,
      report: files.cleanupReport,
      names: names.sort(),
      a: await (await (await folder.getFileHandle('a.txt')).getFile()).text(),
      b: await (await (await out.getFileHandle('b.txt')).getFile()).text(),
      user: await (await (await folder.getFileHandle('user.ls')).getFile()).text(),
    };
  });
  assert.equal(cleaned.batchCount, 0); assert.equal(cleaned.childCount, 0); assert.equal(cleaned.report.removed, 1);
  assert.deepEqual(cleaned.names, ['a.txt', 'user.ls']);
  assert.equal(cleaned.a, 'content\n'); assert.equal(cleaned.b, 'content\n'); assert.equal(cleaned.user, 'user file');
  // A live HTTP authentication failure retains the actual persistent cache.
  await page.evaluate(async () => {
    await files.setRetention(0);
    window.second = await batches.create({ kind: 'web', ids: ['a', 'b', 'c'], name: 'Source ended' });
    await second.promise;
  });
  status = 401;
  await page.evaluate(async () => { await batches.start(second); await second.promise; });
  assert.equal(await page.evaluate(async () => (await files.registry.batches()).length), 1);
  // Explicit source shutdown cleans residual cache, but not two published files.
  status = 410;
  const ended = await page.evaluate(async () => {
    await batches.start(second); await second.promise;
    const out = await (await navigator.storage.getDirectory()).getDirectoryHandle('Source ended');
    const folder = await out.getDirectoryHandle('folder'), names = [];
    for await (const [name] of folder.entries()) names.push(name);
    return { batches: (await files.registry.batches()).length, tasks: (await files.registry.all()).length, names,
      a: await (await (await folder.getFileHandle('a.txt')).getFile()).text() };
  });
  assert.deepEqual(ended, { batches: 0, tasks: 0, names: ['a.txt'], a: 'content\n' });
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ browser: await browser.version(), first, cleaned, ended,
    scenarios: ['refresh retention', 'cross-tab batch lock', 'published and unregistered files preserved', 'HTTP 401 retained', 'HTTP 410 cleaned'],
    boundary: 'Real browser storage and HTTP; OPFS substituted for an authorized directory, not native Downloads permission acceptance' }, null, 2));
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
});
