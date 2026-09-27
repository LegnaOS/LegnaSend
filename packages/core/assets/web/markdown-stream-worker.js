/* Local worker; never fetch document links or execute document markup. */
importScripts('/assets/vendor/marked.umd.js', '/assets/markdown-table-header.js', '/assets/markdown-blocks.js', '/assets/markdown-inline-window.js');
var stream = new LegnaMarkdownBlocks.Stream(0, null, { externalReferences: true }),
  replay, lookup, inline, inlineJob;
self.onmessage = function (event) {
  var m = event.data,
    result;
  try {
    if (m.op === 'inlineStart') {
      if (typeof m.job !== 'string' || !m.job.length || m.job.length > 128) throw new Error('input');
      inlineJob = m.job; inline = new LegnaMarkdownInlineWindow.Planner(m.start); result = {};
    } else if (m.op === 'inlineFeed' || m.op === 'inlineRender') {
      if (!inline || m.job !== inlineJob) throw new Error('cancelled');
      result = m.op === 'inlineFeed' ? inline.feed(m.text, m.final) : inline.render(m.from, m.to, m.text, m.links || {});
    } else if (m.op === 'feed') result = stream.feed(m.text, m.final);
    else if (m.op === 'replayStart') {
      replay = new LegnaMarkdownBlocks.Stream(m.start, m.context, { externalReferences: true });
      result = {};
    } else if (m.op === 'replay') result = replay.feed(m.text, m.final);
    else if (m.op === 'needed') result = LegnaMarkdownBlocks.needed(m.text, m.fragment);
    else if (m.op === 'lookupStart') {
      lookup = new LegnaMarkdownBlocks.Stream(0, null, { referenceFilter: new Set(m.names) });
      result = {};
    } else if (m.op === 'lookup') {
      lookup.feed(m.text, m.final);
      result = m.final ? lookup.links : {};
      if (m.final) lookup = null;
    } else if (m.op === 'render') result = { tokens: LegnaMarkdownBlocks.tokens(m.text, m.links || {}, m.fragment), version: stream.version };
    else throw new Error('operation');
    self.postMessage({ id: m.id, result: result });
  } catch (error) {
    self.postMessage({ id: m.id, error: error.message });
  }
};
