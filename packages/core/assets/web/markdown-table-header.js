/* Bounded structural recovery for oversized GFM table headers.
 * This deliberately does NOT reconstruct header inline semantics. The caller
 * must display both original header lines as complete, labelled source windows.
 * compactHeader is parser scaffolding only; omit its header in rendered rows.
 */
(function (root) {
  'use strict';
  var INPUT = 64 * 1024, COLUMNS = 1024, PREFIX = 256;
  var parser = typeof module === 'object' ? require('./vendor/marked.umd.js') : root.marked;
  function initial() {
    return { version: 1, line: 0, done: false, reason: null, prefix: '',
      headerCells: 1, headerFirstBlank: null, headerBlank: true, slashOdd: false,
      columns: 0, aligns: [], segment: 0, spaces: 0, left: false, right: false,
      dash: false, hadPipe: false, hadColon: false, leadingPipe: false, cr: false };
  }
  function clone(state) { return JSON.parse(JSON.stringify(state)); }
  function HeaderScan(snapshot) {
    if (snapshot && (snapshot.version !== 1 || typeof snapshot.prefix !== 'string' || snapshot.prefix.length > PREFIX ||
      !Array.isArray(snapshot.aligns) || snapshot.aligns.length > COLUMNS ||
      snapshot.aligns.some(function (a) { return a !== null && a !== 'left' && a !== 'right' && a !== 'center'; }) ||
      !Number.isInteger(snapshot.headerCells) || snapshot.headerCells < 1 || snapshot.headerCells > COLUMNS + 3 ||
      ![0, 1].includes(snapshot.line))) throw new Error('snapshot');
    this.state = snapshot ? clone(snapshot) : initial();
  }
  HeaderScan.prototype.snapshot = function () { return clone(this.state); };
  HeaderScan.prototype.fail = function (reason) { this.state.reason = reason; };
  HeaderScan.prototype.headerEnd = function () {
    var s = this.state;
    s.columns = s.headerCells - (s.headerFirstBlank === true || s.headerFirstBlank === null && s.headerBlank ? 1 : 0);
    if (s.columns && s.headerBlank) s.columns--;
    if (!s.columns) this.fail('empty_header');
    else if (s.columns > COLUMNS) this.fail('column_limit');
    // Block-level precedence still belongs to Marked. Avoid promoting obvious
    // headings, lists, fences, HTML and indented code into tables. The caller
    // must also enter this scanner at a genuine top-level block boundary.
    var probe = new parser.Lexer({ gfm: true }).blockTokens(s.prefix + '\n')[0];
    if (!s.reason && (!probe || probe.type !== 'paragraph' || /^ {0,3}</.test(s.prefix))) this.fail('block_precedence');
    s.line = 1; s.slashOdd = false;
  };
  HeaderScan.prototype.pushCell = function () {
    var s = this.state;
    if (!s.dash) return false;
    if (s.aligns.length === COLUMNS) { this.fail('column_limit'); return false; }
    s.aligns.push(s.left ? (s.right ? 'center' : 'left') : (s.right ? 'right' : null));
    return true;
  };
  HeaderScan.prototype.resetCell = function () {
    var s = this.state; s.segment = 0; s.spaces = 0; s.left = false; s.right = false; s.dash = false;
  };
  HeaderScan.prototype.delimiterChar = function (ch) {
    var s = this.state;
    if (ch === '|') {
      s.hadPipe = true;
      if (!s.dash && !s.aligns.length && !s.leadingPipe && s.segment === 0 && s.spaces <= 3) s.leadingPipe = true;
      else if (!this.pushCell()) this.fail(s.reason || 'invalid_delimiter');
      this.resetCell(); return;
    }
    if (ch === ' ') {
      if (s.segment === 1) this.fail('invalid_delimiter');
      else if (s.segment === 2 || s.segment === 3) s.segment = 4;
      s.spaces = Math.min(4, s.spaces + 1); return;
    }
    if (!s.aligns.length && !s.leadingPipe && s.segment === 0 && s.spaces > 3) this.fail('invalid_delimiter');
    if (ch === '-') {
      if (s.segment > 2) this.fail('invalid_delimiter');
      else { s.dash = true; s.segment = 2; }
    } else if (ch === ':') {
      s.hadColon = true;
      if (s.segment === 0) { s.left = true; s.segment = 1; }
      else if (s.segment === 2) { s.right = true; s.segment = 3; }
      else this.fail('invalid_delimiter');
    } else this.fail('invalid_delimiter');
  };
  HeaderScan.prototype.finish = function () {
    var s = this.state;
    if (s.line === 0) this.fail('missing_delimiter');
    else if (!s.reason) {
      if (s.dash) this.pushCell();
      else if (s.segment !== 0 || !s.hadPipe || !s.aligns.length) this.fail('invalid_delimiter');
      if (!s.reason && !s.hadPipe && !s.hadColon) this.fail('not_table_delimiter');
      if (!s.reason && s.columns !== s.aligns.length) this.fail('column_mismatch');
    }
    s.done = true;
  };
  HeaderScan.prototype.result = function (consumed) {
    var s = this.state, valid = s.done && !s.reason;
    return { consumed: consumed, done: s.done, valid: valid, columns: s.columns, reason: s.reason,
      compactHeader: valid ? '|' + ' |'.repeat(s.columns) + '\n|' + s.aligns.map(function (align) {
        return align === 'center' ? ':-:' : align === 'left' ? ':-' : align === 'right' ? '-:' : '-';
      }).join('|') + '|\n' : null };
  };
  HeaderScan.prototype.feed = function (text, final) {
    // Offsets and this limit use UTF-16 code units, matching markdown-blocks.
    // They are NOT UTF-8 transport byte counts. No source is retained here.
    if (typeof text !== 'string' || text.length > INPUT) throw new Error('input');
    var s = this.state, i = 0;
    for (; i < text.length && !s.done; i++) {
      var ch = text[i];
      if (ch === '\n') {
        s.cr = false;
        if (s.line === 0) this.headerEnd(); else this.finish();
        continue;
      }
      if (s.line === 0) {
        if (s.prefix.length < PREFIX) s.prefix += ch;
        if (ch === '|' && !s.slashOdd) {
          if (s.headerFirstBlank === null) s.headerFirstBlank = s.headerBlank;
          s.headerCells = Math.min(COLUMNS + 3, s.headerCells + 1); s.headerBlank = true;
        } else if (!/\s/.test(ch)) s.headerBlank = false;
        s.slashOdd = ch === '\\' ? !s.slashOdd : false;
      } else if (!s.reason) {
        // CRLF may be split across input chunks. A lone CR is not accepted as
        // delimiter whitespace; normal production text is normalized upstream.
        if (s.cr) { this.fail('invalid_delimiter'); s.cr = false; }
        if (ch === '\r') s.cr = true; else this.delimiterChar(ch);
      }
    }
    if (final && !s.done) { if (s.cr) this.fail('invalid_delimiter'); this.finish(); }
    return this.result(i);
  };
  var api = { HeaderScan: HeaderScan, inputLimit: INPUT, columnLimit: COLUMNS };
  if (typeof module === 'object') module.exports = api; else root.LegnaMarkdownTableHeader = api;
})(typeof globalThis === 'object' ? globalThis : this);
