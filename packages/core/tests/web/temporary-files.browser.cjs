// Real loopback HTTP + browser DOM/OPFS. OPFS replaces only the directory picker;
// it does not prove a platform Downloads grant or mock any server/file response.
'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..');
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-temporary-files-evidence');
fs.mkdirSync(evidence, { recursive: true });
let browser, fixture;
const errors = [], results = [];
async function until(check) {
  for (let i = 0; i < 1000; i++) { const value = await check(); if (value) return value; await new Promise(r => setTimeout(r, 25)); }
  throw Error('condition timed out');
}
(async () => {
  browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });
  for (const width of [1120, 390]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-temporary-files-'));
    const original = 'Old source bytes.\n'.repeat(600000), replacement = 'New independent source bytes.\n'.repeat(22000), kept = '# Keep this file\n\n'.repeat(22000);
    fs.writeFileSync(path.join(root, 'demo.txt'), original);
    fs.writeFileSync(path.join(root, 'demo-next.txt'), replacement);
    fs.writeFileSync(path.join(root, 'demo.md'), kept);
    let output = '';
    fixture = spawn(path.join(repo, 'target/debug/examples/web_preview_fixture'), [root], { env: {
      ...process.env, LEGNASEND_FIXTURE_MODE: 'duplex', LEGNASEND_FIXTURE_CONTROL: '1', LEGNASEND_FIXTURE_DOWNLOAD_DELAY_MS: '100',
      ...(width === 390 ? { LEGNASEND_FIXTURE_PIN: '1234' } : {})
    }});
    fixture.stdout.on('data', d => output += d); fixture.stderr.on('data', d => output += d);
    const base = await until(() => output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
    const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme: width === 390 ? 'dark' : 'light', locale: 'en-US' });
    await context.addInitScript(() => { window.showDirectoryPicker = () => navigator.storage.getDirectory(); });
    const page = await context.newPage(); page.on('pageerror', e => errors.push(e.message));
    await page.goto(base + 'share');
    await page.locator('#pane-download iframe').waitFor();
    const frame = await until(() => page.frames().find(f => new URL(f.url()).pathname === '/download'));
    if (width === 390) { await frame.locator('#sharing-pin').fill('1234'); await frame.locator('.pin-card button[type=submit]').click(); }
    await frame.locator('.file-row').first().waitFor();
    const identity = await frame.evaluate(() => ({ session: sessionId, version: activeFileVersion }));
    assert.ok(identity.version);
    // Keep real managed tasks paused before the selected source is replaced.
    await frame.locator('[data-managed-id=text]').click();
    await frame.waitForFunction(() => activeDownloads.manager.tasks[0]?.pendingBytes >= 4 * 1048576);
    await frame.evaluate(() => activeDownloads.manager.pause(activeDownloads.manager.tasks[0]));
    const partial = await frame.evaluate(async () => {
      const t = activeDownloads.manager.tasks[0];
      return { state: t.state, committed: t.offset, total: t.size, cacheBytes: (await t.record.handle.getFile()).size };
    });
    assert.equal(partial.state, 'paused'); assert.ok(partial.committed > 0 && partial.committed < partial.total);
    assert.ok(partial.cacheBytes > partial.committed);
    // Use the actual public UI addition path for the independent file as well.
    await frame.locator('[data-managed-id=markdown]').click();
    await frame.waitForFunction(() => activeDownloads.manager.tasks.length === 2);
    await frame.evaluate(async () => {
      const m = activeDownloads.manager;
      await Promise.all(m.tasks.map(t => m.pause(t)));
      window.qaManager = m;
      window.qaTaskIds = m.tasks.map(t => t.id);
    });
    await frame.locator('#file-list input[type=search]').fill('demo');
    await until(() => frame.locator('.file-row').count().then(n => n === 2));
    fixture.stdin.write('replace-text\n');
    await until(() => output.includes('CONTROL replace-text ok'));
    await frame.locator('#workspace-refresh').waitFor({ state: 'visible' });
    const tag = await frame.locator('#workspace-refresh').evaluate(node => {
      const style = getComputedStyle(node), color = v => v.match(/[\d.]+/g).slice(0,3).map(Number);
      const luminance = c => c.map(n => n / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4).reduce((s,n,i) => s + n * [.2126,.7152,.0722][i], 0);
      const a = luminance(color(style.color)), b = luminance(color(style.backgroundColor));
      return { contrast: (Math.max(a,b) + .05) / (Math.min(a,b) + .05), border: style.borderTopWidth, height: node.getBoundingClientRect().height };
    });
    assert.ok(tag.contrast >= 4.5); assert.equal(tag.border, '0px'); if (width === 390) assert.ok(tag.height >= 44);
    await page.screenshot({ path: path.join(evidence, `update-${width}.png`) });
    await frame.locator('#workspace-refresh').click();
    await frame.locator('.file-name', { hasText: 'demo-next.txt' }).waitFor();
    const after = await frame.evaluate(() => ({
      session: sessionId, version: activeFileVersion, files: Object.keys(previewFiles),
      managerPreserved: qaManager === activeDownloads.manager,
      tasksPreserved: JSON.stringify(qaTaskIds) === JSON.stringify(activeDownloads.manager.tasks.map(t => t.id)),
      filter: document.querySelector('#file-list input[type=search]').value,
      overflow: document.documentElement.scrollWidth > innerWidth
    }));
    assert.equal(after.session, identity.session); assert.notEqual(after.version, identity.version);
    assert.deepEqual(after.files.sort(), ['markdown', 'text-next']);
    assert.ok(after.managerPreserved && after.tasksPreserved); assert.equal(after.filter, 'demo'); assert.equal(after.overflow, false);
    assert.equal(await frame.locator('#workspace-refresh').isVisible(), false);
    const bytes = await frame.evaluate(async () => {
      const response = await fetch(downloadUrl('text-next'));
      return { status: response.status, text: await response.text(), old: (await fetch(downloadUrl('text'))).status };
    });
    assert.equal(bytes.status, 200); assert.equal(bytes.text, replacement); assert.equal(bytes.old, 410);
    // Retry learns the old ID is gone, not an instruction to splice replacement data.
    await frame.evaluate(() => {
      const m = activeDownloads.manager;
      m.tasks.forEach(t => m.start(t));
    });
    await frame.waitForFunction(() => {
      const tasks = activeDownloads.manager.tasks;
      return tasks.some(t => t.source.fileId === 'text' && t.state === 'blocked') && tasks.some(t => t.source.fileId === 'markdown' && t.state === 'complete');
    }, null, { timeout: 30000 });
    const managed = await frame.evaluate(async () => {
      const m = activeDownloads.manager, old = m.tasks.find(t => t.source.fileId === 'text'), keep = m.tasks.find(t => t.source.fileId === 'markdown');
      const file = await (await m.directory.getFileHandle(keep.record.outputName)).getFile();
      const entries = []; for await (const name of m.directory.keys()) entries.push(name);
      return { oldState: old.state, oldError: old.error, content: await file.text(), entries };
    });
    assert.equal(managed.oldError, 'sourceEnded'); assert.equal(managed.content, kept);
    assert.equal(managed.entries.filter(n => n.endsWith('.ls')).length, 0);
    fixture.stdin.write('withdraw-text\n'); await until(() => output.includes('CONTROL withdraw-text ok'));
    await frame.locator('#workspace-refresh').waitFor({ state: 'visible' }); await frame.locator('#workspace-refresh').click();
    await frame.waitForFunction(() => Object.keys(previewFiles).length === 1);
    fixture.stdin.write('withdraw-markdown\n'); await until(() => output.includes('CONTROL withdraw-markdown ok'));
    await frame.locator('#workspace-refresh').waitFor({ state: 'visible' }); await frame.locator('#workspace-refresh').click();
    await frame.waitForFunction(() => Object.keys(previewFiles).length === 0);
    assert.equal(await frame.evaluate(() => activeDownloads.manager.tasks.length), 2);
    assert.equal((await context.request.get(base + 'api/localsend/v2/info')).status(), 200);
    await page.locator('#tab-upload').click(); await page.locator('#pane-upload iframe').waitFor();
    await page.locator('#tab-download').click();
    await page.screenshot({ path: path.join(evidence, `empty-${width}.png`) });
    results.push({ width, pin: width === 390, ...after, oldStatus: bytes.old, oldCacheRemoved: true, partial, tag, keptBytes: Buffer.byteLength(managed.content), listenerPreserved: true });
    await context.close();
    const exited = new Promise(resolve => fixture.once('exit', resolve)); fixture.stdin.end(); await exited; fixture = null;
    fs.rmSync(root, { recursive: true });
  }
  assert.deepEqual(errors, []);
  fs.writeFileSync(path.join(evidence, 'results.json'), JSON.stringify({ results, errors }, null, 2));
  console.log(JSON.stringify({ results, errors, evidence }, null, 2));
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => { fixture?.stdin.end(); await browser?.close(); });
