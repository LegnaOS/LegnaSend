/* Literal content search. Separate bounded reader: cancellation never closes the viewport. */
(function (root) {
  'use strict';
  var LIMIT = 1000;
  function expression(query, sensitive) {
    return new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), sensitive ? 'gu' : 'giu');
  }
  function Search(source, query, options) {
    this.source = source; this.query = query.slice(0, 256); this.options = options || {};
    this.matches = []; this.scanned = 0; this.running = false; this.cancelled = false;
    this.capped = false; this.complete = false; this.error = null; this.reader = null;
    this.index = null; this.total = this.options.full ? source.size : source.offset;
  }
  Search.prototype.cancel = function () { this.cancelled = true; if (this.reader) this.reader.close(); };
  Search.prototype.publish = function () {
    if (this.reader && !this.reader.closed) this.index = this.reader.snapshot(false);
    if (this.options.onProgress) this.options.onProgress(this);
  };
  Search.prototype.run = async function () {
    if (!this.query || this.cancelled || !this.source.encoding) return this;
    var source = this.source, options = this.options, snapshot = source.snapshot();
    var scan = new source.constructor(source.url, source.size, { fetch: source.fetch, encoding: source.encoding, cacheLimit: 2 * 1024 * 1024 });
    this.reader = scan; this.running = true;
    var regex = expression(this.query, options.caseSensitive), tail = '', tailRow = 0, tailStart = 0;
    var limit = Math.min(LIMIT, options.limit || LIMIT), scannedRow = 0, pageNumber = 0;
    try {
      await scan.request('HEAD');
      if (scan.etag !== source.etag) throw Object.assign(new Error('changed'), { code: 'changed' });
      scan.encoding = source.encoding; scan.adopt(snapshot);
      while (!this.cancelled) {
        if (pageNumber >= scan.pages.length) {
          if (!options.full || scan.eof) break;
          await scan.ensureRows(scan.rows + 1);
        }
        var page = scan.pages[pageNumber++];
        if (!page) break;
        // Decode in small row batches; blank-line-heavy pages can contain 65k rows.
        for (var start = page.row; start < page.row + page.count && !this.cancelled; start += 128) {
          var rows = await scan.getRows(start, Math.min(128, page.row + page.count - start));
          for (var r = 0; r < rows.length; r++) {
            var row = rows[r], rowId = start + r;
            if (!row.continued) tail = '';
            var joined = tail + row.text, prefix = tail.length, match;
            regex.lastIndex = 0;
            while ((match = regex.exec(joined))) {
              var end = match.index + match[0].length;
              if (end <= prefix) continue;
              var parts = [];
              if (match.index < prefix) parts.push({ row: tailRow, start: tailStart + match.index, end: tailStart + prefix });
              parts.push({ row: rowId, start: Math.max(0, match.index - prefix), end: end - prefix });
              this.matches.push({ row: parts[0].row, line: row.number, parts: parts });
              if (this.matches.length >= limit) { this.capped = true; break; }
            }
            if (this.capped) break;
            var keep = Math.min(this.query.length - 1, row.text.length);
            tail = keep ? row.text.slice(-keep) : ''; tailRow = rowId; tailStart = row.text.length - keep;
            scannedRow = rowId + 1;
          }
          if (this.capped) break;
          await new Promise(function (resolve) { setTimeout(resolve, 0); });
        }
        // Only claim whole pages actually scanned; an early cap is not full-file coverage.
        if (!this.capped && !this.cancelled && scannedRow >= page.row + page.count) this.scanned = page.end;
        this.publish();
        if (this.capped) break;
      }
      this.complete = !this.cancelled && !this.capped && this.scanned >= this.total;
    } catch (error) { if (!this.cancelled) this.error = error; }
    finally { this.running = false; this.publish(); scan.close(); }
    return this;
  };
  var api = { Search: Search, expression: expression, limit: LIMIT };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.LegnaTextSearch = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
