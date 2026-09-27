import { Transformer } from 'markmap-lib';
import { Markmap } from 'markmap-view';
import DOMPurify from 'dompurify';

window.LegnaDiagramRenderer = async function ({ source, cache, dark, container, changed }) {
  const transformer = new Transformer();
  transformer.md.set({ html: false, linkify: false });
  let input = cache?.kind === 'markmap' ? cache.root : transformer.transform(source).root;
  let count = 0;
  function clean(node, depth = 0) {
    if (!node || typeof node.content !== 'string' || ++count > 300 || depth > 32 || node.content.length > 4096) throw new Error('limit');
    return {
      content: DOMPurify.sanitize(node.content, {
        ALLOWED_TAGS: ['span', 'strong', 'em', 'b', 'i', 's', 'del', 'code', 'br', 'sub', 'sup'],
        ALLOWED_ATTR: []
      }),
      payload: { fold: node.payload?.fold ? 1 : 0 },
      children: (node.children || []).map((child) => clean(child, depth + 1))
    };
  }
  input = clean(input);
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('width', '100%');
  svg.setAttribute('height', '100%');
  container.replaceChildren(svg);
  const view = Markmap.create(svg, {
    duration: 0,
    maxWidth: 230,
    spacingHorizontal: 55,
    fitRatio: 0.9,
    autoFit: false,
    color: () => (dark ? '#82d391' : '#38934a'),
    maxInitialScale: 1,
    zoom: false,
    pan: false,
    embedGlobalCSS: true
  });
  await view.setData(input);
  await view.fit();
  // Pointer gestures are deliberate inside the canvas; ordinary wheel scrolling stays with the reader.
  function zoom(factor) {
    const current = svg.__zoom?.k || 1;
    return view.rescale(Math.max(0.001, Math.min(16, current * factor)) / current);
  }
  const pointers = new Map();
  function distance() {
    const p = [...pointers.values()];
    return p.length === 2 ? Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y) : 0;
  }
  svg.addEventListener('pointerdown', (e) => {
    if (e.target.closest('circle')) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    svg.setPointerCapture(e.pointerId);
  });
  svg.addEventListener('pointermove', (e) => {
    const old = pointers.get(e.pointerId);
    if (!old) return;
    const before = distance();
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2 && before) zoom(distance() / before);
    else if (pointers.size === 1)
      view.svg.call(view.zoom.translateBy, (e.clientX - old.x) / (svg.__zoom?.k || 1), (e.clientY - old.y) / (svg.__zoom?.k || 1));
  });
  for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) svg.addEventListener(name, (e) => pointers.delete(e.pointerId));
  svg.addEventListener(
    'wheel',
    (e) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        zoom(e.deltaY < 0 ? 1.15 : 1 / 1.15);
      }
    },
    { passive: false }
  );
  function snapshot(node = view.state.data) {
    return { content: node.content, payload: { fold: node.payload?.fold ? 1 : 0 }, children: (node.children || []).map(snapshot) };
  }
  function accessible() {
    view.svg.selectAll('g.markmap-node').each(function (data) {
      const circle = this.querySelector('circle');
      if (!circle || !data.children?.length) return;
      circle.setAttribute('tabindex', '0');
      circle.setAttribute('role', 'button');
      circle.setAttribute('aria-label', this.textContent || 'Markmap');
      circle.setAttribute('aria-expanded', data.payload?.fold ? 'false' : 'true');
      circle.onkeydown = async (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          await view.toggleNode(data);
          accessible();
          changed();
        }
      };
    });
  }
  svg.addEventListener('click', () => {
    setTimeout(() => {
      accessible();
      changed();
    }, 0);
  });
  accessible();
  return {
    height: Math.max(200, Math.min(300, view.state.rect.y2 - view.state.rect.y1 + 24)),
    async action(action) {
      if (action === 'fit') await view.fit();
      else if (action === 'zoomIn' || action === 'zoomOut') await zoom(action === 'zoomIn' ? 1.25 : 0.8);
      else if (action === 'expand' || action === 'collapse') {
        function fold(node, depth) {
          node.payload = { ...node.payload, fold: action === 'collapse' && depth > 0 ? 1 : 0 };
          (node.children || []).forEach((child) => fold(child, depth + 1));
        }
        fold(view.state.data, 0);
        await view.renderData();
        await view.fit();
        accessible();
      }
      changed();
    },
    snapshot() {
      return { kind: 'markmap', root: snapshot() };
    },
    close() {
      view.destroy();
      pointers.clear();
      container.replaceChildren();
    }
  };
};
