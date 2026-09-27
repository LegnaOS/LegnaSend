/* Bounded semantic windows for a single physical-line Markdown paragraph.
 * Plain runs are compressed for syntax planning, never used as display text.
 * Original UTF-16 offsets and the visible original slice supply every glyph.
 */
(function (root) {
  'use strict';
  var parser = typeof module === 'object' ? require('./vendor/marked.umd.js') : root.marked;
  var INPUT = 64 * 1024, SKELETON = 128 * 1024, SEGMENTS = 8192, TOKENS = 12000, DEPTH = 24;
  var MARKER = 'LegnaInlineRun';
  function validNumber(value) { return Number.isSafeInteger(value) && value >= 0; }
  function escaped(value) { return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function Planner(start) {
    if (!validNumber(start)) throw new Error('input');
    this.start = start; this.position = start; this.lineEnd = null; this.next = '';
    this.skeleton = ''; this.segments = []; this.run = null; this.prefix = ''; this.done = false; this.unsupported = false;
  }
  Planner.prototype.fail = function () { this.unsupported = true; this.done = true; this.run = null; this.skeleton = ''; this.segments = []; };
  Planner.prototype.append = function (text, from, to, compressed, risk) {
    if (!text) return;
    if (this.skeleton.length + text.length > SKELETON) throw new Error('complexity');
    var at = this.skeleton.length, previous = this.segments[this.segments.length - 1];
    this.skeleton += text;
    if (!compressed && previous && !previous.compressed && previous.b === from) {
      previous.e += text.length; previous.b = to;
    } else {
      if (this.segments.length >= SEGMENTS) throw new Error('complexity');
      this.segments.push({ s: at, e: at + text.length, a: from, b: to, compressed: !!compressed, risk: !!risk });
    }
  };
  Planner.prototype.plain = function (text) {
    if (!text) return;
    var r = this.run;
    if (!r) r = this.run = { start: this.position, limit: /[<(]$/.test(this.skeleton) ? 8192 : 128, length: 0, first: '', last: '', small: '', white: false, allWhite: true, allSpace: true, risk: false, carry: '' };
    r.risk = r.risk || /:\/\/|www\.|@/i.test(r.carry + text);
    r.carry = (r.carry + text).slice(-64);
    r.white = r.white || /[ \t]/.test(text);
    r.allWhite = r.allWhite && /^[ \t]*$/.test(text);
    r.allSpace = r.allSpace && /^ *$/.test(text);
    r.first = (r.first + text).slice(0, 32);
    r.last = (r.last + text).slice(-32);
    r.length += text.length;
    r.small = r.length <= r.limit ? r.small + text : '';
    this.position += text.length;
    if (!validNumber(this.position)) throw new Error('complexity');
  };
  Planner.prototype.flush = function () {
    var r = this.run; if (!r) return;
    this.run = null;
    if (r.length <= r.limit) { this.append(r.small, r.start, r.start + r.length, false); return; }
    // Autolinks can start inside text, unlike paired inline delimiters. Do not
    // hide a possible URL/email inside a compressed run and mislabel it plain.
    // The risk flag may be accepted only after Marked proves a code-span range.
    var risk = r.risk || this.skeleton.endsWith('&') && /^#/.test(r.first);
    var prefix = 16, suffix = 16;
    if (/[\ud800-\udbff]/.test(r.first[prefix - 1])) prefix++;
    if (/[\udc00-\udfff]/.test(r.last[r.last.length - suffix])) suffix++;
    var marker = r.allSpace ? '   ' : r.allWhite ? '\t\t\t' : r.white ? 'Legna Inline Run' : MARKER;
    this.append(r.first.slice(0, prefix), r.start, r.start + prefix, false);
    this.append(marker, r.start + prefix, r.start + r.length - suffix, true, risk);
    this.append(r.last.slice(-suffix), r.start + r.length - suffix, r.start + r.length, false);
  };
  Planner.prototype.firstLine = function (text) {
    this.prefix = (this.prefix + text).slice(0, 256);
    var expression = /[\\`*_~\[\]()!<>&|]/g, match, at = 0;
    while ((match = expression.exec(text))) {
      this.plain(text.slice(at, match.index)); this.flush();
      this.append(match[0], this.position, this.position + 1, false);
      this.position++; at = match.index + 1;
    }
    this.plain(text.slice(at));
  };
  Planner.prototype.finish = function () {
    this.flush();
    if (this.lineEnd === null) this.lineEnd = this.position;
    // Marked still owns block precedence. A real table/setext heading, or a
    // paragraph continuing onto a second physical line, is not this feature.
    var originalPrefix = new parser.Lexer({ gfm: true }).blockTokens(this.prefix + '\n')[0];
    if (!originalPrefix || originalPrefix.type !== 'paragraph') { this.fail(); return; }
    var source = this.skeleton + (this.next ? '\n' + this.next + '\n' : '');
    var first = new parser.Lexer({ gfm: true }).blockTokens(source)[0];
    if (!first || first.type !== 'paragraph' || this.next && first.raw.length > this.skeleton.length + 1) {
      this.fail(); return;
    }
    this.done = true;
  };
  Planner.prototype.feed = function (text, final) {
    if (typeof text !== 'string' || text.length > INPUT) throw new Error('input');
    if (this.done) return this.result();
    try {
      if (this.lineEnd === null) {
        var end = text.indexOf('\n');
        this.firstLine(end < 0 ? text : text.slice(0, end));
        if (end >= 0) { this.flush(); this.lineEnd = this.position; text = text.slice(end + 1); }
        else text = '';
      }
      if (this.lineEnd !== null) {
        var newline = text.indexOf('\n'), part = newline < 0 ? text : text.slice(0, newline);
        if (this.next.length + part.length > INPUT) throw new Error('complexity');
        this.next += part;
        if (newline >= 0) this.finish();
      }
      if (final && !this.done) this.finish();
    } catch (error) {
      if (!['complexity', 'boundary'].includes(error.message)) throw error;
      this.fail();
    }
    return this.result();
  };
  Planner.prototype.lexer = function (links) {
    var lexer = new parser.Lexer({ gfm: true });
    Object.setPrototypeOf(lexer.tokens.links, links && Object.getPrototypeOf(links) === null ? links : Object.assign(Object.create(null), links || {}));
    return lexer;
  };
  Planner.prototype.result = function () {
    var names = new Set(), self = this;
    if (this.done && !this.unsupported) {
      try {
        this.lexer(new Proxy(Object.create(null), { get: function (_, name) { if (typeof name === 'string') names.add(name); return undefined; } })).inlineTokens(this.skeleton);
        if (names.size > 256 || Array.from(names).some(function (name) { return name.length > 4096 || /legna\s*inline\s*run/i.test(name); })) self.fail();
      } catch (_) { self.fail(); }
    }
    return { done: this.done, unsupported: this.unsupported, names: this.unsupported ? [] : Array.from(names) };
  };
  Planner.prototype.offset = function (position) {
    if (position === this.skeleton.length) return this.lineEnd;
    var low = 0, high = this.segments.length;
    while (low < high) { var mid = (low + high) >>> 1; if (this.segments[mid].e <= position) low = mid + 1; else high = mid; }
    var segment = this.segments[low];
    if (!segment || position < segment.s) throw new Error('boundary');
    if (segment.compressed && position !== segment.s) throw new Error('complexity');
    return segment.a + (position - segment.s);
  };
  Planner.prototype.entityBoundary = function (position) {
    if (position <= this.start || position >= this.lineEnd) return false;
    var segment = this.segments.find(function (s) { return s.a <= position && s.b > position; });
    if (!segment || segment.compressed) return false;
    var at = segment.s + position - segment.a, amp = this.skeleton.lastIndexOf('&', at - 1);
    if (amp < 0) return false;
    var end = this.skeleton.indexOf(';', amp + 1);
    // Search the bounded skeleton, not an assumed fixed entity width. Numeric
    // spellings can be long; no viewport receives half a decoded entity.
    return end >= at && /^(?:#[xX]?[0-9a-fA-F]+|[a-zA-Z]+)$/.test(this.skeleton.slice(amp + 1, end));
  };
  Planner.prototype.intersects = function (from, to, property) {
    var low = 0, high = this.segments.length;
    while (low < high) { var mid = (low + high) >>> 1; if (this.segments[mid].e <= from) low = mid + 1; else high = mid; }
    for (var i = low; i < this.segments.length && this.segments[i].s < to; i++) if (this.segments[i][property]) return true;
    return false;
  };
  Planner.prototype.render = function (from, to, text, links) {
    if (!this.done || !validNumber(from) || !validNumber(to) || to < from || typeof text !== 'string' || text.length !== to - from || text.length > 20 * 1024) throw new Error('input');
    if (this.unsupported || from < this.start || from > this.lineEnd || this.entityBoundary(from) || this.entityBoundary(to)) return { semantic: false };
    var self = this, count = 0, sourceEnd = this.lineEnd;
    function slice(a, b) { return text.slice(Math.max(from, a) - from, Math.max(Math.max(from, a), Math.min(to, b)) - from); }
    function leaf(type, start, end, extra) {
      // Code spans do not interpret links/entities. Elsewhere a run hiding a
      // potential autolink or giant numeric entity remains an explicit fallback.
      if (type !== 'codespan' && self.intersects(start, end, 'risk')) throw new Error('complexity');
      var a = self.offset(start), b = self.offset(end), value = slice(a, b);
      return value ? [Object.assign({ type: type, text: type === 'codespan' ? escaped(value) : value }, extra || {})] : [];
    }
    function walk(tokens, position, depth) {
      if (depth > DEPTH) throw new Error('complexity');
      var result = [];
      tokens.forEach(function (token) {
        if (++count > TOKENS || typeof token.raw !== 'string' || self.skeleton.slice(position, position + token.raw.length) !== token.raw) throw new Error('boundary');
        var begin = position, end = position + token.raw.length, children = token.tokens || [], body = children.map(function (t) { return t.raw; }).join('');
        position = end;
        // Validate even offscreen syntax, so unsupported hidden structures do
        // not silently alter the meaning of the visible part of the paragraph.
        switch (token.type) {
          case 'text':
            if (token.tokens) throw new Error('complexity');
            result.push.apply(result, leaf('text', begin, end)); break;
          case 'escape':
            if (token.raw.length !== 2 || token.raw[0] !== '\\') throw new Error('boundary');
            result.push.apply(result, leaf('literal', begin + 1, end)); break;
          case 'strong': case 'em': case 'del': {
            var width = token.type === 'strong' ? 2 : token.type === 'em' ? 1 : token.raw.startsWith('~~') ? 2 : 1;
            if (token.raw.slice(width, -width) !== body) throw new Error('boundary');
            var nested = walk(children, begin + width, depth + 1);
            if (nested.length) result.push({ type: token.type, tokens: nested });
            break;
          }
          case 'codespan': {
            var opening = /^`+/.exec(token.raw); if (!opening) throw new Error('boundary');
            var codeStart = begin + opening[0].length, codeEnd = end - opening[0].length;
            var middle = self.skeleton.slice(codeStart, codeEnd);
            if (middle.startsWith(' ') && middle.endsWith(' ') && /[^ ]/.test(middle)) { codeStart++; codeEnd--; }
            result.push.apply(result, leaf('codespan', codeStart, codeEnd)); break;
          }
          case 'link': {
            if (token.raw[0] !== '[' || token.raw.slice(1, 1 + body.length) !== body || token.raw[1 + body.length] !== ']') throw new Error('complexity');
            var labelEnd = begin + 1 + body.length;
            if (self.intersects(labelEnd, end, 'compressed') || typeof token.href !== 'string' || token.href.length > 8192 || token.title && token.title.length > 4096) throw new Error('complexity');
            var label = walk(children, begin + 1, depth + 1);
            if (label.length) result.push({ type: 'link', href: token.href, title: token.title, tokens: label });
            break;
          }
          default: throw new Error('complexity');
        }
      });
      return result;
    }
    try {
      var values = this.lexer(links || Object.create(null)).inlineTokens(this.skeleton);
      var rendered = walk(values, 0, 0);
      return { semantic: true, tokens: [{ type: 'paragraph', tokens: rendered }], start: this.start, end: sourceEnd };
    } catch (error) {
      if (!['complexity', 'boundary'].includes(error.message)) throw error;
      return { semantic: false };
    }
  };
  var api = { Planner: Planner, inputLimit: INPUT, skeletonLimit: SKELETON };
  if (typeof module === 'object') module.exports = api; else root.LegnaMarkdownInlineWindow = api;
})(typeof globalThis === 'object' ? globalThis : this);
