/* Inspect dimensions before assigning a raster source to a browser decoder. */
(function (root) {
  'use strict';
  var HEADER = 65536, MAX_BYTES = 32 * 1024 * 1024, MAX_PIXELS = 16 * 1024 * 1024, MAX_EDGE = 8192;
  function issue(code, status) { var e = new Error(code); e.code = code; e.status = status; return e; }
  function dimensions(bytes) {
    var a = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes), v = new DataView(a.buffer, a.byteOffset, a.byteLength);
    function text(p, n) { return String.fromCharCode.apply(null, a.subarray(p, p + n)); }
    function result(w, h) {
      if (!Number.isSafeInteger(w) || !Number.isSafeInteger(h) || w <= 0 || h <= 0) throw issue('image-inspect');
      if (w > MAX_EDGE || h > MAX_EDGE || w * h > MAX_PIXELS) throw issue('image-budget');
      return {width: w, height: h};
    }
    if (a.length >= 24 && a[0] === 137 && text(1, 3) === 'PNG' && text(12, 4) === 'IHDR') return result(v.getUint32(16), v.getUint32(20));
    if (a.length >= 10 && (text(0, 6) === 'GIF87a' || text(0, 6) === 'GIF89a')) return result(v.getUint16(6, true), v.getUint16(8, true));
    if (a.length >= 26 && text(0, 2) === 'BM') return v.getUint32(14, true) === 12 ? result(v.getUint16(18, true), v.getUint16(20, true)) : result(Math.abs(v.getInt32(18, true)), Math.abs(v.getInt32(22, true)));
    if (a.length >= 30 && text(0, 4) === 'RIFF' && text(8, 4) === 'WEBP') {
      if (text(12, 4) === 'VP8X') return result(1 + a[24] + a[25] * 256 + a[26] * 65536, 1 + a[27] + a[28] * 256 + a[29] * 65536);
      if (text(12, 4) === 'VP8 ' && a[23] === 157 && a[24] === 1 && a[25] === 42) return result(v.getUint16(26, true) & 16383, v.getUint16(28, true) & 16383);
      if (text(12, 4) === 'VP8L' && a[20] === 47) return result(1 + ((a[22] & 63) << 8 | a[21]), 1 + ((a[24] & 15) << 10 | a[23] << 2 | a[22] >> 6));
    }
    if (a.length >= 4 && a[0] === 255 && a[1] === 216) {
      var p = 2;
      while (p + 4 <= a.length) {
        if (a[p++] !== 255) throw issue('image-inspect');
        while (a[p] === 255) p++;
        var marker = a[p++];
        if (marker === 217 || marker === 218) break;
        if (marker === 1 || marker >= 208 && marker <= 215) continue;
        if (p + 2 > a.length) break;
        var length = v.getUint16(p);
        if (length < 2 || p + length > a.length) break;
        if ([192,193,194,195,197,198,199,201,202,203,205,206,207].indexOf(marker) >= 0 && length >= 7) return result(v.getUint16(p + 5), v.getUint16(p + 3));
        p += length;
      }
    }
    // Unknown containers (including arbitrary AVIF box layouts) do not bypass
    // preflight. The original file remains downloadable without decoding it.
    throw issue('image-inspect');
  }
  async function inspectInner(url, options) {
    options = options || {};
    var request = options.fetch || root.fetch.bind(root), signal = options.signal;
    var init = {credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: signal};
    var head = await request(url, Object.assign({}, init, {method: 'HEAD'}));
    if (!head.ok) throw issue('changed', head.status);
    var size = Number(head.headers.get('Content-Length')), tag = head.headers.get('ETag');
    if (!Number.isSafeInteger(size) || size <= 0 || size > MAX_BYTES) throw issue('image-budget');
    if (options.size != null && size !== options.size) throw issue('changed', 412);
    if (!/^"[a-f0-9]{64}"$/i.test(tag || '')) throw issue('image-inspect');
    var end = Math.min(size, HEADER) - 1;
    var response = await request(url, Object.assign({}, init, {headers: {'Range': 'bytes=0-' + end, 'If-Match': tag}}));
    var expected = 'bytes 0-' + end + '/' + size;
    if (response.status !== 206 || response.headers.get('ETag') !== tag || response.headers.get('Content-Range') !== expected) {
      if (response.body) await response.body.cancel().catch(function () {});
      throw issue(response.status === 412 || response.status === 409 ? 'changed' : 'image-inspect', response.status);
    }
    var reader = response.body.getReader(), chunks = [], count = 0;
    try {
      while (true) {
        var chunk = await reader.read(); if (chunk.done) break;
        count += chunk.value.byteLength;
        if (count > end + 1) throw issue('image-inspect');
        chunks.push(chunk.value);
      }
    } finally { await reader.cancel().catch(function () {}); reader.releaseLock(); }
    if (count !== end + 1) throw issue('image-inspect');
    var bytes = new Uint8Array(count), offset = 0;
    chunks.forEach(function (chunk) { bytes.set(chunk, offset); offset += chunk.byteLength; });
    var result = dimensions(bytes), pinned = new URL(url, root.location ? root.location.href : 'http://localhost/');
    pinned.searchParams.set('version', tag);
    result.url = pinned.pathname + pinned.search; result.tag = tag; result.bytes = count;
    return result;
  }
  async function inspect(url, options) {
    options = options || {};
    var controller = new AbortController(), outer = options.signal;
    function abort() { controller.abort(); }
    if (outer) { if (outer.aborted) abort(); else outer.addEventListener('abort', abort, {once:true}); }
    var timer = setTimeout(abort, 8000);
    try { return await inspectInner(url, Object.assign({}, options, {signal:controller.signal})); }
    finally { clearTimeout(timer); if (outer) outer.removeEventListener('abort', abort); }
  }
  var api = {inspect: inspect, dimensions: dimensions, maxPixels: MAX_PIXELS, maxBytes: MAX_BYTES, headerBytes: HEADER};
  root.LegnaImageSource = api;
  if (typeof module === 'object') module.exports = api;
})(typeof window === 'object' ? window : globalThis);
