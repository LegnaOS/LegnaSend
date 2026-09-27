/* Local worker: bounded source, bounded token graph, no HTML execution or network input. */
// License is embedded and available at /assets/vendor/marked-LICENSE.txt.
importScripts('/assets/vendor/marked.umd.js');
self.onmessage = function (event) {
  try {
    if (typeof event.data !== 'string' || event.data.length > 256 * 1024) throw new Error('limit');
    var tokens = marked.lexer(event.data, { gfm: true }), count = 0;
    function inspect(value, depth) {
      if (depth > 64 || ++count > 40000) throw new Error('limit');
      if (Array.isArray(value)) value.forEach(function (item) { inspect(item, depth + 1); });
      else if (value && typeof value === 'object') Object.keys(value).forEach(function (key) { inspect(value[key], depth + 1); });
    }
    inspect(tokens, 0); self.postMessage({ tokens: tokens });
  } catch (_) { self.postMessage({ error: 'format' }); }
};
