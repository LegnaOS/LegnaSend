/* Complete-block indexing; Marked owns syntax, this layer owns incremental boundaries. */
(function (root) {
  'use strict';
  var MAX = 256 * 1024,
    REF_BYTES = 1024 * 1024;
  var parser = typeof module === 'object' ? require('./vendor/marked.umd.js') : root.marked;
  var HeaderScan = (typeof module === 'object' ? require('./markdown-table-header.js') : root.LegnaMarkdownTableHeader).HeaderScan;
  function inspect(value, depth, budget) {
    if (depth > 64 || ++budget.count > 40000) throw new Error('complexity');
    if (Array.isArray(value))
      value.forEach(function (v) {
        inspect(v, depth + 1, budget);
      });
    else if (value && typeof value === 'object')
      Object.keys(value).forEach(function (key) {
        inspect(value[key], depth + 1, budget);
      });
  }
  // A single huge code fence is still one semantic block, but its source/DOM
  // windows are independently replayable. Keep at most one bounded lookahead.
  var WINDOW = 16 * 1024, LARGE = 64 * 1024;
  function fenceStart(source) {
    var m = /^( {0,3})(`{3,}|~{3,})([^\n]*)\n/.exec(source);
    if (!m || m[0].length > 4096 || (m[2][0] === '`' && m[3].includes('`'))) return null;
    return { kind: 'fence', marker: m[2][0], length: m[2].length, indent: m[1].length,
      lang: m[3].trim().split(/\s+/)[0], opening: m[0].length, lineStart: true };
  }
  function largeStart(source) {
    var fence = fenceStart(source);
    if (fence) return fence;
    var first = source.indexOf('\n'), second = source.indexOf('\n', first + 1);
    if (/^ {0,3}(?:>|[-+*]\s|\d{1,9}[.)]\s)/.test(source)) {
      var container = new parser.Lexer({ gfm: true }).blockTokens(source)[0];
      if (container && (container.type === 'list' || container.type === 'blockquote'))
        return { kind: container.type, nextStart: container.start || 1 };
    }
    if (first >= 0 && second >= 0 && second <= 4096) {
      var header = source.slice(0, second + 1);
      var table = new parser.Lexer({ gfm: true }).blockTokens(header)[0];
      if (table && table.type === 'table') return { kind: 'table', header: header, opening: header.length };
    }
    // Large two-line headers retain their real source separately. A compact
    // structural scaffold is used only to parse later rows, never as a label.
    if (first < 0 || first > LARGE || ((first > 4096 || second > 4096 || second < 0 && source.length - first > 4096) && source.slice(0, first).includes('|'))) {
      var start = new parser.Lexer({ gfm: true }).blockTokens(source.slice(0, first < 0 ? 256 : Math.min(256, first)) + '\n')[0];
      if (start && start.type === 'paragraph') return { kind: 'table-header-source', first: true };
    }
    var token = new parser.Lexer({ gfm: true }).blockTokens(source)[0];
    return token && token.type === 'paragraph' && token.raw.length > LARGE
      ? { kind: 'paragraph', first: true, lineStart: true } : null;
  }
  function safeCut(text, limit, final) {
    var end = Math.min(limit, text.length);
    if (end && (end < text.length || !final) && /[\ud800-\udbff]/.test(text[end - 1])) end--;
    return end;
  }
  function Stream(start, context, options) {
    this.options = options || {};
    this.pending = '';
    this.large = context ? Object.assign({}, context) : null;
    this.offset = start || 0;
    this.links = Object.create(null);
    this.version = 0;
    this.refBytes = 0;
    this.refCount = 0;
  }
  Stream.prototype.definitions = function (tokens) {
    var self = this;
    function visit(token) {
      var tag = token.originalTag || token.tag;
      if (token.type === 'def' && self.options.externalReferences) { self.version++; return; }
      if (token.type === 'def' && self.options.referenceFilter && !self.options.referenceFilter.has(tag)) return;
      if (token.type === 'def' && !Object.prototype.hasOwnProperty.call(self.links, tag)) {
        var value = { href: token.href, title: token.title },
          cost = (tag.length + JSON.stringify(value).length) * 2;
        if (self.refCount >= 4096 || self.refBytes + cost > REF_BYTES) throw new Error('references');
        self.links[tag] = value;
        self.refBytes += cost;
        self.refCount++;
        self.version++;
      }
      if (token.tokens) token.tokens.forEach(visit);
      if (token.items) token.items.forEach(visit);
    }
    tokens.forEach(visit);
  };
  Stream.prototype.windowFence = function (final) {
    var mode = this.large, text = this.pending, opening = mode.opening || 0;
    var body = text.slice(opening), closeAt = -1, closeEnd = -1;
    var pattern = new RegExp('^ {0,3}' + (mode.marker === '`' ? '`' : '~') + '{' + mode.length + ',}[ \t]*(?:\\n|$)', 'gm');
    var match;
    while ((match = pattern.exec(body))) {
      // A segmented long physical line cannot turn its middle into a fence.
      if ((match.index > 0 || mode.lineStart) && (match[0].endsWith('\n') || final)) {
        closeAt = opening + match.index; closeEnd = closeAt + match[0].length; break;
      }
      if (!match[0].length) pattern.lastIndex++;
    }
    var boundary = closeAt >= 0 ? closeAt : text.length;
    var end = safeCut(text, Math.min(WINDOW + opening, boundary), final);
    if (end < boundary) {
      var newline = text.lastIndexOf('\n', end - 1);
      if (newline >= opening) end = newline + 1;
    }
    // Bound physical height too: thousands of blank lines must not create a
    // section taller than the browser's maximum scroll range.
    var lineEnd = opening;
    for (var lines = 0; lines < 256; lines++) {
      var nextLine = text.indexOf('\n', lineEnd);
      if (nextLine < 0 || nextLine + 1 > end) break;
      lineEnd = nextLine + 1;
    }
    if (lines === 256 && lineEnd < end) end = lineEnd;
    var closed = closeAt >= 0 && end === closeAt;
    var consume = closed ? closeEnd : end;
    if (!closed && !final && text.length < WINDOW + opening) return null;
    if (!consume) {
      if (final) this.large = null;
      return null;
    }
    var context = Object.assign({}, mode);
    var block = { start: this.offset, end: this.offset + consume, type: 'code',
      replay: context, fragment: { kind: 'fence', lang: mode.lang, indent: mode.indent,
        lineStart: mode.lineStart, from: opening, to: end } };
    mode.opening = 0;
    mode.lineStart = text[end - 1] === '\n';
    this.pending = text.slice(consume); this.offset += consume;
    if (closed || final && !this.pending.length) this.large = null;
    return block;
  };
  Stream.prototype.windowTableHeader = function (final) {
    var mode = this.large, text = this.pending;
    if (mode.first && mode.inlineStart == null) mode.inlineStart = this.offset;
    if (!text.length) { if (final) this.large = null; return null; }
    if (!final && text.length < WINDOW && text.indexOf('\n') < 0) return null;
    // A long pipe-bearing paragraph is only a provisional header. Do not eat
    // an unrelated following heading/list as the second header source line.
    if (mode.scan && mode.scan.line === 1 && !mode.delimiterStarted) {
      var firstNonSpace = text.search(/[^ ]/);
      if (firstNonSpace < 0 && text.length <= 3 && !final) return null;
      var probeEnd = text.indexOf('\n');
      var delimiterProbe = text.slice(0, Math.min(WINDOW, probeEnd < 0 ? text.length : probeEnd));
      if (firstNonSpace < 0 || firstNonSpace > 3 || !'|:-'.includes(text[firstNonSpace]) || /[^ |:\-\r]/.test(delimiterProbe)) {
        this.large = { kind: 'paragraph', first: false, lineStart: true };
        return this.windowParagraph(final);
      }
      mode.delimiterStarted = true;
    }
    var end = safeCut(text, WINDOW, final), context = Object.assign({}, mode);
    // Commit the first physical line separately so second-line precedence can
    // be checked before consuming any of it, including across read boundaries.
    if (!mode.scan || mode.scan.line === 0) {
      var newline = text.indexOf('\n');
      if (newline >= 0) end = Math.min(end, newline + 1);
    }
    var scanner = new HeaderScan(mode.scan), result = scanner.feed(text.slice(0, end), final && end === text.length);
    end = result.consumed;
    if (!end) { this.large = null; return null; }
    var block = { start: this.offset, end: this.offset + end, type: 'table', replay: context,
      fragment: { kind: 'table-header-source', literal: true, first: mode.first,
        inlineStart: !mode.scan || mode.scan.line === 0 ? mode.inlineStart : undefined } };
    mode.first = false; mode.scan = scanner.snapshot();
    this.pending = text.slice(end); this.offset += end;
    if (result.done) this.large = result.valid
      ? { kind: 'table', header: result.compactHeader, opening: 0, omitHeader: true }
      : { kind: 'paragraph', first: false, lineStart: text[end - 1] === '\n' };
    return block;
  };
  Stream.prototype.windowTable = function (final) {
    var mode = this.large, text = this.pending, opening = mode.opening || 0;
    var firstRowEnd = text.indexOf('\n', opening);
    if (!mode.rowLiteral && firstRowEnd < 0 && !final && text.length - opening <= LARGE) return null;
    if (mode.rowLiteral || (firstRowEnd < 0 ? text.length - opening > LARGE : firstRowEnd + 1 - opening > LARGE)) {
      // A bounded prefix decides whether this line belongs to the table. Never
      // consume a following heading/fence as a table row just because it is long.
      var probeRow = new parser.Lexer({ gfm: true }).blockTokens(mode.header + text.slice(opening, opening + WINDOW) + '\n')[0];
      if (mode.rowLiteral || probeRow && probeRow.type === 'table' && probeRow.raw.length > mode.header.length) {
        if (!mode.rowLiteral) { mode.rowLiteral = true; mode.rowFirst = true; }
        return this.windowTableRow(final);
      }
    }
    var rowBoundary = firstRowEnd < 0 ? (final ? text.length : 0) : firstRowEnd + 1;
    if (rowBoundary - opening > WINDOW && rowBoundary - opening <= LARGE) {
      var completeRow = new parser.Lexer({ gfm: true }).blockTokens(mode.header + text.slice(opening, rowBoundary))[0];
      if (completeRow && completeRow.type === 'table' && completeRow.rows.length === 1) {
        var rowBlock = { start: this.offset, end: this.offset + rowBoundary, type: 'table', replay: Object.assign({}, mode),
          fragment: { kind: 'table', header: mode.header, omitHeader: mode.omitHeader, from: opening, to: rowBoundary } };
        mode.opening = 0; this.pending = text.slice(rowBoundary); this.offset += rowBoundary;
        if (final && !this.pending.length) this.large = null;
        return rowBlock;
      }
    }
    var prefixEnd = final ? text.length : text.lastIndexOf('\n') + 1;
    if (prefixEnd < opening || !prefixEnd) {
      if (text.length > MAX) throw new Error('block');
      return null;
    }
    var probe = opening;
    for (var rows = 0; rows < 32; rows++) {
      var line = text.indexOf('\n', probe);
      if (line < 0) break;
      probe = line + 1;
    }
    if (probe > opening) prefixEnd = Math.min(prefixEnd, probe);
    var prefix = mode.header + text.slice(opening, prefixEnd);
    var token = new parser.Lexer({ gfm: true }).blockTokens(prefix)[0];
    if (!token || token.type !== 'table') throw new Error('boundary');
    var boundary = Math.max(opening, opening + token.raw.length - mode.header.length);
    if (boundary === opening) {
      this.large = null;
      if (!opening) return null;
      var empty = { start: this.offset, end: this.offset + opening, type: 'table', replay: Object.assign({}, mode),
        fragment: { kind: 'table', header: mode.header, omitHeader: mode.omitHeader, from: opening, to: opening } };
      this.pending = text.slice(opening); this.offset += opening;
      return empty;
    }
    var terminated = boundary < prefixEnd || final && prefixEnd === text.length;
    var end = Math.min(boundary, WINDOW + opening);
    var rowEnd = opening;
    for (var row = 0; row < 16; row++) {
      var newline = text.indexOf('\n', rowEnd);
      if (newline < 0 || newline + 1 > end) break;
      rowEnd = newline + 1;
    }
    if (rowEnd > opening) end = rowEnd;
    if (end < boundary) end = text.lastIndexOf('\n', end - 1) + 1;
    if (end <= opening || !final && !terminated && text.length < WINDOW) {
      if (text.length > MAX) throw new Error('block');
      return null;
    }
    var context = Object.assign({}, mode);
    var block = { start: this.offset, end: this.offset + end, type: 'table', replay: context,
      fragment: { kind: 'table', header: mode.header, omitHeader: mode.omitHeader, from: opening, to: end } };
    mode.opening = 0;
    this.pending = text.slice(end); this.offset += end;
    if (terminated && end === boundary) this.large = null;
    return block;
  };
  Stream.prototype.windowTableRow = function (final) {
    var mode = this.large, text = this.pending, opening = mode.opening || 0;
    if (!text.length) { if (final) this.large = null; return null; }
    var newline = text.indexOf('\n', opening), boundary = newline < 0 ? text.length : newline + 1;
    if (newline < 0 && !final && text.length - opening < WINDOW) return null;
    var end = safeCut(text, Math.min(opening + WINDOW, boundary), final);
    var block = { start: this.offset, end: this.offset + end, type: 'table',
      replay: Object.assign({}, mode), fragment: { kind: 'table-row-source', literal: true,
        first: mode.rowFirst, header: opening && !mode.omitHeader ? mode.header : null, from: opening } };
    mode.opening = 0; mode.rowFirst = false;
    this.pending = text.slice(end); this.offset += end;
    if (end === boundary && newline >= 0) mode.rowLiteral = false;
    if (final && !this.pending.length) this.large = null;
    return block;
  };
  // A single loose item can contain thousands of ordinary complete blocks.
  // Map Marked's deindented child boundaries back to exact source lines rather
  // than treating the entire item as one unrenderable inline expression.
  function listItemMapping(item, marker) {
    if (item.task || /\t/.test(marker)) return null;
    var raw=item.raw, normalized='', mapping=new Map(), position=0, first=true;
    while(position<raw.length){
      var end=raw.indexOf('\n',position);end=end<0?raw.length:end+1;
      var line=raw.slice(position,end);
      if(first){if(!line.startsWith(marker))return null;line=line.slice(marker.length);first=false;}
      else line=line.replace(new RegExp('^ {0,'+marker.length+'}'),'');
      normalized+=line;mapping.set(normalized.length,end);
      if(line.endsWith('\n'))mapping.set(normalized.length-1,end);
      position=end;
    }
    var trim=function(value){return value.replace(/\n+$/,'');};
    if(trim(normalized)!==trim(item.text)||trim(item.tokens.map(function(token){return token.raw;}).join(''))!==trim(item.text))return null;
    return mapping;
  }
  Stream.prototype.windowListChildren = function(final){
    var mode=this.large,text=this.pending;
    if((!mode.itemFirst&&!mode.itemSemantic)||!mode.itemLineStart)return null;
    var prefix=mode.itemFirst?'':mode.itemPrefix+'LegnaContinuation\n\n';
    var all=new parser.Lexer({gfm:true}).blockTokens(prefix+text),list=all[0];
    if(!list||list.type!=='list'||!list.items.length)return null;
    var item=list.items[0],mapping=listItemMapping(item,mode.itemPrefix);
    if(!mapping||!item.loose)return null;
    var ended=list.items.length>1||all.slice(1).some(function(token){return token.type!=='space';})||final;
    var children=item.tokens,available=children.length,childEnd=0,end=0,count=0;
    if(!ended){while(available&&children[available-1].type==='space')available--;if(available)available--;}
    for(var i=0;i<available&&count<32;i++){
      childEnd+=children[i].raw.length;
      var candidate=mapping.get(childEnd);
      if(candidate==null)continue;
      candidate-=prefix.length;
      if(candidate<=0)continue;
      if(text.slice(0,candidate).split('\n').length>257)break;
      if(candidate>WINDOW){if(!end&&candidate<=LARGE)end=candidate;break;}
      end=candidate;count++;
    }
    if(!ended&&count<32&&text.length<LARGE)return 'wait';
    if(!end)return !ended&&text.length<LARGE?'wait':null;
    var boundary=(list.items.length===1?list.raw.length:item.raw.length)-prefix.length;
    if(final&&list.items.length===1&&all.slice(1).every(function(token){return token.type==='space';}))boundary=text.length;
    if(ended&&i>=children.length&&boundary<=LARGE)end=boundary;
    var context=Object.assign({},mode);
    var block={start:this.offset,end:this.offset+end,type:'list',replay:context,
      fragment:{kind:'list-item-children',first:mode.itemFirst,marker:mode.itemPrefix,start:mode.nextStart}};
    this.definitions(new parser.Lexer({gfm:true}).blockTokens(prefix+text.slice(0,end)));
    mode.itemFirst=false;mode.itemSemantic=true;mode.itemLineStart=text[end-1]==='\n';
    this.pending=text.slice(end);this.offset+=end;
    if(ended&&end===boundary){mode.itemLiteral=false;mode.itemSemantic=false;mode.nextStart++;}
    if(final&&!this.pending.length)this.large=null;
    return block;
  };
  Stream.prototype.windowListItem = function (final) {
    var mode = this.large, text = this.pending;
    if (!text.length) { if (final) this.large = null; return null; }
    var semantic=this.windowListChildren(final);
    if(semantic==='wait')return null;
    if(semantic)return semantic;
    mode.itemSemantic=false;
    // Only boundary detection sees the synthetic marker. The displayed source
    // and its offsets never contain the marker or lose the original indentation.
    var prefix = mode.itemFirst ? '' : mode.itemPrefix + 'LegnaContinuation' + (mode.itemLineStart ? '\n' : ' ');
    var all = new parser.Lexer({ gfm: true }).blockTokens(prefix + text), token = all[0];
    var boundary = token && token.type === 'list'
      ? Math.max(0, (token.items.length > 1 ? token.items[0].raw.length : token.raw.length) - prefix.length) : 0;
    if (!boundary) {
      mode.itemLiteral = false; mode.nextStart++;
      return this.windowContainer(final);
    }
    var terminated = token.items.length > 1 || all.slice(1).some(function (item) { return item.type !== 'space'; }) || final;
    if (!terminated && text.length < WINDOW) return null;
    var end = safeCut(text, Math.min(WINDOW, boundary), final);
    if (end < boundary) {
      var newline = text.lastIndexOf('\n', end - 1);
      if (newline >= 0) end = newline + 1;
    }
    var lineEnd = 0;
    for (var lines = 0; lines < 256; lines++) {
      var next = text.indexOf('\n', lineEnd);
      if (next < 0 || next + 1 > end) break;
      lineEnd = next + 1;
    }
    if (lines === 256 && lineEnd < end) end = lineEnd;
    var block = { start: this.offset, end: this.offset + end, type: 'list',
      replay: Object.assign({}, mode), fragment: { kind: 'list-item-source', literal: true, first: !mode.itemSourceStarted } };
    mode.itemSourceStarted = true; mode.itemFirst = false; mode.itemLineStart = text[end - 1] === '\n';
    this.pending = text.slice(end); this.offset += end;
    if (terminated && end === boundary) { mode.itemLiteral = false; mode.nextStart++; }
    if (final && !this.pending.length) this.large = null;
    return block;
  };
  // Map complete quoted physical lines back to their exact source offsets.
  // Prefix stripping is accepted only when it matches the parser's own text.
  function quoteMapping(token) {
    var raw = token.raw, transformed = '', mapping = new Map(), position = 0;
    while (position < raw.length) {
      var end = raw.indexOf('\n', position);
      end = end < 0 ? raw.length : end + 1;
      transformed += raw.slice(position, end).replace(/^ {0,3}>[ \t]?/, '');
      mapping.set(transformed.length, end);
      // Marked paragraph children omit their trailing newline. Consume that
      // physical newline with the child so the next window starts on a line.
      if (raw[end - 1] === '\n') mapping.set(transformed.length - 1, end);
      position = end;
    }
    return transformed === token.text || transformed.replace(/\n$/, '') === token.text ? mapping : null;
  }
  Stream.prototype.windowQuoteChild = function (final) {
    var mode = this.large, text = this.pending;
    if (!text.length) { if (final) this.large = null; return null; }
    // This prefix exists only in the boundary probe, never in displayed source.
    // Preserve a quoted fence until its genuine closer rather than letting an
    // apparent heading inside its body terminate a literal continuation.
    var prefix = mode.quoteFirst ? '' : mode.quoteFence
      ? '> ' + mode.quoteFence + '\n' + (mode.quoteLineStart ? '' : '> ')
      : '> LegnaContinuation' + (mode.quoteLineStart ? '\n' : ' ');
    var all = new parser.Lexer({ gfm: true }).blockTokens(prefix + text), token = all[0];
    if (!token || token.type !== 'blockquote') { mode.quoteLiteral = false; return this.windowContainer(final); }
    var mapping = quoteMapping(token), child = token.tokens[0];
    var childEnd = !mode.quoteWhole && child && mapping && mapping.get(child.raw.length);
    if (mode.quoteWhole) childEnd = null;
    var boundary = Math.max(0, (childEnd == null ? token.raw.length : childEnd) - prefix.length);
    if (!boundary) {
      mode.quoteLiteral = false;
      return this.windowContainer(final);
    }
    var terminated = boundary < text.length || final;
    if (!terminated && text.length < WINDOW) return null;
    var end = safeCut(text, Math.min(WINDOW, boundary), final);
    if (end < boundary) {
      var newline = text.lastIndexOf('\n', end - 1);
      if (newline >= 0) end = newline + 1;
    }
    var lineEnd = 0;
    for (var lines = 0; lines < 256; lines++) {
      var next = text.indexOf('\n', lineEnd);
      if (next < 0 || next + 1 > end) break;
      lineEnd = next + 1;
    }
    if (lines === 256 && lineEnd < end) end = lineEnd;
    var block = { start: this.offset, end: this.offset + end, type: 'blockquote',
      replay: Object.assign({}, mode), fragment: { kind: 'quote-child-source', literal: true, first: mode.quoteFirst } };
    mode.quoteFirst = false; mode.quoteLineStart = text[end - 1] === '\n';
    this.pending = text.slice(end); this.offset += end;
    if (terminated && end === boundary) mode.quoteLiteral = false;
    if (final && !this.pending.length) this.large = null;
    return block;
  };
  // Split containers only between complete semantic children. The final child
  // remains lookahead, so lazy continuation, nested fences and list indentation
  // are still interpreted by Marked rather than a line-oriented approximation.
  Stream.prototype.windowContainer = function (final) {
    var mode = this.large, text = this.pending;
    if (mode.itemLiteral) return this.windowListItem(final);
    if (mode.quoteLiteral) return this.windowQuoteChild(final);
    var prefixEnd = final ? text.length : text.lastIndexOf('\n') + 1;
    if (text.length - prefixEnd > WINDOW) prefixEnd = text.length;
    var lexer = new parser.Lexer({ gfm: true });
    var all = lexer.blockTokens(text.slice(0, prefixEnd)), token = all[0];
    if (!token || token.type !== mode.kind) { this.large = null; return null; }
    var terminated = all.slice(1).some(function (item) { return item.type !== 'space'; }) || final && prefixEnd === text.length;
    var end = 0, count = 0;
    if (mode.kind === 'list') {
      if (token.items[0].raw.length > LARGE) {
        var marker = /^( {0,3})(?:[-+*]|\d{1,9}[.)])[ \t]+/.exec(text);
        if (!marker) throw new Error('boundary');
        mode.itemLiteral = true; mode.itemFirst = true; mode.itemLineStart = true; mode.itemSemantic = false; mode.itemSourceStarted = false;
        mode.itemPrefix = marker[0].replace(/[ \t]+$/, ' ');
        return this.windowListItem(final);
      }
      var available = token.items.length - (terminated ? 0 : 1);
      var largeItem = token.items.findIndex(function (item) { return item.raw.length > WINDOW; });
      if (largeItem > 0) available = Math.min(available, largeItem);
      if (!terminated && largeItem < 0 && available < 16 && text.length <= MAX) return null;
      for (; count < Math.min(16, available); count++) {
        var next = end + token.items[count].raw.length;
        if (next > WINDOW && count) break;
        if (next > MAX) throw new Error('block');
        end = next;
      }
      if (count === token.items.length) end = token.raw.length;
    } else {
      // Mapping is accepted only when it reproduces Marked's exact text. This
      // deliberately leaves unusual lazy-prefix rewrites to the ordinary lexer.
      var mapping = quoteMapping(token);
      var firstChild = token.tokens[0];
      if (firstChild && (firstChild.raw.length > LARGE || mapping && mapping.get(firstChild.raw.length) > LARGE)) {
        mode.quoteLiteral = true; mode.quoteFirst = true; mode.quoteLineStart = true;
        // Nested container continuation carries grammar state beyond a single
        // paragraph. Keep the remainder of this quote explicitly as source,
        // rather than inventing semantic headings inside an unclosed fence.
        mode.quoteWhole = firstChild.type === 'list' || firstChild.type === 'blockquote';
        var openingFence = firstChild.type === 'code' && /^( {0,3}(?:`{3,}|~{3,})[^\n]*)\n/.exec(firstChild.raw);
        mode.quoteFence = openingFence ? openingFence[1] : null;
        return this.windowQuoteChild(final);
      }
      if (mapping) {
        var children = token.tokens, available = children.length, childEnd = 0;
        if (!terminated) {
          while (available && children[available - 1].type === 'space') available--;
          if (available) available--;
        }
        if (!terminated && available < 32 && text.length <= MAX && !children.some(function (child) { return child.raw.length > LARGE; })) return null;
        for (var i = 0; i < available && i < 32; i++) {
          childEnd += children[i].raw.length;
          var candidate = mapping.get(childEnd);
          if (candidate && candidate <= MAX) {
            if (candidate > WINDOW && end) break;
            end = candidate;
          }
        }
        if (terminated && childEnd === token.text.length) end = token.raw.length;
      }
    }
    if (!end) {
      if (text.length > MAX) throw new Error('block');
      return null;
    }
    var context = Object.assign({}, mode);
    var block = { start: this.offset, end: this.offset + end, type: mode.kind,
      replay: context, fragment: { kind: mode.kind, start: mode.nextStart } };
    // Definitions nested inside containers contribute to document-wide links.
    this.definitions(new parser.Lexer({ gfm: true }).blockTokens(text.slice(0, end)));
    mode.nextStart += count;
    this.pending = text.slice(end); this.offset += end;
    if (terminated && end === token.raw.length) this.large = null;
    return block;
  };
  // Never close an inline construct at a viewport boundary. These source
  // windows stay literal unless the separate complete-line semantic planner
  // proves a supported paragraph and maps its syntax back to original offsets.
  Stream.prototype.windowParagraph = function (final) {
    var mode = this.large, text = this.pending;
    if (mode.first && mode.inlineStart == null) mode.inlineStart = this.offset;
    if (!text.length) { if (final) this.large = null; return null; }
    var prefix = mode.first ? '' : mode.lineStart ? 'LegnaContinuation\n' : 'LegnaContinuation ';
    var all = new parser.Lexer({ gfm: true }).blockTokens(prefix + text), token = all[0];
    var boundary = token ? Math.max(0, token.raw.length - prefix.length) : 0;
    if (!boundary) { this.large = null; return null; }
    var terminated = boundary < text.length || final;
    if (!terminated && text.length < WINDOW) return null;
    var end = safeCut(text, Math.min(WINDOW, boundary), final);
    if (end < boundary) {
      var newline = text.lastIndexOf('\n', end - 1);
      if (newline >= 0) end = newline + 1;
    }
    var lineEnd = 0;
    for (var lines = 0; lines < 256; lines++) {
      var next = text.indexOf('\n', lineEnd);
      if (next < 0 || next + 1 > end) break;
      lineEnd = next + 1;
    }
    if (lines === 256 && lineEnd < end) end = lineEnd;
    var block = { start: this.offset, end: this.offset + end, type: 'paragraph',
      replay: Object.assign({}, mode), fragment: { kind: 'paragraph', literal: true, first: mode.first,
        inlineStart: !mode.inlineLineEnded ? mode.inlineStart : undefined } };
    if (text.slice(0, end).includes('\n')) mode.inlineLineEnded = true;
    mode.first = false; mode.lineStart = text[end - 1] === '\n';
    this.pending = text.slice(end); this.offset += end;
    if (terminated && end === boundary) this.large = null;
    return block;
  };
  Stream.prototype.feed = function (text, final) {
    if (typeof text !== 'string' || text.length > 64 * 1024) throw new Error('input');
    this.pending += text;
    var windows = [];
    while (true) {
      if (!this.large && this.pending.length > LARGE) this.large = largeStart(this.pending);
      if (!this.large) break;
      var window = this.large.kind === 'table-header-source' ? this.windowTableHeader(final)
        : this.large.kind === 'table' ? this.windowTable(final)
        : this.large.kind === 'fence' ? this.windowFence(final)
        : this.large.kind === 'paragraph' ? this.windowParagraph(final) : this.windowContainer(final);
      if (!window) {
        if (!this.large) break;
        return { blocks: windows, offset: this.offset, version: this.version, final: !!final };
      }
      windows.push(window);
    }
    var lastLineEnd = this.pending.lastIndexOf('\n') + 1;
    // Include a giant unfinished physical line in the boundary probe so a
    // stable preceding heading cannot indefinitely hide its following block.
    var cut = final || this.pending.length - lastLineEnd > LARGE ? this.pending.length : lastLineEnd;
    var prefix = this.pending.slice(0, cut),
      lexer = new parser.Lexer({ gfm: true });
    // Marked drops duplicate definitions from its returned token list. Retag only
    // during indexing so every consumed source character has a range; semantics
    // still use the original tag with first-definition-wins below.
    var definition = lexer.tokenizer.def.bind(lexer.tokenizer),
      definitionId = 0;
    lexer.tokenizer.def = function (source) {
      var token = definition(source);
      if (token) {
        token.originalTag = token.tag;
        token.tag = '\u0000' + definitionId++;
      }
      return token;
    };
    var tokens = lexer.blockTokens(prefix),
      raw = tokens
        .map(function (t) {
          return t.raw;
        })
        .join('');
    if (raw !== prefix) throw new Error('boundary');
    var end = tokens.length;
    if (!final) {
      // The last substantive block may still become a table, a continued list,
      // a setext heading, an open fence, etc. Its following blank lines stay too.
      while (end && tokens[end - 1].type === 'space') end--;
      if (end) end--;
    }
    var committed = tokens.slice(0, end),
      blocks = windows,
      consumed = 0,
      offset = this.offset;
    committed.forEach(function (token) {
      var length = token.raw.length;
      if (length > MAX) throw new Error('block');
      if (token.type !== 'space' && token.type !== 'def')
        blocks.push({ start: offset + consumed, end: offset + consumed + length, type: token.type });
      consumed += length;
    });
    this.definitions(committed);
    this.pending = this.pending.slice(consumed);
    this.offset += consumed;
    if (this.pending.length > LARGE && largeStart(this.pending)) {
      var more = this.feed('', final);
      blocks.push.apply(blocks, more.blocks);
    } else if (this.pending.length > MAX) throw new Error('block');
    return { blocks: blocks, offset: this.offset, version: this.version, final: !!final };
  };
  function tokens(source, links, fragment) {
    if (fragment && ['table-row-source', 'list-item-source', 'quote-child-source', 'table-header-source'].includes(fragment.kind)) {
      if (source.length > WINDOW + 4096) throw new Error('block');
      var result = fragment.header ? tokens(fragment.header, links) : [];
      result.push({ type: 'paragraph', tokens: [{ type: 'literal', text: source.slice(fragment.from || 0) }] });
      return result;
    }
    if (fragment && fragment.kind === 'paragraph' && fragment.literal) {
      if (source.length > WINDOW) throw new Error('block');
      return [{ type: 'paragraph', tokens: [{ type: 'literal', text: source }] }];
    }
    if (fragment && fragment.kind === 'fence') {
      if (source.length > WINDOW + 4096) throw new Error('block');
      var content = source.slice(fragment.from, fragment.to);
      if (fragment.indent) {
        var lines = content.split('\n');
        lines = lines.map(function (line, index) { return index || fragment.lineStart ? line.replace(new RegExp('^ {0,' + fragment.indent + '}'), '') : line; });
        content = lines.join('\n');
      }
      return [{ type: 'code', text: content, lang: fragment.lang, fragment: true }];
    }
    if(fragment&&fragment.kind==='list-item-children'&&!fragment.first)source=fragment.marker+'LegnaContinuation\n\n'+source;
    if (fragment && fragment.kind === 'table') source = fragment.header + source.slice(fragment.from, fragment.to);
    if (source.length > MAX) throw new Error('block');
    var lexer = new parser.Lexer({ gfm: true });
    Object.setPrototypeOf(lexer.tokens.links, links && Object.getPrototypeOf(links) === null
      ? links : Object.assign(Object.create(null), links || {}));
    var result = lexer.blockTokens(source);
    // blockTokens preserves supplied cross-block definitions; resolve inline
    // tokens only after the whole complete block has contributed its own defs.
    lexer.inlineQueue.forEach(function (item) {
      lexer.inlineTokens(item.src, item.tokens);
    });
    if(fragment&&fragment.kind==='list-item-children'){
      var list=result[0];
      if(!list||list.type!=='list'||list.items.length!==1)throw new Error('boundary');
      if(!fragment.first){
        var first=list.items[0].tokens.shift();
        if(!first||first.text!=='LegnaContinuation')throw new Error('boundary');
        list.items[0].continuation=true;
      }
      list.start=fragment.start;list.loose=true;list.items[0].loose=true;
      list.items[0].tokens=list.items[0].tokens.map(function(token){return token.type==='text'?Object.assign({},token,{type:'paragraph'}):token;});
    }
    if (fragment && fragment.kind === 'list' && result[0] && result[0].type === 'list' && result[0].ordered)
      result[0].start = fragment.start;
    if (fragment && fragment.kind === 'table' && fragment.omitHeader && result[0] && result[0].type === 'table') result[0].header = [];
    inspect(result, 0, { count: 0 });
    return result;
  }
  function needed(source, fragment) {
    var names = new Set();
    tokens(source, new Proxy(Object.create(null), { get: function (_, name) {
      if (typeof name === 'string') names.add(name);
      return undefined;
    } }), fragment);
    return Array.from(names);
  }
  var api = { Stream: Stream, tokens: tokens, needed: needed, limit: MAX, windowLimit: WINDOW };
  if (typeof module === 'object') module.exports = api;
  else root.LegnaMarkdownBlocks = api;
})(typeof globalThis === 'object' ? globalThis : this);
