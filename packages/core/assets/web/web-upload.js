/* Original LocalSend v2 upload wire format; directory support only changes fileName paths. */
(function (root) {
  'use strict';
  function namedFile(file, name) {
    var parts = String(name).split('/');
    if (!name || /[\\\0]/.test(name) || /^[a-z]:/i.test(name) || parts.some(function (part) { return !part || part === '.' || part === '..'; })) {
      var error = new Error('invalidPath'); error.code = 'invalidPath'; throw error;
    }
    return { file: file, name: name };
  }
  async function collectDrop(transfer, onProgress) {
    // Capture handles while the drop event still grants access to DataTransfer.
    var roots = [], loose = [], items = transfer.items;
    if (items && items.length) {
      for (var i = 0; i < items.length; i++) {
        if (items[i].kind && items[i].kind !== 'file') continue;
        var entry = items[i].webkitGetAsEntry && items[i].webkitGetAsEntry();
        if (entry) roots.push({ entry: entry, prefix: '', depth: 0 });
        else { var file = items[i].getAsFile(); if (file) loose.push(namedFile(file, file.name)); }
      }
    } else {
      for (var j = 0; j < transfer.files.length; j++) loose.push(namedFile(transfer.files[j], transfer.files[j].name));
    }
    var files = loose, visited = 0;
    while (roots.length) {
      var current = roots.pop(), name = current.prefix + current.entry.name;
      namedFile(null, name);
      if (current.depth > 128) throw new Error('readError');
      if (current.entry.isFile) {
        var value = await new Promise(function (resolve, reject) { current.entry.file(resolve, reject); });
        files.push(namedFile(value, name));
      } else if (current.entry.isDirectory) {
        var reader = current.entry.createReader();
        while (true) {
          var batch = await new Promise(function (resolve, reject) { reader.readEntries(resolve, reject); });
          if (!batch.length) break;
          batch.forEach(function (entry) { roots.push({ entry: entry, prefix: name + '/', depth: current.depth + 1 }); });
          await new Promise(function (resolve) { setTimeout(resolve, 0); });
        }
      }
      if (++visited % 100 === 0) { if (onProgress) onProgress(files.length); await new Promise(function (resolve) { setTimeout(resolve, 0); }); }
    }
    return files;
  }
  async function manifest(selection, fingerprint, protocol) {
    var selected = Object.create(null), files = Object.create(null), paths = new Set();
    for (var i = 0; i < selection.length; i++) {
      if (i % 250 === 0) await new Promise(function (resolve) { setTimeout(resolve, 0); });
      var item = namedFile(selection[i].file, selection[i].name);
      if (paths.has(item.name)) { var error = new Error('duplicatePath'); error.code = 'duplicatePath'; throw error; }
      paths.add(item.name);
      selected[String(i)] = item.file;
      files[String(i)] = { id: String(i), fileName: item.name, size: item.file.size, fileType: item.file.type || 'application/octet-stream' };
    }
    return { selected: selected, body: JSON.stringify({ info: { alias: 'Web Browser', version: '2.1', deviceType: 'web', fingerprint: fingerprint,
      port: 0, protocol: protocol, download: false }, files: files }) };
  }
  // Sampled only on the 500 ms UI tick. Monotonic timestamps avoid clock changes.
  function RateMeter() { this.samples = []; }
  RateMeter.prototype.sample = function (bytes, now) {
    bytes = Math.max(0, bytes); var samples = this.samples;
    if (samples.length && (now < samples[samples.length - 1].time || bytes < samples[samples.length - 1].bytes)) samples.length = 0;
    if (samples.length && now === samples[samples.length - 1].time) return null;
    samples.push({ time: now, bytes: bytes });
    while (samples.length > 2 && samples[1].time <= now - 3000) samples.shift();
    while (samples.length > 32) samples.splice(1, 1);
    var elapsed = now - samples[0].time;
    return elapsed < 250 ? null : Math.round((bytes - samples[0].bytes) * 1000 / elapsed);
  };
  function bytesLabel(bytes) {
    var units = ['B', 'KB', 'MB', 'GB', 'TB'], value = Math.max(0, bytes), i = 0;
    while (value >= 1000 && i < units.length - 1) { value /= 1000; i++; }
    return (i ? value.toFixed(1) : Math.round(value)) + ' ' + units[i];
  }
  // XHR exposes upload byte progress without buffering or changing the original file body.
  function uploadFile(url, file, options) {
    options = options || {};
    return new Promise(function (resolve, reject) {
      var xhr = options.createXhr ? options.createXhr() : new root.XMLHttpRequest(), signal = options.signal, settled = false;
      function cleanup() { xhr.onload = xhr.onerror = xhr.onabort = xhr.ontimeout = xhr.upload.onprogress = null; if (signal) signal.removeEventListener('abort', abort); }
      function done(error, value) { if (settled) return; settled = true; cleanup(); if (error) reject(error); else resolve(value); }
      function abort() { done(Object.assign(new Error('Aborted'), { name: 'AbortError' })); xhr.abort(); }
      if (signal && signal.aborted) { abort(); return; }
      xhr.onload = function () { done(null, { status: xhr.status }); };
      xhr.onerror = xhr.ontimeout = function () { done(new Error('Upload failed')); };
      xhr.onabort = function () { done(Object.assign(new Error('Aborted'), { name: 'AbortError' })); };
      xhr.upload.onprogress = function (event) { if (!settled && options.onProgress) options.onProgress(Math.max(0, Math.min(file.size, event.loaded))); };
      if (signal) signal.addEventListener('abort', abort, { once: true });
      try { xhr.open('POST', url, true); xhr.send(file); } catch (error) { done(error); }
    });
  }
  function init() {
    var BASE = '/api/localsend/v2', serverI18n = {}, i18n, labels, busy = false, dragDepth = 0, controller, activePin, prepared = false, closed = false;
    var inWorkspace = new URLSearchParams(root.location.search).get('workspace') === '1', uploadAllowed = !inWorkspace;
    var fileInput = document.getElementById('file-input'), folderInput = document.getElementById('folder-input');
    var fileButton = document.getElementById('upload-button'), folderButton = document.getElementById('folder-button'), language = document.getElementById('web-language');
    var meter = null, meterTimer = null, transferred = 0, totalBytes = 0, startedAt = 0, speed = null, average = false;
    var pinValue = new URLSearchParams(root.location.search).get('pin'), progress = { finished: 0, total: 0 };
    function status(text, error) { var node = document.getElementById('status-text'); node.textContent = text || ''; node.className = error ? 'error' : ''; }
    function showProgress(finished, total) {
      progress = { finished: finished, total: total }; var node = document.getElementById('progress-text');
      node.hidden = total === 0; node.textContent = finished + ' / ' + total + ' ' + labels.files;
    }
    function renderBytes() {
      var region = document.getElementById('transfer-metrics'), bar = document.getElementById('transfer-progress');
      region.hidden = !meter && !average; bar.value = totalBytes ? transferred / totalBytes : average ? 1 : 0;
      bar.setAttribute('aria-label', labels.transferProgress);
      document.getElementById('transfer-bytes').textContent = bytesLabel(transferred) + ' / ' + bytesLabel(totalBytes);
      document.getElementById('transfer-speed').textContent = (average ? labels.averageSpeed : labels.speed) + ': ' + (speed == null ? (average ? '—' : labels.measuringSpeed) : bytesLabel(speed) + '/s');
    }
    function tickSpeed() { if (meter) speed = meter.sample(transferred, root.performance.now()); renderBytes(); }
    function startSpeed(total) {
      clearInterval(meterTimer); totalBytes = total; transferred = 0; speed = null; average = false; startedAt = root.performance.now();
      meter = new RateMeter(); meter.sample(0, startedAt); renderBytes(); meterTimer = setInterval(tickSpeed, 500);
    }
    function stopSpeed(success) {
      clearInterval(meterTimer); meterTimer = null;
      if (meter) { var elapsed = root.performance.now() - startedAt; speed = success ? (elapsed > 0 ? Math.round(transferred * 1000 / elapsed) : null) : 0; }
      average = success && !!meter; meter = null; renderBytes();
    }
    function locale() {
      var previous = Object.assign({}, i18n || {}, labels || {});
      i18n = root.LegnaWebUI.localize(serverI18n); labels = root.LegnaWebUI.apply('upload', i18n.webUi);
      root.LegnaWebUI.translateStatus(document.getElementById('status-text'), previous, Object.assign({}, i18n, labels));
      showProgress(progress.finished, progress.total); renderBytes();
    }
    root.LegnaWebUI.onLanguageChange = locale; locale();
    function setBusy(value) { busy = value; fileButton.disabled = folderButton.disabled = value || !uploadAllowed; language.disabled = value; }
    function finish(text, error) { stopSpeed(!error && text === labels.completed); setBusy(false); status(text, error); if (controller) controller.abort(); controller = null; }
    function fingerprint() {
      var value = root.sessionStorage.getItem('fingerprint');
      if (!value) { value = 'web-' + Array.from(root.crypto.getRandomValues(new Uint8Array(16)), function (b) { return b.toString(16).padStart(2, '0'); }).join(''); root.sessionStorage.setItem('fingerprint', value); }
      return value;
    }
    function errorText(response) {
      if (response.status === 403 || response.status === 204) return i18n.uploadRejected;
      if (response.status === 409) return i18n.busy;
      if (response.status === 429) return i18n.tooManyAttempts;
      return labels.error + ' (' + response.status + ')';
    }
    async function sendPrepared(response, selected) {
      if (response.status !== 200) { finish(errorText(response), true); return; }
      var data = await response.json(), ids = Object.keys(data.files);
      status(labels.transferring); showProgress(0, ids.length);
      if (ids.some(function (id) { return !Object.hasOwn(selected, id); })) throw new Error('Invalid accepted file ID');
      startSpeed(ids.reduce(function (sum, id) { return sum + selected[id].size; }, 0));
      var acknowledgedBytes = 0;
      for (var index = 0; index < ids.length; index++) {
        var id = ids[index];
        if (!Object.hasOwn(selected, id)) throw new Error('Invalid accepted file ID');
        var url = BASE + '/upload?sessionId=' + encodeURIComponent(data.sessionId) + '&fileId=' + encodeURIComponent(id) + '&token=' + encodeURIComponent(data.files[id]);
        status(labels.transferring);
        var result = await uploadFile(url, selected[id], { signal: controller.signal, onProgress: function (bytes) {
          transferred = Math.max(transferred, acknowledgedBytes + bytes);
          if (bytes === selected[id].size) status(labels.confirming);
        } });
        if (result.status !== 200) { finish(errorText(result), true); return; }
        acknowledgedBytes += selected[id].size; transferred = acknowledgedBytes;
        showProgress(index + 1, ids.length); renderBytes();
      }
      finish(labels.completed, false);
    }
    function prepareUrl(pin) {
      var params = new URLSearchParams(); if (pin) params.set('pin', pin); if (inWorkspace) params.set('web', '1');
      return BASE + '/prepare-upload' + (params.toString() ? '?' + params.toString() : '');
    }
    async function prepare(batch) {
      controller = new AbortController();
      var response = await fetch(prepareUrl(pinValue), {
        method: 'POST', body: batch.body, headers: { 'Content-Type': 'application/json' }, signal: controller.signal
      });
      if (response.status !== 401) { await sendPrepared(response, batch.selected); return; }
      activePin = root.LegnaWebUI.pin({ labels: labels,
        verify: async function (pin, signal) {
          var result = await fetch(prepareUrl(pin), { method: 'POST', body: batch.body, headers: { 'Content-Type': 'application/json' }, signal: signal });
          if (result.status === 401) return { ok: false, error: i18n.invalidPin };
          if (result.status === 429) return { ok: false, error: i18n.tooManyAttempts, blocked: true };
          // Consume the response before the dialog aborts its own completed request.
          var body = await result.text();
          return { ok: true, pin: pin, response: new Response(body || null, { status: result.status }) };
        },
        onSuccess: function (result) { activePin = null; pinValue = result.pin; sendPrepared(result.response, batch.selected).catch(function () { finish(labels.error, true); }); },
        onCancel: function () { activePin = null; finish(labels.cancelled, false); }
      });
    }
    async function begin(load) {
      if (closed) return;
      if (!uploadAllowed) { status(labels.uploadDisabled, true); return; }
      if (busy || !prepared) { status(labels.busyDrop, true); return; }
      setBusy(true); stopSpeed(false); status(labels.readingFiles); showProgress(0, 0);
      var transferring = false;
      try {
        var selection = await load(function (count) { status(labels.readingFiles + ' ' + count); });
        if (closed) return;
        if (!selection.length) { finish(labels.emptyFolder, false); return; }
        var batch = await manifest(selection, fingerprint(), root.location.protocol === 'https:' ? 'https' : 'http');
        if (closed) return;
        transferring = true; status(i18n.waiting); await prepare(batch);
      } catch (error) { finish(labels[error.code] || (transferring ? labels.error : labels.readError), true); }
    }
    fileButton.onclick = function () { fileInput.click(); }; folderButton.onclick = function () { folderInput.click(); };
    function selected(input) {
      var files = Array.from(input.files); input.value = '';
      begin(async function () { return files.map(function (file) { return namedFile(file, file.webkitRelativePath || file.name); }); });
    }
    fileInput.onchange = function () { if (fileInput.files.length) selected(fileInput); };
    folderInput.onchange = function () { if (folderInput.files.length) selected(folderInput); };
    folderButton.hidden = !('webkitdirectory' in folderInput);
    function isFileDrag(event) { return event.dataTransfer && Array.from(event.dataTransfer.types || []).includes('Files'); }
    function highlight(value) { document.getElementById('content').classList.toggle('drag-over', value); }
    document.addEventListener('dragenter', function (event) { if (!isFileDrag(event)) return; event.preventDefault(); if (!busy) { dragDepth++; highlight(true); } });
    document.addEventListener('dragover', function (event) { if (!isFileDrag(event)) return; event.preventDefault(); event.dataTransfer.dropEffect = busy ? 'none' : 'copy'; });
    document.addEventListener('dragleave', function (event) { if (!isFileDrag(event)) return; dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) highlight(false); });
    document.addEventListener('drop', function (event) {
      if (!isFileDrag(event)) return; event.preventDefault(); dragDepth = 0; highlight(false);
      // begin calls load synchronously before awaiting, so entry handles are captured in this event.
      begin(function (progress) { return collectDrop(event.dataTransfer, progress); });
    });
    function permission(next) {
      uploadAllowed = next.allowUpload === true; setBusy(busy);
      if (!busy && !uploadAllowed) status(labels.uploadDisabled);
      else if (!busy && uploadAllowed && document.getElementById('status-text').textContent === labels.uploadDisabled) status('');
    }
    if (inWorkspace) {
      root.addEventListener('message', function (event) {
        if (event.origin === root.location.origin && event.source === root.parent && event.data && event.data.type === 'legna-workspace') permission(event.data.status);
      });
      // The iframe may load after the parent last sent state; start closed until verified.
      fetch('/web-status.json', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(permission).catch(function () {});
    }
    root.addEventListener('pagehide', function () { closed = true; stopSpeed(false); if (controller) controller.abort(); if (activePin) activePin.close(); });
    fileButton.disabled = folderButton.disabled = true;
    fetch('/i18n.json', { cache: 'no-store' }).then(function (response) { return response.ok ? response.json() : {}; }).catch(function () { return {}; }).then(function (data) {
      serverI18n = data; locale(); prepared = true; setBusy(busy);
    });
  }
  var api = { collectDrop: collectDrop, namedFile: namedFile, manifest: manifest, RateMeter: RateMeter, bytesLabel: bytesLabel, uploadFile: uploadFile, init: init };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else { root.LegnaWebUpload = api; init(); }
})(typeof globalThis !== 'undefined' ? globalThis : this);
