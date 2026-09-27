// Verify real late seeks, not only setting currentTime inside an already buffered clip.
const assert = require('node:assert/strict'),
  fs = require('node:fs'),
  os = require('node:os'),
  path = require('node:path'),
  { spawn, spawnSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..'),
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-media-range-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-media-range-evidence');
fs.mkdirSync(evidence, { recursive: true });
fs.mkdirSync(root + '/a');
fs.mkdirSync(root + '/b');
function generate(args) {
  const result = spawnSync(process.env.FFMPEG_PATH || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], {
    encoding: 'utf8',
    timeout: 120000
  });
  assert.equal(result.status, 0, result.stderr);
}
let fixture,
  browser,
  output = '';
const errors = [],
  requests = [],
  responses = [],
  results = [];
async function until(fn) {
  for (let i = 0; i < 1600; i++) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw Error('timeout');
}
(async () => {
  generate([
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=640x360:rate=24',
    '-t',
    '60',
    '-c:v',
    'libvpx-vp9',
    '-deadline',
    'realtime',
    '-cpu-used',
    '8',
    '-threads',
    '4',
    '-b:v',
    '1500k',
    '-g',
    '24',
    root + '/a/late.webm'
  ]);
  generate([
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:sample_rate=44100',
    '-t',
    '120',
    '-c:a',
    'libmp3lame',
    '-b:a',
    '192k',
    root + '/a/late.mp3'
  ]);
  generate(['-f','lavfi','-i','testsrc2=size=640x360:rate=24','-t','60','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-b:v','1500k','-g','24','-movflags','+faststart',root + '/a/late.mp4']);
  generate(['-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','120','-c:a','pcm_s16le',root + '/a/late.wav']);
  fs.writeFileSync(root + '/b/independent.txt', 'other workspace');
  fixture = spawn(path.join(repo, 'target/debug/examples/directory_workspace_fixture'), [root]);
  fixture.stdout.on('data', (d) => (output += d));
  fixture.stderr.on('data', (d) => process.stderr.write(d));
  const url = await until(() => output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  const context = await browser.newContext({ viewport: { width: 1000, height: 800 }, locale: 'en' }),
    page = await context.newPage();
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('request', (r) => {
    if (r.url().includes('/content?')) requests.push({ url: r.url(), method: r.method(), range: r.headers().range || null });
  });
  page.on('response', (r) => {
    if (r.url().includes('/content?'))
      responses.push({
        url: r.url(),
        method: r.request().method(),
        range: r.request().headers().range || null,
        status: r.status(),
        contentRange: r.headers()['content-range'] || null
      });
  });
  await page.goto(url + 'design/');
  await page.locator('.preview-button').first().waitFor();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.emulateNetworkConditions', {
    offline: false,
    latency: 20,
    downloadThroughput: 128 * 1024,
    uploadThroughput: 128 * 1024
  });
  for (const [name, tag, target] of [
    ['late.mp4', 'video', 50],
    ['late.webm', 'video', 50],
    ['late.mp3', 'audio', 100],
    ['late.wav', 'audio', 100]
  ]) {
    const size = fs.statSync(root + '/a/' + name).size,
      marker = '/' + Buffer.from(name).toString('base64url') + '/content';
    await page.locator(`.row[title="${name}"] .preview-button`).click();
    await page.locator('#directory-preview .media-preview-player[data-state="paused"]').waitFor({timeout:40000});
    await page.locator('#directory-preview .media-preview-resume').click();
    await page.waitForFunction((tag) => document.querySelector('#directory-preview ' + tag)?.duration > 30, tag, { timeout: 40000 });
    const media = page.locator('#directory-preview ' + tag);
    assert.equal(await media.getAttribute('preload'), 'metadata');
    assert.equal(await media.evaluate(m => m.controls), true);
    if (tag === 'video') {
      // Exercise the element's actual fullscreen lifecycle with browser activation.
      await media.evaluate(m => m.requestFullscreen());
      await page.waitForFunction(() => document.fullscreenElement?.tagName === 'VIDEO');
      await page.evaluate(() => document.exitFullscreen());
      await page.waitForFunction(() => document.fullscreenElement === null);
    }
    await media.evaluate(m => { m.volume = 0.4; m.playbackRate = 1.25; });
    assert.deepEqual(await media.evaluate(m => [m.volume, m.playbackRate]), [0.4, 1.25]);
    await media.evaluate(async (m) => {
      m.muted = true;
      await m.play();
    });
    await page.waitForFunction((tag) => document.querySelector('#directory-preview ' + tag)?.currentTime > 0.1, tag);
    await media.evaluate((m) => m.pause());
    const before = await media.evaluate((m) => ({
      time: m.currentTime,
      buffered: Array.from({ length: m.buffered.length }, (_, i) => [m.buffered.start(i), m.buffered.end(i)])
    }));
    assert.ok(before.buffered.every(([a, b]) => target < a || target > b));
    const at = requests.length;
    await page.locator('#directory-preview .media-preview-player[data-state="paused"]').waitFor();
    await page.locator('#directory-preview .media-preview-position').evaluate((slider, target) => {
      slider.value = String(target); slider.dispatchEvent(new Event('input'));
    }, target);
    await page.locator('#directory-preview .media-preview-resume').click();
    await until(async () => await media.evaluate((m, t) => m.currentTime > t + 0.1 && !m.seeking && m.readyState >= 2, target)).catch(async error => {
      console.error(JSON.stringify({name,state:await media.evaluate(m=>({time:m.currentTime,duration:m.duration,ready:m.readyState,seeking:m.seeking,paused:m.paused,error:m.error?.code,buffered:Array.from({length:m.buffered.length},(_,i)=>[m.buffered.start(i),m.buffered.end(i)])})),requests:requests.slice(at),responses:responses.filter(r=>r.url.includes(marker))})); throw error;
    });
    const late = requests
      .slice(at)
      .filter((r) => r.url.includes(marker) && r.range && Number(r.range.match(/^bytes=(\d+)/)?.[1]) > size / 2);
    assert.ok(late.length > 0, 'late range ' + name);
    await media.evaluate((m) => m.pause());
    const handle = await media.elementHandle();
    await page.locator('#directory-preview-close').click();
    assert.ok(await handle.evaluate((m) => m.paused && !m.hasAttribute('src')));
    await until(async () => await handle.evaluate(m => m.readyState === 0 && m.buffered.length === 0)).catch(async error=>{console.error(JSON.stringify({name,cleanup:await handle.evaluate(m=>({src:m.getAttribute('src'),currentSrc:m.currentSrc,ready:m.readyState,network:m.networkState,paused:m.paused,buffered:m.buffered.length}))}));throw error;});
    await handle.dispose();
    const data = responses.filter((r) => r.url.includes(marker) && r.range);
    assert.ok(data.some((r) => r.status === 206 && r.contentRange && r.url.includes('version=')));
    results.push({
      name,
      size,
      target,
      before,
      lateRanges: late.map((r) => r.range),
      responses: data.map(({ range, status, contentRange }) => ({ range, status, contentRange })),
      cleanup: true,
      metadataPreload: true,
      controls: true,
      fullscreen: tag === 'video',
      volume: 0.4,
      playbackRate: 1.25
    });
  }
  assert.deepEqual(errors, []);
  const result = { browser: browser.version(), host: process.platform, throttleBytesPerSecond: 128 * 1024, results, errors };
  fs.writeFileSync(path.join(evidence, 'media-range-results.json'), JSON.stringify(result, null, 2) + '\n');
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
