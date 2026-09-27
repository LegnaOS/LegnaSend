import DOMPurify from 'dompurify';
export function svgView(svg, container) {
  const safe = DOMPurify.sanitize(svg, {
    USE_PROFILES: { svg: true, svgFilters: true },
    FORBID_TAGS: ['foreignObject', 'a', 'image', 'script', 'iframe', 'use'],
    FORBID_ATTR: ['href', 'xlink:href', 'tabindex']
  });
  container.innerHTML = safe;
  const element = container.querySelector('svg');
  if (!element || container.querySelectorAll('*').length > 6000) throw new Error('limit');
  element.removeAttribute('style');
  element.setAttribute('width', '100%');
  element.setAttribute('height', '100%');
  element.style.maxWidth = 'none';
  const box = element.viewBox.baseVal;
  if (!(box.width > 0 && box.height > 0) || ![box.x, box.y, box.width, box.height].every(Number.isFinite)) throw new Error('format');
  const initial = { x: box.x, y: box.y, width: box.width, height: box.height };
  let scale = 1;
  function fit() {
    scale = 1;
    Object.assign(box, initial);
  }
  function zoom(factor) {
    const next = Math.max(0.25, Math.min(8, scale * factor)),
      ratio = scale / next;
    const width = box.width * ratio,
      height = box.height * ratio;
    box.x += (box.width - width) / 2;
    box.y += (box.height - height) / 2;
    box.width = width;
    box.height = height;
    scale = next;
  }
  const points = new Map();
  function span() {
    const p = [...points.values()];
    return p.length === 2 ? Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y) : 0;
  }
  element.addEventListener('pointerdown', (e) => {
    points.set(e.pointerId, { x: e.clientX, y: e.clientY });
    element.setPointerCapture(e.pointerId);
  });
  element.addEventListener('pointermove', (e) => {
    const old = points.get(e.pointerId);
    if (!old) return;
    const before = span();
    points.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (points.size === 2 && before) zoom(span() / before);
    else if (points.size === 1) {
      box.x -= ((e.clientX - old.x) * box.width) / element.clientWidth;
      box.y -= ((e.clientY - old.y) * box.height) / element.clientHeight;
    }
  });
  for (const event of ['pointerup', 'pointercancel', 'lostpointercapture'])
    element.addEventListener(event, (e) => points.delete(e.pointerId));
  element.addEventListener(
    'wheel',
    (e) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        zoom(e.deltaY < 0 ? 1.15 : 1 / 1.15);
      }
    },
    { passive: false }
  );
  return {
    height: Math.max(170, Math.min(300, (initial.height / initial.width) * container.clientWidth + 12)),
    action(action) {
      if (action === 'fit') fit();
      else if (action === 'zoomIn') zoom(1.25);
      else if (action === 'zoomOut') zoom(0.8);
    },
    snapshot() {
      return { kind: 'mermaid', svg: safe };
    },
    close() {
      points.clear();
      container.replaceChildren();
    }
  };
}
