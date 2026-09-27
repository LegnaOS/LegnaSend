/* Marked tokens become allowlisted DOM nodes, never HTML strings. No remote images. */
(function (root) {
  'use strict';
  var MAX = 256 * 1024;
  function entities(text) {
    return String(text || '').replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, function (all, name) {
      if (name[0] !== '#') return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0' }[name.toLowerCase()];
      var code = name[1].toLowerCase() === 'x' ? parseInt(name.slice(2), 16) : Number(name.slice(1));
      return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : '\ufffd';
    });
  }
  function safeUrl(value) {
    value = entities(value).trim();
    if (/[\u0000-\u0020\u007f]/.test(value) || !/^(https?:\/\/|mailto:)/i.test(value)) return null;
    try { var url = new URL(value); return ['https:', 'http:', 'mailto:'].indexOf(url.protocol) >= 0 ? url.href : null; } catch (_) { return null; }
  }
  function render(tokens, doc, diagrams, budget) {
    var count = 0, article = doc.createElement('article'); article.className = 'markdown-document';
    function el(tag, text) { if (++count > (budget || 6000)) throw new Error('limit'); var node = doc.createElement(tag); if (text != null) node.textContent = text; return node; }
    function children(parent, list, depth) {
      if (depth > 32) throw new Error('depth');
      (list || []).forEach(function (token) {
        var node, url;
        switch (token.type) {
          case 'space': case 'def': return;
          case 'heading': node = el('h' + Math.max(1, Math.min(6, token.depth))); children(node, token.tokens, depth + 1); break;
          case 'paragraph': node = el('p'); children(node, token.tokens, depth + 1); break;
          case 'strong': case 'em': case 'del': node = el(token.type); children(node, token.tokens, depth + 1); break;
          case 'blockquote': node = el('blockquote'); children(node, token.tokens, depth + 1); break;
          case 'literal': node = el('span', token.text); break;
          case 'text': case 'escape': node = el('span'); if (token.tokens) children(node, token.tokens, depth + 1); else node.textContent = entities(token.text); break;
          case 'codespan': node = el('code', entities(token.text)); break;
          case 'code':
            if (!token.fragment && diagrams && root.LegnaDiagrams.kind(token.lang) && diagrams.blocks.length < root.LegnaDiagrams.limits.blocks) node = diagrams.block(token.lang, token.text);
            else { node = el('pre'); node.appendChild(el('code', token.text)); }
            break;
          case 'checkbox': node = el('input'); node.type = 'checkbox'; node.disabled = true; node.checked = !!token.checked; break;
          case 'br': node = el('br'); break;
          case 'hr': node = el('hr'); break;
          case 'link':
            url = safeUrl(token.href); node = el(url ? 'a' : 'span');
            if (url) { node.href = url; node.target = '_blank'; node.rel = 'noopener noreferrer'; node.referrerPolicy = 'no-referrer'; }
            children(node, token.tokens, depth + 1); break;
          case 'image': node = el('span', '[' + entities(token.text || 'Image') + ']'); node.className = 'markdown-image-label'; break;
          case 'list':
            node = el(token.ordered ? 'ol' : 'ul'); if (token.ordered && Number.isSafeInteger(Number(token.start))) node.start = Number(token.start);
            token.items.forEach(function (item) { var li = el('li'); if (item.continuation) { li.className = 'markdown-list-continuation'; li.setAttribute('data-continuation', 'true'); } children(li, item.tokens, depth + 1); node.appendChild(li); }); break;
          case 'table':
            node = el('div'); node.className = 'markdown-table'; var table = el('table'), head = el('thead'), body = el('tbody');
            function tableRow(cells, tag) { var tr = el('tr'); cells.forEach(function (cell, i) { var td = el(tag); if (['left', 'right', 'center'].indexOf(token.align[i]) >= 0) td.style.textAlign = token.align[i]; children(td, cell.tokens, depth + 1); tr.appendChild(td); }); return tr; }
            if (token.header.length) head.appendChild(tableRow(token.header, 'th')); token.rows.forEach(function (row) { body.appendChild(tableRow(row, 'td')); });
            if (token.header.length) table.appendChild(head); table.appendChild(body); node.appendChild(table); break;
          // Raw HTML/SVG and unknown extensions are displayed literally, never inserted as markup.
          default: node = el('span', token.raw || token.text || '');
        }
        parent.appendChild(node);
      });
    }
    children(article, tokens, 0); return article;
  }
  function mount(options) {
    if (options.reader.size > MAX && root.Worker && root.LegnaMarkdownStream) return root.LegnaMarkdownStream.mount(options);
    var closed = false, worker = null, timer = null, rejectWork;
    var reader = options.reader;
    var diagrams = root.LegnaDiagrams ? new root.LegnaDiagrams.Manager({container:options.container, labels:options.labels}) : null;
    function close() { closed = true; if (diagrams) diagrams.close(); if (worker) worker.terminate(); clearTimeout(timer); if (rejectWork) rejectWork(new Error('closed')); }
    var ready = (async function () {
      if (reader.size > MAX || !root.Worker) throw new Error('limit');
      await reader.ensureRows(Number.MAX_SAFE_INTEGER);
      var source = '', previousLine = null;
      for (var start = 0; start < reader.rows; start += 128) {
        if (closed) throw new Error('closed');
        var rows = await reader.getRows(start, 128);
        rows.forEach(function (row) { if (previousLine != null && row.number !== previousLine) source += '\n'; source += row.text; previousLine = row.number; });
        if (source.length > MAX) throw new Error('limit');
        await new Promise(function (resolve) { setTimeout(resolve, 0); });
      }
      if (closed) throw new Error('closed');
      var tokens = await new Promise(function (resolve, reject) {
        rejectWork = reject; worker = new root.Worker('/assets/markdown-worker.js');
        timer = setTimeout(function () { worker.terminate(); reject(new Error('timeout')); }, 2500);
        worker.onmessage = function (event) { if (event.data.error) reject(new Error('format')); else resolve(event.data.tokens); };
        worker.onerror = function () { reject(new Error('worker')); }; worker.postMessage(source);
      });
      if (closed) throw new Error('closed');
      var document = render(tokens, root.document, diagrams); options.container.textContent = ''; options.container.appendChild(document);
    })().finally(function () { if (worker) worker.terminate(); clearTimeout(timer); rejectWork = null; });
    return { ready: ready, close: close, setActive: function(active) { if(diagrams)diagrams.setActive(active); } };
  }
  var api = { mount: mount, render: render, safeUrl: safeUrl, entities: entities, limit: MAX };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.LegnaMarkdown = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
