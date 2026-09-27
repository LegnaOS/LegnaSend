const { test } = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs'),
  vm = require('node:vm');
const { Geometry } = require('../../assets/web/image-preview.js'),
  { domFixture } = require('./dom_fixture.cjs');
function near(a, b) {
  assert.ok(Math.abs(a - b) < 1e-7, `${a} != ${b}`);
}
test('fit preserves aspect and small images are never enlarged automatically', () => {
  const large = new Geometry(2000, 1000, 800, 600);
  near(large.scale, 0.4);
  assert.deepEqual(large.transform(), { x: 0, y: 100, scale: 0.4 });
  const small = new Geometry(80, 120, 800, 600);
  assert.equal(small.scale, 1);
  assert.deepEqual(small.transform(), { x: 360, y: 240, scale: 1 });
});
test('zoom keeps the focal source pixel stable until the image boundary is reached', () => {
  const m = new Geometry(2000, 2000, 800, 600);
  m.zoom(1, 400, 300);
  const anchor = { x: 500, y: 340 },
    before = m.transform();
  const pixel = { x: (anchor.x - before.x) / before.scale, y: (anchor.y - before.y) / before.scale };
  m.zoom(2, anchor.x, anchor.y);
  const after = m.transform();
  near((anchor.x - after.x) / after.scale, pixel.x);
  near((anchor.y - after.y) / after.scale, pixel.y);
});
test('pan and scale stay bounded and finite under long input sequences', () => {
  const m = new Geometry(6000, 4000, 390, 320);
  for (let i = 0; i < 1000; i++) {
    m.zoom(i % 2 ? 100 : 0.00001, i % 390, i % 320);
    m.pan(i * 200, -i * 300);
    assert.ok(m.scale >= m.minimum && m.scale <= 8);
    const p = m.transform();
    assert.ok(Object.values(p).every(Number.isFinite));
    assert.ok(Math.abs(m.x) <= Math.max(0, (m.width * m.scale - m.viewWidth) / 2));
  }
  const saved = m.transform();
  m.pan(NaN, Infinity);
  m.zoom(NaN, 0, 0);
  assert.deepEqual(m.transform(), saved);
});
test('resize refits fit mode but retains and constrains a custom view', () => {
  const m = new Geometry(2000, 1000, 800, 600);
  m.resize(400, 300);
  assert.equal(m.scale, 0.2);
  m.zoom(1, 200, 150);
  m.pan(100, 80);
  m.resize(600, 450);
  assert.equal(m.scale, 1);
  assert.equal(m.x, 100);
  assert.equal(m.y, 80);
  m.fit();
  near(m.scale, 0.3);
  assert.equal(m.x, 0);
});
test('invalid and hidden dimensions do not introduce invalid geometry', () => {
  for (const bad of [0, -1, NaN, Infinity]) assert.throws(() => new Geometry(bad, 100, 100, 100), /dimensions/);
  const m = new Geometry(100, 100, 200, 200),
    before = m.transform();
  m.resize(0, 0);
  assert.deepEqual(m.transform(), before);
});
function fixture(options = {}) {
  const dom = domFixture(),
    events = new Map(),
    nodes = [],
    observers = [];
  function listen(target) {
    target.listeners = new Map();
    target.addEventListener = (type, fn) => {
      let list = target.listeners.get(type) || [];
      list.push(fn);
      target.listeners.set(type, list);
    };
    target.removeEventListener = (type, fn) =>
      target.listeners.set(
        type,
        (target.listeners.get(type) || []).filter((x) => x !== fn)
      );
    target.emit = (type, data = {}) => {
      const event = {
        preventDefault() {
          this.prevented = true;
        },
        ...data
      };
      for (const fn of target.listeners.get(type) || []) fn(event);
      return event;
    };
    return target;
  }
  const make = dom.document.createElement;
  dom.document.createElement = (tag) => {
    const n = listen(make(tag));
    n.clientWidth = 800;
    Object.defineProperty(n, 'clientHeight', {
      get() {
        return parseFloat(n.style.height) || 160;
      }
    });
    n.getBoundingClientRect = () => ({ left: 0, top: 0, width: n.clientWidth, height: n.clientHeight });
    n.append = (...values) => values.forEach((v) => n.appendChild(v));
    n.removeAttribute = (key) => {
      delete n.attributes[key];
    };
    n.classList.add = (cls) => n.classList.toggle(cls, true);
    n.classList.remove = (cls) => n.classList.toggle(cls, false);
    n.capture = new Set();
    n.setPointerCapture = (id) => n.capture.add(id);
    n.hasPointerCapture = (id) => n.capture.has(id);
    n.releasePointerCapture = (id) => n.capture.delete(id);
    nodes.push(n);
    return n;
  };
  const root = listen({
    document: dom.document,
    innerHeight: 900,
    ResizeObserver: class {
      constructor(fn) {
        this.fn = fn;
        observers.push(this);
      }
      observe() {}
      disconnect() {
        this.disconnected = true;
      }
    }
  });
  vm.createContext(root);
  vm.runInContext(fs.readFileSync(require.resolve('../../assets/web/image-preview.js'), 'utf8'), root);
  const container = dom.document.createElement('div'),
    image = dom.document.createElement('img');
  image.alt = 'Photo';
  if (options.decode) image.decode = options.decode;
  image.naturalWidth = 2000;
  image.naturalHeight = 1000;
  image.setAttribute('src', '/authorized');
  dom.document.body.appendChild(container);
  const controller = root.LegnaImagePreview.mount({ container, image });
  image.emit('load');
  return {
    ...dom,
    root,
    container,
    image,
    controller,
    nodes,
    observers,
    stage: nodes.find((n) => n.className === 'image-stage'),
    buttons: nodes.filter((n) => n.tag === 'button')
  };
}
test('component loads the authorized image in place and provides named controls', () => {
  const f = fixture();
  assert.equal(f.image.getAttribute('src'), '/authorized');
  assert.equal(f.image.draggable, false);
  assert.equal(f.stage.getAttribute('role'), 'region');
  assert.ok(f.image.style.transform.includes('scale(0.4)'));
  assert.deepEqual(
    f.buttons.map((b) => b.getAttribute('aria-label')),
    ['Zoom out', 'Zoom in', 'Fit', 'Actual size']
  );
  assert.equal(f.buttons[0].disabled, true);
  f.buttons[1].emit('click');
  assert.ok(Number(f.stage.dataset.scale) > 0.4);
  f.buttons[2].emit('click');
  assert.equal(Number(f.stage.dataset.scale), 0.4);
  f.controller.close();
});
test('ordinary wheel is not intercepted; modified wheel and keyboard zoom/pan without trapping Escape', () => {
  const f = fixture();
  assert.equal(f.stage.emit('wheel', { deltaY: 10 }).prevented, undefined);
  assert.equal(f.stage.emit('wheel', { ctrlKey: true, deltaY: -80, clientX: 400, clientY: 200 }).prevented, true);
  assert.ok(Number(f.stage.dataset.scale) > 0.4);
  f.stage.emit('keydown', { key: '1' });
  assert.equal(Number(f.stage.dataset.scale), 1);
  let x = Number(f.stage.dataset.x);
  f.stage.emit('keydown', { key: 'ArrowLeft' });
  assert.ok(Number(f.stage.dataset.x) > x);
  assert.equal(f.stage.emit('keydown', { key: 'Escape' }).prevented, undefined);
  f.stage.emit('keydown', { key: '0' });
  assert.equal(Number(f.stage.dataset.scale), 0.4);
  f.controller.close();
});
test('two pointers pinch and pan, cancellation releases capture, close removes all callbacks', () => {
  const f = fixture();
  f.stage.emit('pointerdown', { pointerId: 1, pointerType: 'touch', clientX: 350, clientY: 200 });
  f.stage.emit('pointerdown', { pointerId: 2, pointerType: 'touch', clientX: 450, clientY: 200 });
  f.stage.emit('pointermove', { pointerId: 2, clientX: 550, clientY: 200 });
  assert.ok(Number(f.stage.dataset.scale) > 0.4);
  assert.equal(f.stage.capture.size, 2);
  f.stage.emit('pointercancel', { pointerId: 1 });
  assert.equal(f.stage.capture.size, 1);
  const late = f.image.listeners.get('load')[0];
  f.controller.close();
  f.controller.close();
  late();
  assert.equal(f.stage.capture.size, 0);
  assert.equal(f.image.getAttribute('src'), null);
  assert.equal(f.container.children.length, 0);
  assert.ok(f.observers.every((o) => o.disconnected));
  assert.ok([...f.nodes, f.root].every((n) => [...n.listeners.values()].every((v) => !v.length)));
});
test('image load errors disable the viewport controls without creating another modal', () => {
  const f = fixture();
  f.image.emit('error');
  assert.equal(f.stage.hidden, true);
  assert.ok(f.buttons.every((b) => b.disabled));
  assert.equal(f.descendants().filter((n) => n.tag === 'dialog').length, 0);
  f.controller.close();
});

test('decoded pixels, not just load metadata, complete the image ready promise', async () => {
  let finish;
  const f = fixture({
    decode: () =>
      new Promise((resolve) => {
        finish = resolve;
      })
  });
  assert.ok(f.buttons.every((b) => b.disabled));
  finish();
  await f.controller.ready;
  assert.equal(Number(f.stage.dataset.scale), 0.4);
  f.controller.close();
});

test('closing during image decode rejects only the old preview and ignores the late result', async () => {
  let finish;
  const f = fixture({
    decode: () =>
      new Promise((resolve) => {
        finish = resolve;
      })
  });
  f.controller.close();
  await assert.rejects(f.controller.ready, /closed/);
  finish();
  await Promise.resolve();
  assert.equal(f.container.children.length, 0);
  assert.ok(f.buttons.every((b) => b.disabled));
});

test('decoder failure keeps controls disabled and reports through the ready contract', async () => {
  const f = fixture({ decode: () => Promise.reject(new Error('decoder')) });
  await assert.rejects(f.controller.ready, /image/);
  assert.equal(f.stage.hidden, true);
  assert.ok(f.buttons.every((b) => b.disabled));
  f.controller.close();
});

test('window blur releases held pointers and no-op panning keeps fit mode', () => {
  const model = new Geometry(2000, 1000, 800, 600);
  model.pan(50, 30);
  assert.equal(model.mode, 'fit');
  const f = fixture();
  f.stage.emit('pointerdown', { pointerId: 9, pointerType: 'mouse', button: 0, clientX: 100, clientY: 100 });
  assert.equal(f.stage.capture.size, 1);
  f.root.emit('blur');
  assert.equal(f.stage.capture.size, 0);
  f.controller.close();
});

test('missing or interrupted pointer capture still ends the gesture on window pointer-up', () => {
  const f = fixture();
  f.stage.setPointerCapture = () => {
    throw new Error('inactive pointer');
  };
  assert.doesNotThrow(() => f.stage.emit('pointerdown', { pointerId: 42, pointerType: 'mouse', button: 0, clientX: 100, clientY: 100 }));
  f.root.emit('pointerup', { pointerId: 42 });
  assert.equal(f.stage.className.includes('image-dragging'), false);
  f.controller.close();
});
