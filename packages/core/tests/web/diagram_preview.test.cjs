const { test } = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs'),
  vm = require('node:vm'),
  { webcrypto, createHash } = require('node:crypto'),
  path = require('node:path');
const { domFixture } = require('./dom_fixture.cjs');
const source = fs.readFileSync(path.join(__dirname, '../../assets/web/diagram-preview.js'), 'utf8');
function fixture() {
  const dom = domFixture(),
    events = {},
    timers = new Map();
  let timer = 0,
    observer;
  const create = dom.document.createElement;
  dom.document.hidden = false;
  dom.document.addEventListener = (n, fn) => (events[n] = fn);
  dom.document.removeEventListener = (n) => delete events[n];
  dom.document.createElement = (tag) => {
    const n = create(tag);
    n.rect = { top: 0, bottom: 200 };
    n.getBoundingClientRect = () => n.rect;
    n.listeners = {};
    n.addEventListener = (e, fn) => (n.listeners[e] = fn);
    n.append = (...nodes) => nodes.forEach((v) => n.appendChild(v));
    n.replaceChildren = (...nodes) => {
      n.children.slice().forEach((v) => v.remove());
      n.append(...nodes);
    };
    n.contentWindow = {
      messages: [],
      postMessage(data, origin) {
        this.messages.push({ data, origin });
      }
    };
    return n;
  };
  const root = {
    document: dom.document,
    TextEncoder,
    Uint32Array,
    crypto: webcrypto,
    postMessage() {},
    addEventListener: (n, fn) => (events[n] = fn),
    removeEventListener: (n) => delete events[n],
    setTimeout: (fn) => {
      timers.set(++timer, fn);
      return timer;
    },
    clearTimeout: (id) => timers.delete(id),
    IntersectionObserver: class {
      constructor(fn) {
        observer = this;
        this.callback = fn;
      }
      observe() {}
      unobserve() {}
      disconnect() {
        this.disconnected = true;
      }
    },
    matchMedia: () => ({ matches: false, addEventListener: (n, fn) => (events.theme = fn), removeEventListener: () => delete events.theme })
  };
  vm.createContext(root);
  vm.runInContext(source, root);
  const container = dom.document.createElement('div');
  container.rect = { top: 0, bottom: 400 };
  dom.document.body.appendChild(container);
  const manager = new root.LegnaDiagrams.Manager({ container });
  function block(kind = 'mermaid', text = 'flowchart LR\nA-->B') {
    const el = manager.block(kind, text);
    container.appendChild(el);
    return manager.blocks.at(-1);
  }
  function flush() {
    if (manager.resumeTimer) {
      const id = manager.resumeTimer,
        fn = timers.get(id);
      timers.delete(id);
      fn();
    }
  }
  function near(blocks) {
    observer.callback(manager.blocks.map((b) => ({ target: b.element, isIntersecting: blocks.includes(b) })));
    flush();
  }
  function message(b, data, origin = 'null', token = b.token) {
    events.message({ source: b.frame.contentWindow, origin, data: { token, ...data } });
    flush();
  }
  return {
    ...dom,
    root,
    container,
    manager,
    block,
    near,
    flush,
    message,
    events,
    timers,
    get observer() {
      return observer;
    }
  };
}
test('diagram fences accept mermaid, markmap and the markedmap alias only', () => {
  const { kind } = require('../../assets/web/diagram-preview.js');
  assert.equal(kind('mermaid'), 'mermaid');
  assert.equal(kind(' MARKEDMAP extra '), 'markmap');
  assert.equal(kind('markmap'), 'markmap');
  assert.equal(kind('html'), null);
});
test('viewport scheduling keeps only two frames and destroys offscreen renderers', () => {
  const f = fixture(),
    blocks = [f.block(), f.block(), f.block()];
  f.near(blocks);
  assert.equal(f.manager.frames, 0);
  f.manager.setActive(true);
  assert.equal(f.manager.frames, 2);
  assert.ok(!blocks[2].frame);
  const stale = blocks[0].frame;
  f.near([blocks[2]]);
  assert.equal(f.manager.frames, 1);
  assert.equal(stale.parentNode, null);
  assert.ok(blocks[2].frame);
  f.manager.close();
  assert.equal(f.timers.size, 0);
  assert.ok(f.observer.disconnected);
});
test('frames have opaque sandboxing and validate window, origin and token', () => {
  const f = fixture(),
    b = f.block();
  f.near([b]);
  f.manager.setActive(true);
  assert.equal(b.frame.getAttribute('sandbox'), 'allow-scripts');
  b.frame.listeners.load();
  assert.equal(b.frame.contentWindow.messages[0].data.source, b.source);
  assert.equal(b.frame.src, '/assets/diagram-frame.html');
  f.message(b, { type: 'ready' }, 'http://fixture');
  assert.equal(b.ready, false);
  f.message(b, { type: 'ready' }, 'null', 'bad');
  assert.equal(b.ready, false);
  f.events.message({ source: {}, origin: 'null', data: { type: 'ready', token: b.token } });
  assert.equal(b.ready, false);
  f.message(b, { type: 'ready', height: 9999 });
  assert.equal(b.ready, true);
  assert.equal(b.height, 320);
  f.manager.close();
});
test('successful Mermaid results use bounded cache on reentry; inactive views release everything', () => {
  const f = fixture(),
    b = f.block();
  f.near([b]);
  f.manager.setActive(true);
  f.message(b, { type: 'ready', cache: { kind: 'mermaid', svg: '<svg />' } });
  const token = b.token;
  f.manager.setActive(false);
  assert.equal(f.manager.frames, 0);
  assert.equal(f.manager.cache.size, 1);
  f.manager.setActive(true);
  f.flush();
  b.frame.listeners.load();
  assert.equal(b.frame.contentWindow.messages[0].data.cache.svg, '<svg />');
  assert.notEqual(b.token, token);
  f.document.hidden = true;
  f.events.visibilitychange();
  assert.equal(f.manager.frames, 0);
  f.manager.close();
  assert.equal(f.manager.cacheBytes, 0);
  assert.equal(Object.keys(f.events).length, 0);
});
test('errors, source view and retry stay scoped to one diagram and discard damaged cache', () => {
  const f = fixture(),
    a = f.block(),
    b = f.block('markedmap', '# Plan');
  f.near([a, b]);
  f.manager.setActive(true);
  f.message(a, { type: 'ready', cache: { kind: 'mermaid', svg: 'bad' } });
  f.message(a, { type: 'error' });
  assert.equal(a.element.dataset.state, 'error');
  assert.equal(a.pre.hidden, false);
  assert.equal(a.stage.hidden, true);
  assert.equal(f.manager.cache.size, 0);
  assert.ok(b.frame);
  a.retry.listeners.click();
  assert.ok(a.frame);
  a.toggle.listeners.click();
  assert.equal(a.frame, null);
  assert.ok(b.frame);
  f.manager.close();
});
test('source byte, line and block limits retain literal source without creating frames', () => {
  const f = fixture();
  for (const text of ['x'.repeat(16385), '绿'.repeat(6000), 'x\n'.repeat(501)]) {
    const b = f.block('mermaid', text);
    assert.equal(b.error, 'limit');
    assert.equal(b.pre.textContent, text);
  }
  for (let i = f.manager.blocks.length; i < 64; i++) f.block();
  const fallback = f.manager.block('mermaid', 'flowchart LR\nA-->B');
  assert.match(fallback.textContent, /preview limit/);
  assert.equal(f.manager.blocks.length, 64);
  f.manager.close();
});
test('result cache counts UTF-16 storage conservatively and evicts least recently used entries', () => {
  const f = fixture(),
    blocks = Array.from({ length: 20 }, () => f.block());
  for (const b of blocks) f.manager.put(b, { svg: 'x'.repeat(140000) });
  assert.ok(f.manager.cacheBytes <= 4 * 1024 * 1024);
  assert.ok(f.manager.cache.size < 20);
  assert.ok(!f.manager.cache.has(blocks[0]));
  assert.ok(f.manager.cache.has(blocks.at(-1)));
  f.manager.put(blocks[0], { svg: 'x'.repeat(300000) });
  assert.ok(!f.manager.cache.has(blocks[0]));
  f.manager.close();
});
test('dependency loading and rendering use separate cancellable deadlines', () => {
  const f = fixture(),
    b = f.block();
  f.near([b]);
  f.manager.setActive(true);
  const first = b.deadline;
  f.message(b, { type: 'rendering' });
  assert.notEqual(b.deadline, first);
  assert.ok(!f.timers.has(first));
  f.message(b, { type: 'ready' });
  assert.ok(!f.timers.has(b.deadline));
  f.manager.close();
});
test('timeout releases the frame and closing rejects all stale responses', () => {
  const f = fixture(),
    b = f.block();
  f.near([b]);
  f.manager.setActive(true);
  f.timers.get(b.deadline)();
  assert.equal(b.error, 'timeout');
  assert.equal(f.manager.frames, 0);
  b.retry.listeners.click();
  f.flush();
  const event = { origin: 'null', source: b.frame.contentWindow, data: { token: b.token, type: 'ready' } };
  f.manager.close();
  f.manager.message(event);
  assert.equal(f.manager.frames, 0);
  assert.equal(f.manager.cache.size, 0);
});
test('offline bundles are pinned, hashed, licensed and served from a generated allowlist', () => {
  const root = path.join(__dirname, '../../assets/web/vendor/diagrams'),
    manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  for (const file of manifest.assets) {
    const bytes = fs.readFileSync(path.join(root, file.file));
    assert.equal(bytes.length, file.bytes);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), file.sha256);
  }
  for (const name of ['mermaid', 'markmap-lib', 'markmap-view', 'dompurify']) assert.ok(manifest.dependencies.some((d) => d.name === name));
  assert.ok(fs.readFileSync(path.join(root, 'LICENSES.txt'), 'utf8').includes('Permission is hereby granted'));
  const server = fs.readFileSync(path.join(__dirname, '../../src/http/server/web.rs'), 'utf8');
  assert.match(server, /sandbox allow-scripts; default-src 'none'/);
  assert.match(server, /connect-src 'none'/);
  assert.doesNotMatch(fs.readFileSync(path.join(__dirname, '../../assets/web/diagram-frame.html'), 'utf8'), /https?:/);
});

test('Markdown tracks at most 64 diagrams and keeps further fences as literal bounded DOM', () => {
  const marked = require('../../assets/web/vendor/marked.umd.js');
  const markdown = require('../../assets/web/markdown-preview.js');
  const f = domFixture(),
    previous = global.LegnaDiagrams;
  global.LegnaDiagrams = require('../../assets/web/diagram-preview.js');
  const manager = {
    blocks: [],
    block() {
      this.blocks.push(1);
      return f.document.createElement('section');
    }
  };
  try {
    f.document.body.appendChild(markdown.render(marked.lexer('```mermaid\nflowchart LR\nA-->B\n```\n\n'.repeat(100)), f.document, manager));
    assert.equal(manager.blocks.length, 64);
    assert.equal(f.descendants().filter((n) => n.tag === 'pre').length, 36);
  } finally {
    if (previous === undefined) delete global.LegnaDiagrams;
    else global.LegnaDiagrams = previous;
  }
});


test('virtual block removal releases controllers while stable keys recover bounded results', () => {
  const f = fixture();
  const element = f.manager.block('markmap', '# Root', 'section:0');
  f.container.appendChild(element);
  const b = f.manager.blocks[0];
  f.manager.put(b, { tree: { content: 'Folded', payload: { fold: 1 } } });
  const parent = { contains: n => n === element };
  f.manager.detach(parent);
  assert.equal(f.manager.blocks.length, 0);
  assert.equal(f.manager.frames, 0);
  assert.equal(f.manager.cache.size, 1);
  f.manager.block('markmap', '# Root', 'section:0');
  const replacement = f.manager.blocks[0];
  assert.equal(JSON.parse(f.manager.cache.get(replacement.cacheKey)).tree.payload.fold, 1);
  f.manager.close(); assert.equal(f.manager.cacheBytes, 0);
});
