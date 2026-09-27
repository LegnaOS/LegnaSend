// Minimal deterministic DOM for component contracts; real-browser QA stays separate.
function domFixture() {
  const document = { activeElement: null, documentElement: {} };
  function element(tag) {
    let text = '';
    const node = { tag, style: {}, dataset: {}, attributes: {}, children: [], className: '', value: '', disabled: false, hidden: false, inert: false,
      parentNode: null, clientHeight: 560, scrollTop: 0,
      setAttribute(key, value) { this.attributes[key] = String(value); if (key === 'class') this.className = value; },
      getAttribute(key) { return this.attributes[key] ?? null; },
      appendChild(child) { if (child.parentNode) child.remove(); child.parentNode = this; this.children.push(child); if (this.tag === 'select' && this.children.length === 1) this.value = child.value; return child; },
      remove() { if (this.parentNode) { const list = this.parentNode.children; list.splice(list.indexOf(this), 1); this.parentNode = null; } },
      contains(child) { return this === child || this.children.some(n => n.contains(child)); },
      focus() { document.activeElement = this; }, select() { this.selected = true; },
      closest(selector) { for (let n = this; n; n = n.parentNode) if (matches(n, selector)) return n; return null; },
    };
    node.classList = { toggle(cls, enabled) { const set = new Set(node.className.split(' ').filter(Boolean)); if (enabled) set.add(cls); else set.delete(cls); node.className = [...set].join(' '); } };
    Object.defineProperty(node, 'textContent', { get() { return text + this.children.map(n => n.textContent).join(''); }, set(value) { text = String(value); this.children.forEach(n => n.parentNode = null); this.children = []; } });
    Object.defineProperty(node, 'isConnected', { get() { return document.body.contains(this); } });
    return node;
  }
  function matches(node, selector) {
    if (selector.startsWith('.')) return node.className.split(' ').includes(selector.slice(1));
    if (selector.startsWith('[')) { const key = selector.slice(1, -1); return key.startsWith('data-') ? key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase()) in node.dataset || key in node.attributes : key in node.attributes; }
    return node.tag === selector;
  }
  function descendants(node) { return node.children.flatMap(n => [n, ...descendants(n)]); }
  document.body = element('body'); document.body.style.overflow = '';
  document.createElement = element; document.createElementNS = (_, tag) => element(tag);
  document.getElementById = id => descendants(document.body).find(n => n.id === id) || null;
  document.querySelectorAll = selectors => descendants(document.body).filter(n => selectors.split(',').some(s => matches(n, s)));
  return { document, element, descendants: () => descendants(document.body) };
}
module.exports = { domFixture };
