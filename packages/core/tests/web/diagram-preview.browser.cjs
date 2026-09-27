// Real core HTTP, offline local bundles and opaque-origin frames in an isolated browser.
const assert = require('node:assert/strict'),
  fs = require('node:fs'),
  os = require('node:os'),
  path = require('node:path'),
  { spawn } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(__dirname, '../../../..'),
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'legnasend-diagrams-'));
const evidence = process.env.EVIDENCE_DIR || path.join(os.tmpdir(), 'legnasend-diagrams-evidence');
fs.mkdirSync(evidence, { recursive: true });
const fence = (lang, body) => '```' + lang + '\n' + body + '\n```\n\n';
const mermaid = 'flowchart LR\n A[开始] --> B{发送文件?}\n B -->|是| C[共享]\n B -->|否| D[等待]';
const map = '# LegnaSend\n## 发送\n- 文件\n- 目录\n## 接收\n- 暂停\n- 继续';
const hostileMap =
  '---\nmarkmap:\n extraJs: [https://example.invalid/plugin.js]\n extraCss: [https://example.invalid/style.css]\n---\n# 附件\n## <img src="https://example.invalid/pixel" onerror="parent.diagramAttack=1">\n- [unsafe](javascript:alert(1))\n- [remote](https://example.invalid/link)';
const hostileMermaid =
  '%%{init: {"securityLevel":"loose","themeCSS":"body{background:url(https://example.invalid/theme)}"}}%%\nflowchart LR\n A["<img src=https://example.invalid/mermaid onerror=parent.diagramAttack=1>"] --> B[完成]\n click B "https://example.invalid/link"';
const types = [
  ['classDiagram', 'classDiagram\n class Person {\n +String name\n }', 'Person'],
  ['erDiagram', 'erDiagram\n CUSTOMER ||--o{ ORDER : places', 'CUSTOMER'],
  ['stateDiagram', 'stateDiagram-v2\n [*] --> Ready\n Ready --> Done', 'Ready'],
  ['gantt', 'gantt\n title Schedule\n dateFormat YYYY-MM-DD\n section Work\n Task :2026-09-01, 2d', 'Schedule'],
  ['pie', 'pie title Files\n "Text" : 40\n "Media" : 60', 'Text'],
  ['mindmap', 'mindmap\n root((Plan))\n  Send\n   Files\n  Receive', 'Plan'],
  ['gitGraph', 'gitGraph\n commit\n branch develop\n checkout develop\n commit', 'develop']
];
const markdown =
  '# LegnaSend 图表\n\n' +
  fence('mermaid', mermaid) +
  '正文分隔。\n\n'.repeat(30) +
  fence('markedmap', map) +
  fence('mermaid', 'sequenceDiagram\n A->>B: Hello\n B->>A: OK') +
  fence('mermaid', 'not a diagram !!!') +
  fence('markmap', hostileMap) +
  fence('mermaid', hostileMermaid) +
  fence('mermaid', 'x'.repeat(16385)) +
  fence('markmap', '# Too many nodes\n' + Array.from({ length: 301 }, (_, i) => '- node ' + i).join('\n')) +
  fence(
    'mermaid',
    '%%{init: {"maxEdges":9999}}%%\nflowchart LR\n' + Array.from({ length: 210 }, (_, i) => 'N' + i + '-->N' + (i + 1)).join('\n')
  ) +
  fence('js', 'const original = true;');
fs.mkdirSync(root + '/a');
fs.mkdirSync(root + '/b');
fs.writeFileSync(root + '/a/diagrams.md', markdown);
fs.writeFileSync(root + '/b/independent.txt', 'independent');
fs.writeFileSync(root + '/b/types.md', types.map(([, body]) => fence('mermaid', body)).join(''));
let fixture,
  browser,
  stdout = '',
  failures = [],
  external = [],
  requests = [];
async function until(fn) {
  for (let i = 0; i < 400; i++) {
    const value = await fn();
    if (value) return value;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw Error('condition timed out');
}
(async () => {
  fixture = spawn(path.join(repo, 'target/debug/examples/directory_workspace_fixture'), [root]);
  fixture.stdout.on('data', (d) => (stdout += d));
  fixture.stderr.on('data', (d) => process.stderr.write(d));
  const url = await until(() => stdout.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0]);
  browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  const context = await browser.newContext({ viewport: { width: 1180, height: 880 }, locale: 'en', hasTouch: true });
  await context.route('**/*', (route) => {
    if (!route.request().url().startsWith(url)) {
      external.push(route.request().url());
      return route.abort();
    }
    return route.continue();
  });
  const page = await context.newPage();
  let activeFrames = 0,
    peakFrames = 0;
  page.on('frameattached', () => {
    activeFrames++;
    peakFrames = Math.max(peakFrames, activeFrames);
  });
  page.on('framedetached', () => activeFrames--);
  page.on('pageerror', (e) => failures.push(e.message));
  page.on('request', (r) => requests.push(new URL(r.url()).pathname));
  await page.goto(url + 'design/');
  await page.locator('.preview-button').click();
  await page.locator('.markdown-document h1').waitFor();
  const blocks = page.locator('.diagram-block'),
    viewport = page.locator('.markdown-viewport');
  assert.equal(await blocks.count(), 9);
  async function go(index) {
    await viewport.evaluate((v, i) => {
      const b = v.querySelectorAll('.diagram-block')[i];
      v.scrollTop += b.getBoundingClientRect().top - v.getBoundingClientRect().top;
    }, index);
  }
  async function state(index, wanted) {
    await page.waitForFunction(([i, s]) => document.querySelectorAll('.diagram-block')[i]?.dataset.state === s, [index, wanted], {
      timeout: 20000
    });
  }
  async function frame(index) {
    return (await blocks.nth(index).locator('iframe').elementHandle()).contentFrame();
  }
  await state(0, 'ready');
  assert.equal(await blocks.nth(1).locator('iframe').count(), 0);
  assert.ok((await page.locator('.diagram-block iframe').count()) <= 2);
  let flow = await frame(0);
  assert.ok((await flow.locator('svg').textContent()).includes('开始'));
  assert.equal(await blocks.nth(0).locator('iframe').getAttribute('sandbox'), 'allow-scripts');
  assert.equal(
    await flow.evaluate(() => {
      try {
        return parent.document.title;
      } catch (e) {
        return e.name;
      }
    }),
    'SecurityError'
  );
  assert.equal(
    await flow.evaluate(() => {
      try {
        return localStorage.length;
      } catch (e) {
        return e.name;
      }
    }),
    'SecurityError'
  );
  let before = await flow.locator('svg').evaluate((e) => e.viewBox.baseVal.width);
  await blocks.nth(0).getByRole('button', { name: 'Zoom in', exact: true }).click();
  await until(async () => (await flow.locator('svg').evaluate((e) => e.viewBox.baseVal.width)) < before);
  await blocks.nth(0).getByRole('button', { name: 'Fit', exact: true }).click();
  await page.screenshot({ path: path.join(evidence, 'diagrams-mermaid-desktop.png') });
  const initialFrames = await page.locator('.diagram-block iframe').count();
  await go(1);
  await state(1, 'ready');
  assert.equal(await blocks.nth(0).locator('iframe').count(), 0);
  const mind = await frame(1),
    nodes = await mind.locator('.markmap-node').count();
  assert.equal(nodes, 7);
  await blocks.nth(1).getByRole('button', { name: 'Collapse branches', exact: true }).click();
  await until(async () => (await mind.locator('.markmap-node').count()) === 3);
  await blocks.nth(1).getByRole('button', { name: 'Expand all', exact: true }).click();
  await until(async () => (await mind.locator('.markmap-node').count()) === 7);
  const keyNode = mind.locator('circle[role=button]').first();
  await keyNode.focus();
  await keyNode.press('Enter');
  await until(async () => (await mind.locator('.markmap-node').count()) < 7);
  await blocks.nth(1).getByRole('button', { name: 'Expand all', exact: true }).click();
  await until(async () => (await mind.locator('.markmap-node').count()) === 7);
  let transform = await mind.locator('svg').evaluate((e) => e.__zoom.k);
  await blocks.nth(1).getByRole('button', { name: 'Zoom in', exact: true }).click();
  await until(async () => (await mind.locator('svg').evaluate((e) => e.__zoom.k)) > transform);
  await blocks.nth(1).getByRole('button', { name: 'Fit', exact: true }).click();
  const canvasBox = await mind.locator('svg').boundingBox(),
    oldX = await mind.locator('svg').evaluate((e) => e.__zoom.x);
  await page.mouse.move(canvasBox.x + 12, canvasBox.y + 12);
  await page.mouse.down();
  await page.mouse.move(canvasBox.x + 42, canvasBox.y + 32);
  await page.mouse.up();
  await until(async () => (await mind.locator('svg').evaluate((e) => e.__zoom.x)) !== oldX);
  const cdp = await context.newCDPSession(page),
    center = { x: canvasBox.x + canvasBox.width / 2, y: canvasBox.y + canvasBox.height / 2 };
  const scaleBefore = await mind.locator('svg').evaluate((e) => e.__zoom.k);
  function points(span) {
    return [
      { x: center.x - span, y: center.y, id: 1 },
      { x: center.x + span, y: center.y, id: 2 }
    ];
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: points(20) });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: points(40) });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await until(async () => (await mind.locator('svg').evaluate((e) => e.__zoom.k)) > scaleBefore);
  await cdp.detach();
  await blocks.nth(1).getByRole('button', { name: 'Fit', exact: true }).click();
  await page.screenshot({ path: path.join(evidence, 'diagrams-markmap-desktop.png') });
  await blocks.nth(1).getByRole('button', { name: 'Collapse branches', exact: true }).click();
  await until(async () => (await mind.locator('.markmap-node').count()) === 3);
  const at = requests.length;
  await go(0);
  await state(0, 'ready');
  assert.ok(requests.slice(at).some((p) => p.includes('/cached-svg-')));
  assert.ok(!requests.slice(at).some((p) => p.includes('/mermaid-')));
  await go(1);
  await state(1, 'ready');
  assert.equal(await (await frame(1)).locator('.markmap-node').count(), 3);
  await go(3);
  await state(3, 'error');
  assert.ok(await blocks.nth(3).locator('.diagram-source').isVisible());
  await go(4);
  await state(4, 'ready');
  const hostile = await frame(4);
  assert.equal(await hostile.locator('img,a,script[src^="https:"]').count(), 0);
  assert.equal(await page.evaluate(() => window.diagramAttack), undefined);
  await go(5);
  await state(5, 'ready');
  const strict = await frame(5);
  assert.equal(await strict.locator('img,a,foreignObject').count(), 0);
  assert.equal(await page.evaluate(() => window.diagramAttack), undefined);
  assert.equal(await blocks.nth(6).getAttribute('data-state'), 'error');
  assert.equal(await blocks.nth(6).locator('iframe').count(), 0);
  await go(7);
  await state(7, 'error');
  await go(8);
  await state(8, 'error');
  // Source search releases render contexts, then reading view recreates only nearby blocks.
  await page.keyboard.press('Control+f');
  await page.locator('.text-query').fill('发送文件');
  await page.waitForFunction(() => document.querySelector('[data-current-match]')?.textContent === '发送文件');
  assert.equal(await page.locator('.diagram-block iframe').count(), 0);
  await page.locator('.text-view-button').click();
  await go(1);
  await state(1, 'ready');
  await page.locator('#directory-preview-close').click();
  assert.equal(await page.locator('.diagram-block iframe').count(), 0);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.locator('#language').selectOption('zh-TW');
  await page.locator('.preview-button').click();
  await state(0, 'ready');
  await go(1);
  await state(1, 'ready');
  assert.equal(await page.locator('#directory-preview').evaluate((e) => e.scrollWidth <= e.clientWidth), true);
  assert.equal(await page.locator('body').evaluate((e) => e.scrollWidth <= innerWidth), true);
  assert.ok(await blocks.nth(1).getByRole('button', { name: '全部展開', exact: true }).isVisible());
  await page.screenshot({ path: path.join(evidence, 'diagrams-markmap-mobile-hant.png') });
  // Source replacement revokes the whole reader, including its opaque frames.
  fs.appendFileSync(root + '/a/diagrams.md', '\nsource changed');
  await page.locator('#directory-preview[open]').waitFor({ state: 'hidden', timeout: 12000 });
  assert.equal(await page.locator('.diagram-block iframe').count(), 0);
  await page.setViewportSize({ width: 1180, height: 880 });
  await page.emulateMedia({ colorScheme: 'light' });
  await page.goto(url + 'private/');
  await page.locator('.row[title="types.md"] .preview-button').click();
  await blocks.first().waitFor();
  for (let i = 0; i < types.length; i++) {
    await go(i);
    await state(i, 'ready');
    assert.ok((await (await frame(i)).locator('svg').textContent()).includes(types[i][2]), types[i][0]);
  }
  await page.locator('#directory-preview-close').click();
  await until(() => activeFrames === 0);
  assert.equal(activeFrames, 0);
  assert.ok(peakFrames <= 2);
  assert.deepEqual(failures, []);
  assert.deepEqual(external, []);
  const result = {
    browser: browser.version(),
    host: process.platform,
    sourceBytes: Buffer.byteLength(markdown),
    blocks: 9,
    initialFrames,
    maxFrames: peakFrames,
    mermaid: true,
    markmapAlias: true,
    additionalMermaidTypes: types.map((t) => t[0]),
    collapseExpand: true,
    keyboardFold: true,
    zoom: true,
    panAndEmulatedPinch: true,
    foldStateReentry: true,
    nodeAndLockedEdgeLimits: true,
    cachedSvgReentry: true,
    localErrorIsolation: true,
    oversizedSource: true,
    opaqueOrigin: true,
    strictLinks: true,
    externalRequests: external,
    sourceSearch: true,
    closeCleanup: true,
    sourceChangeCleanup: true,
    mobileWidth: 390,
    errors: failures
  };
  fs.writeFileSync(path.join(evidence, 'diagram-preview-results.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
})()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (browser) await browser.close();
    if (fixture) fixture.stdin.write('quit\n');
    fs.rmSync(root, { recursive: true, force: true });
  });
