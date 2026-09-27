/* Incremental SHA-256. Fixed 64-byte state; no whole-file WebCrypto buffer. */
(function (root) {
  'use strict';
  var K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
    0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
    0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
    0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
    0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]);
  function r(v, n) {
    return (v >>> n) | (v << (32 - n));
  }
  function Hash() {
    this.h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    this.b = new Uint8Array(64);
    this.w = new Uint32Array(64);
    this.used = 0;
    this.length = 0;
    this.done = false;
  }
  Hash.prototype.block = function (b) {
    var w = this.w,
      h = this.h;
    for (var i = 0; i < 16; i++) w[i] = (b[i * 4] << 24) | (b[i * 4 + 1] << 16) | (b[i * 4 + 2] << 8) | b[i * 4 + 3];
    for (i = 16; i < 64; i++) {
      var x = w[i - 15],
        y = w[i - 2];
      w[i] = (w[i - 16] + (r(x, 7) ^ r(x, 18) ^ (x >>> 3)) + w[i - 7] + (r(y, 17) ^ r(y, 19) ^ (y >>> 10))) >>> 0;
    }
    var a = h[0],
      c = h[1],
      d = h[2],
      e = h[3],
      f = h[4],
      g = h[5],
      j = h[6],
      k = h[7];
    for (i = 0; i < 64; i++) {
      var t = (k + (r(f, 6) ^ r(f, 11) ^ r(f, 25)) + ((f & g) ^ (~f & j)) + K[i] + w[i]) >>> 0;
      var u = ((r(a, 2) ^ r(a, 13) ^ r(a, 22)) + ((a & c) ^ (a & d) ^ (c & d))) >>> 0;
      k = j;
      j = g;
      g = f;
      f = (e + t) >>> 0;
      e = d;
      d = c;
      c = a;
      a = (t + u) >>> 0;
    }
    [a, c, d, e, f, g, j, k].forEach(function (v, n) {
      h[n] = (h[n] + v) >>> 0;
    });
  };
  Hash.prototype.update = function (bytes) {
    if (this.done) throw new Error('hash finalized');
    if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
    this.length += bytes.length;
    if (!Number.isSafeInteger(this.length)) throw new Error('hash length');
    var offset = 0;
    while (offset < bytes.length) {
      var n = Math.min(64 - this.used, bytes.length - offset);
      this.b.set(bytes.subarray(offset, offset + n), this.used);
      this.used += n;
      offset += n;
      if (this.used === 64) {
        this.block(this.b);
        this.used = 0;
      }
    }
    return this;
  };
  Hash.prototype.digest = function () {
    if (this.done) throw new Error('hash finalized');
    this.done = true;
    this.b[this.used++] = 128;
    if (this.used > 56) {
      this.b.fill(0, this.used);
      this.block(this.b);
      this.used = 0;
    }
    this.b.fill(0, this.used, 56);
    var v = new DataView(this.b.buffer);
    v.setUint32(56, Math.floor(this.length / 0x20000000));
    v.setUint32(60, (this.length * 8) >>> 0);
    this.block(this.b);
    var out = new Uint8Array(32),
      view = new DataView(out.buffer);
    this.h.forEach(function (x, i) {
      view.setUint32(i * 4, x);
    });
    return out;
  };
  function hex(b) {
    return Array.from(b, function (v) {
      return v.toString(16).padStart(2, '0');
    }).join('');
  }
  var api = {
    Hash: Hash,
    hex: hex,
    digest: function (b) {
      return new Hash().update(b).digest();
    }
  };
  if (typeof module === 'object') module.exports = api;
  root.LegnaSha256 = api;
})(typeof globalThis === 'object' ? globalThis : this);
