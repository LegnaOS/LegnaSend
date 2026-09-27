/* Shared, local-only format guidance. Extension/container is not a decoder claim. */
(function(root) {
  'use strict';
  var keys = ['previewSupportImages','previewSupportVideo','previewSupportAudio','previewSupportText','previewSupportMarkdown','previewSupportOther','previewSupportDownload'];
  function mount(container, labels) {
    if (!container || !labels || !labels.previewSupportTitle) return;
    var doc = container.ownerDocument || root.document;
    var hint = doc.createElement('p');
    hint.className = 'preview-support-hint';
    hint.textContent = labels.previewSupportHint;
    var details = doc.createElement('details');
    details.className = 'preview-support-details';
    var summary = doc.createElement('summary');
    summary.textContent = labels.previewSupportTitle;
    var body = doc.createElement('div');
    body.className = 'preview-support-body';
    body.appendChild(hint);
    keys.forEach(function(key) {
      var paragraph = doc.createElement('p');
      paragraph.textContent = labels[key] || '';
      body.appendChild(paragraph);
    });
    details.appendChild(summary);
    details.appendChild(body);
    container.replaceChildren(details);
  }
  var api = {mount:mount, keys:keys};
  if (typeof module === 'object') module.exports = api;
  else root.LegnaPreviewSupport = api;
})(typeof globalThis === 'object' ? globalThis : this);
