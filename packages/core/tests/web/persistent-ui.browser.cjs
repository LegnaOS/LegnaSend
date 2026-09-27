// Uses the isolated browser after persistent-downloads.browser.cjs.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright'),
  fs = require('fs'),
  assert = require('assert/strict');
(async () => {
  const b = await chromium.connectOverCDP(process.env.LEGNASEND_QA_CDP),
    p = b.contexts()[0].pages()[0],
    root = require('path').resolve(process.env.LEGNASEND_QA_ROOT);
  let picks = 0;
  await p.exposeFunction('qaPicked', () => picks++);
  await p.evaluate(() => {
    const picker = showDirectoryPicker;
    window.showDirectoryPicker = (...a) => {
      qaPicked();
      return picker(...a);
    };
  });
  const downloadDir = fs.mkdtempSync(root + '/ordinary-');
  const cdp = await p.context().newCDPSession(p);
  await cdp.send('Browser.setDownloadBehavior', {
    behavior: 'allow',
    browserContextId: (await cdp.send('Target.getTargetInfo')).targetInfo.browserContextId,
    downloadPath: downloadDir,
    eventsEnabled: true
  });
  const native = p.waitForEvent('download');
  await p.locator('.file-row').filter({ hasText: 'demo.txt' }).locator('.file-name').click();
  const download = await native;
  for (let i = 0; i < 600 && !fs.existsSync(downloadDir + '/demo.txt'); i++) await new Promise((r) => setTimeout(r, 100));
  assert.deepEqual(fs.readFileSync(downloadDir + '/demo.txt'), fs.readFileSync(root + '/demo.txt'));
  assert.equal(picks, 0);
  await p.locator('.file-row').filter({ hasText: 'demo.md' }).locator('.managed-download').click();
  await p.waitForFunction(() => activeDownloads.manager.tasks.length === 2);
  await p.locator('.download-task').last().getByRole('button', { name: '暂停', exact: true }).click();
  await p.waitForFunction(() => activeDownloads.manager.tasks[1].state === 'paused' && !activeDownloads.manager.tasks[1].promise, null, {
    timeout: 60000
  });
  await p.setViewportSize({ width: 390, height: 844 });
  await p.emulateMedia({ colorScheme: 'dark' });
  await p.locator('#web-language').selectOption('zh-TW');
  await p.locator('.download-task').last().getByRole('button', { name: '移除工作', exact: true }).click();
  await p.waitForTimeout(250);
  await p.screenshot({ path: root + '/persistent-remove-mobile.png' });
  assert.equal(await p.locator('dialog[open]').count(), 1);
  assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  await p.getByRole('button', { name: '取消', exact: true }).click();
  assert.equal(await p.locator('dialog[open]').count(), 0);
  assert.equal(await p.locator('.download-task').count(), 2);
  await p.locator('.download-task').last().getByRole('button', { name: '移除工作', exact: true }).click();
  await p.locator('dialog').getByRole('button', { name: '移除工作', exact: true }).click();
  await p.waitForFunction(() => activeDownloads.manager.tasks.length === 1);
  await p.waitForTimeout(250);
  await p.screenshot({ path: root + '/persistent-complete-mobile.png' });
  await p.setViewportSize({ width: 1280, height: 800 });
  await p.emulateMedia({ colorScheme: 'light' });
  await p.locator('#web-language').selectOption('en');
  await p.waitForTimeout(250);
  await p.screenshot({ path: root + '/persistent-complete-desktop.png' });
  console.log('PASS ordinary original bytes, no picker, modal cancel/remove, zh-TW 390 dark no overflow');
  process.exit();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
