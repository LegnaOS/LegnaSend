// Run only against the isolated QA browser and generated directory described in
// build/test-results/PERSISTENT_DOWNLOADS_ZH.md; directory authorization is real, not mocked.
for (const name of ['LEGNASEND_QA_CDP', 'LEGNASEND_QA_ROOT', 'LEGNASEND_QA_URL']) {
  if (!process.env[name]) throw new Error('Required fixture setting: ' + name);
}
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright'),
  fs = require('fs'),
  assert = require('assert/strict'),
  { createHash } = require('crypto');
(async () => {
  const b = await chromium.connectOverCDP(process.env.LEGNASEND_QA_CDP),
    p = b.contexts()[0].pages()[0],
    root = require('path').resolve(process.env.LEGNASEND_QA_ROOT);
  const evidence = { errors: [], requests: [], peak: 0 };
  let active = 0;
  const persist = () => fs.writeFileSync(root + '/stage2.json', JSON.stringify(evidence, null, 2));
  p.on('pageerror', (e) => {
    evidence.errors.push(e.message);
    persist();
  });
  p.on('request', (r) => {
    if (new URL(r.url()).pathname === '/api/localsend/v2/download') {
      const range = r.headers().range;
      evidence.requests.push({ method: r.method(), range: range || null });
      if (range) {
        active++;
        evidence.peak = Math.max(evidence.peak, active);
      }
      persist();
    }
  });
  function ended(r) {
    if (r.headers().range) active--;
  }
  p.on('requestfinished', ended);
  p.on('requestfailed', ended);
  await p.goto(process.env.LEGNASEND_QA_URL);
  await p.waitForFunction(() => activeDownloads?.manager && document.querySelector('.managed-download'));
  await p.locator('#web-language').selectOption('zh-CN');
  await p.evaluate(async () => {
    await activeDownloads.manager.ready;
    for (const task of [...activeDownloads.manager.tasks]) {
      if (!['complete', 'blocked', 'cancelled'].includes(task.state)) throw Error('QA requires terminal existing tasks');
      await activeDownloads.manager.remove(task);
    }
  });
  const old = 'demo.txt',
    oldHash = createHash('sha256')
      .update(fs.readFileSync(root + '/Downloads/' + old))
      .digest('hex');
  await p.locator('.file-row').filter({ hasText: 'demo.txt' }).locator('.managed-download').click();
  await p.waitForFunction(
    () => {
      const t = activeDownloads.manager.tasks[0];
      return t && (t.offset + (t.pendingBytes || 0) >= 4 * 1024 * 1024 || ['failed', 'blocked'].includes(t.state));
    },
    null,
    { timeout: 180000 }
  );
  await p.locator('.download-task').first().getByRole('button', { name: '暂停', exact: true }).click();
  await p.waitForFunction(
    () => {
      const t = activeDownloads.manager.tasks[0];
      return t.state === 'paused' && !t.promise;
    },
    null,
    { timeout: 180000 }
  );
  evidence.pause = await p.evaluate(() => {
    const t = activeDownloads.manager.tasks[0];
    return { offset: t.offset, cacheName: t.record.cacheName, id: t.id };
  });
  assert.ok(evidence.pause.offset >= 4 * 1024 * 1024 && evidence.pause.offset < 40 * 1024 * 1024);
  fs.copyFileSync(root + '/Downloads/' + evidence.pause.cacheName, root + '/checkpoint.ls');
  fs.writeFileSync(root + '/checkpoint.json', JSON.stringify(await p.evaluate(() => activeDownloads.manager.tasks[0].record.identity)));
  persist();
  await p.screenshot({ path: root + '/stage2-paused.png' });
  await p.reload();
  await p.waitForFunction(() => activeDownloads?.manager?.tasks.length && document.querySelector('.managed-download'));
  evidence.restored = await p.evaluate(() => {
    const t = activeDownloads.manager.tasks[0];
    return { offset: t.offset, state: t.state, restored: t.restored };
  });
  assert.equal(evidence.restored.offset, evidence.pause.offset);
  assert.equal(evidence.restored.restored, true);
  // A page-local 503 verifies retry with the same approved source, without altering the sender.
  await p.route('**/api/localsend/v2/download?**', async (route) => {
    const r = route.request();
    if (r.headers().range?.startsWith('bytes=' + (evidence.pause.offset + 4 * 1024 * 1024) + '-'))
      await route.fulfill({ status: 503, body: '' });
    else await route.continue();
  });
  let before = evidence.requests.length;
  await p.locator('.download-task').getByRole('button', { name: '继续', exact: true }).click();
  await p.waitForFunction(
    () => {
      const t = activeDownloads.manager.tasks[0];
      return !t.promise && ['failed', 'blocked', 'complete'].includes(t.state);
    },
    null,
    { timeout: 180000 }
  );
  evidence.failure = await p.evaluate(() => {
    const t = activeDownloads.manager.tasks[0];
    return { state: t.state, error: t.error, offset: t.offset };
  });
  assert.equal(evidence.failure.state, 'failed');
  assert.equal(evidence.failure.error, 'network');
  assert.ok(evidence.failure.offset >= evidence.pause.offset + 4 * 1024 * 1024);
  evidence.resumedRequests = evidence.requests.slice(before);
  assert.ok(evidence.resumedRequests.filter((r) => r.range).every((r) => Number(r.range.match(/\d+/)[0]) >= evidence.pause.offset));
  persist();
  await p.unroute('**/api/localsend/v2/download?**');
  before = evidence.requests.length;
  const started = Date.now();
  await p.locator('.download-task').getByRole('button', { name: '重试', exact: true }).click();
  await p.waitForFunction(() => activeDownloads.manager.tasks[0].state !== 'failed');
  await p.waitForFunction(
    () => {
      const t = activeDownloads.manager.tasks[0];
      return !t.promise && ['failed', 'blocked', 'complete'].includes(t.state);
    },
    null,
    { timeout: 180000 }
  );
  evidence.retryMs = Date.now() - started;
  evidence.final = await p.evaluate(() => {
    const t = activeDownloads.manager.tasks[0];
    return { state: t.state, error: t.error, offset: t.offset, receipt: t.record.receipt, outputName: t.record.outputName };
  });
  assert.equal(evidence.final.state, 'complete', evidence.final.error);
  evidence.retryRequests = evidence.requests.slice(before);
  assert.equal(evidence.retryRequests[0].method, 'HEAD');
  assert.ok(evidence.retryRequests.filter((r) => r.range).every((r) => Number(r.range.match(/\d+/)[0]) >= evidence.failure.offset));
  assert.deepEqual(fs.readFileSync(root + '/Downloads/' + evidence.final.outputName), fs.readFileSync(root + '/demo.txt'));
  assert.notEqual(evidence.final.outputName, old);
  assert.equal(
    createHash('sha256')
      .update(fs.readFileSync(root + '/Downloads/' + old))
      .digest('hex'),
    oldHash
  );
  assert.ok(!fs.existsSync(root + '/Downloads/' + evidence.pause.cacheName));
  assert.deepEqual(evidence.errors, []);
  assert.equal(evidence.peak, 4);
  await p.screenshot({ path: root + '/stage2-complete.png' });
  persist();
  console.log('PASS', evidence.final, { peak: evidence.peak, retryMs: evidence.retryMs, root });
  process.exit();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
