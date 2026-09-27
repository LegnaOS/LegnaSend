// Requires a free QA port previously authorized by the isolated browser.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright'),
  fs = require('fs'),
  assert = require('assert/strict'),
  { spawn } = require('child_process'),
  { createHash } = require('crypto');
const root = require('path').resolve(process.env.LEGNASEND_QA_ROOT),
  dir = root + '/directory-fixture';
fs.mkdirSync(dir + '/a', { recursive: true });
fs.mkdirSync(dir + '/b', { recursive: true });
const bytes = fs.readFileSync(root + '/demo.txt').subarray(0, 5 * 1048576 + 31);
fs.writeFileSync(dir + '/a/directory.bin', bytes);
fs.writeFileSync(dir + '/b/private.txt', 'independent');
let fixture,
  stdout = '';
const wait = async (fn) => {
  for (let i = 0; i < 2000; i++) {
    const r = await fn();
    if (r) return r;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw Error('condition timeout');
};
(async () => {
  fixture = spawn(process.cwd() + '/target/debug/examples/directory_workspace_fixture', [dir], {
    env: { ...process.env, LEGNASEND_FIXTURE_PORT: process.env.LEGNASEND_QA_PORT },
    stdio: ['pipe', 'pipe', 'inherit']
  });
  fixture.stdout.on('data', (d) => (stdout += d));
  await wait(() => stdout.includes('http://127.0.0.1:' + process.env.LEGNASEND_QA_PORT + '/'));
  async function command(c) {
    const at = stdout.length;
    fixture.stdin.write(c + '\n');
    await wait(() => stdout.slice(at).includes('revision'));
  }
  await command('protect-a');
  const b = await chromium.connectOverCDP(process.env.LEGNASEND_QA_CDP),
    p = b.contexts()[0].pages()[0],
    errors = [];
  p.on('pageerror', (e) => errors.push(e.message));
  await p.goto('http://127.0.0.1:' + process.env.LEGNASEND_QA_PORT + '/design/');
  await p.locator('#language').selectOption('en');
  await p.locator('#auth-password').fill('fixture-password');
  await p.locator('#auth-submit').click();
  await p.locator('.managed-download').waitFor();
  const all = () => p.evaluate(async () => await new LegnaDownloadRegistry().all());
  await p.route('**/content?**', async (r) => {
    if (r.request().headers().range) await new Promise((resolve) => setTimeout(resolve, 400));
    await r.continue();
  });
  async function pausedTask() {
    await p.locator('.managed-download').click();
    const last = p.locator('.download-task').last();
    await p.waitForFunction(
      () => {
        const r = [...document.querySelectorAll('.download-task')].at(-1);
        return r?.querySelector('.download-metrics').textContent.includes('Awaiting checkpoint');
      },
      null,
      { timeout: 60000 }
    );
    await last.getByRole('button', { name: 'Pause', exact: true }).click();
    await p.waitForFunction(
      () => document.querySelectorAll('.download-task')[document.querySelectorAll('.download-task').length - 1]?.dataset.state === 'paused',
      null,
      { timeout: 60000 }
    );
    return (await all()).filter((r) => r.source.kind === 'directory').at(-1);
  }
  const paused = await pausedTask();
  assert.equal(paused.committedBytes, 4 * 1048576);
  assert.ok(fs.existsSync(root + '/Downloads/' + paused.cacheName));
  await p.locator('#logout').click();
  await p.locator('.download-task').last().getByRole('button', { name: 'Continue', exact: true }).click();
  await p.locator('#auth[open]').waitFor();
  await p.waitForFunction(() => [...document.querySelectorAll('.download-task')].at(-1)?.dataset.state === 'failed');
  let auth = (await all()).find((r) => r.id === paused.id);
  assert.equal(auth.error, 'authRequired');
  assert.equal(auth.committedBytes, paused.committedBytes);
  await p.locator('#auth-password').fill('fixture-password');
  await p.locator('#auth-submit').click();
  await p.locator('.managed-download').waitFor();
  await p.locator('.download-task').last().getByRole('button', { name: 'Try again', exact: true }).click();
  await p.waitForFunction(() => [...document.querySelectorAll('.download-task')].at(-1)?.dataset.state === 'complete', null, {
    timeout: 120000
  });
  const complete = (await all()).find((r) => r.id === paused.id);
  assert.deepEqual(fs.readFileSync(root + '/Downloads/' + complete.outputName), bytes);
  assert.ok(!fs.existsSync(root + '/Downloads/' + paused.cacheName));
  const second = await pausedTask();
  await command('close-a');
  await p.locator('.download-task').last().getByRole('button', { name: 'Continue', exact: true }).click();
  await p.waitForFunction(() => [...document.querySelectorAll('.download-task')].at(-1)?.dataset.state === 'blocked', null, {
    timeout: 60000
  });
  const blocked = (await all()).find((r) => r.id === second.id);
  assert.equal(blocked.error, 'sourceEnded');
  assert.ok(!fs.existsSync(root + '/Downloads/' + second.cacheName));
  assert.equal((await p.context().request.get('http://127.0.0.1:' + process.env.LEGNASEND_QA_PORT + '/private/?meta')).status(), 200);
  assert.deepEqual(errors, []);
  await p.setViewportSize({ width: 390, height: 844 });
  await p.emulateMedia({ colorScheme: 'dark' });
  await p.locator('#language').selectOption('zh-TW');
  await p.screenshot({ path: root + '/persistent-directory-mobile.png' });
  assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  fs.writeFileSync(
    root + '/directory-download-results.json',
    JSON.stringify(
      {
        bytes: bytes.length,
        sha256: createHash('sha256').update(bytes).digest('hex'),
        pausedBytes: paused.committedBytes,
        authRetry: true,
        sourceEndedCleanup: true,
        independentWorkspace: true,
        pageErrors: errors
      },
      null,
      2
    )
  );
  console.log('PASS directory grants, pause, 401 retain, unlock/retry, completed hash, 404 owned cleanup, independent workspace');
})()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(() => {
    if (fixture) fixture.stdin.write('quit\n');
    setTimeout(() => process.exit(process.exitCode || 0), 1000);
  });
