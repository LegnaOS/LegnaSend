/* Compact in-page controls; original browser download remains an explicit fallback. */
(function (root) {
  'use strict';
  function mount(options) {
    var engine = root.LegnaDownloads, container = options.container, labels = options.labels, nodes = new Map(), choosing = false, closed = false, notice = null, fallbackSource = null;
    function el(tag, cls, text) { var n = document.createElement(tag); n.className = cls || ''; if (text != null) n.textContent = text; return n; }
    function bytes(value) {
      var units = ['B', 'KiB', 'MiB', 'GiB'], i = 0;
      while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
      return (i ? value.toFixed(1) : Math.round(value)) + ' ' + units[i];
    }
    container.className = 'download-panel'; container.hidden = true;
    var heading = el('h2'), hint = el('details', 'download-hint'), summary = el('summary'), copy = el('p'), message = el('p', 'download-message'), list = el('div', 'download-task-list');
    hint.appendChild(summary); hint.appendChild(copy);
    message.setAttribute('role', 'status'); message.setAttribute('aria-live', 'polite'); container.appendChild(heading); container.appendChild(hint); container.appendChild(message); container.appendChild(list);
    var manager = new engine.Manager({ onChange: render });
    function showNotice(key, source) { notice = key; fallbackSource = source || null; renderNotice(); }
    function renderNotice() {
      message.textContent = notice ? labels[notice] || labels.error : '';
      if (fallbackSource) {
        var original = el('a', 'download-original', labels.downloadOriginal); original.href = engine.sourceUrl(fallbackSource);
        message.appendChild(document.createTextNode(' ')); message.appendChild(original);
      }
    }
    function action(row, key, callback) { var button = el('button'); button.type = 'button'; button.onclick = callback; row.appendChild(button); return button; }
    function create(task) {
      var row = el('article', 'download-task'), top = el('div', 'download-task-top'), name = el('span', 'download-name', task.name), state = el('span', 'download-state');
      name.title = task.name; top.appendChild(name); top.appendChild(state); row.appendChild(top);
      var progress = el('progress', 'download-progress'); progress.max = task.size || 1; progress.setAttribute('aria-label', task.name); row.appendChild(progress);
      var metrics = el('div', 'download-metrics'), amount = el('span'), speed = el('span'); metrics.appendChild(amount); metrics.appendChild(speed); row.appendChild(metrics);
      var error = el('p', 'download-error'); error.setAttribute('role', 'status'); row.appendChild(error);
      var actions = el('div', 'download-actions'); row.appendChild(actions);
      var pause = action(actions, 'pause', function () { manager.pause(task); });
      var resume = action(actions, 'continue', function () { manager.start(task); });
      var cancel = action(actions, 'cancel', function () { manager.cancel(task); });
      var objectUrl = null;
      var save = action(actions, 'save', function () {
        try {
          if (!objectUrl) objectUrl = URL.createObjectURL(task.sink.blob());
          var a = el('a'); a.href = objectUrl; a.download = task.name.replace(/[\\/]/g, '-'); document.body.appendChild(a); a.click(); a.remove();
        } catch (_) { task.error = 'storage'; render(manager.tasks); }
      });
      var original = el('a', 'download-original'); original.href = engine.sourceUrl(task); actions.appendChild(original);
      var remove = action(actions, 'remove', async function () { await manager.remove(task); });
      list.appendChild(row);
      return { row: row, state: state, progress: progress, amount: amount, speed: speed, error: error, pause: pause, resume: resume,
        cancel: cancel, save: save, original: original, remove: remove, release: function () { if (objectUrl) URL.revokeObjectURL(objectUrl); row.remove(); } };
    }
    function render(tasks) {
      if (closed) return;
      heading.textContent = labels.downloadTasks; summary.textContent = labels.downloadScope; copy.textContent = labels.downloadSessionHint;
      nodes.forEach(function (node, task) { if (!tasks.includes(task)) { node.release(); nodes.delete(task); } });
      tasks.forEach(function (task) {
        var node = nodes.get(task); if (!node) { node = create(task); nodes.set(task, node); }
        node.state.textContent = labels['dl_' + (task.state === 'failed' && task.error === 'authRequired' ? 'authRequired' : task.state)]; node.row.dataset.state = task.state;
        node.progress.value = task.size ? task.offset : task.state === 'complete' ? 1 : 0;
        node.amount.textContent = bytes(task.offset) + ' / ' + bytes(task.size);
        node.speed.textContent = task.state === 'downloading' ? labels.speed + ': ' + (task.speed == null ? labels.measuringSpeed : bytes(task.speed) + '/s') : '';
        node.error.textContent = task.state === 'cancelled' && task.sink.kind === 'disk' ? labels.downloadPartialKept : task.error ? labels['dlError_' + task.error] || labels.error : '';
        node.pause.textContent = labels.downloadPause; node.pause.hidden = !['queued', 'checking', 'downloading'].includes(task.state);
        node.resume.textContent = task.state === 'failed' ? labels.retry : task.state === 'ready' ? labels.downloadStart : labels.continue;
        node.resume.hidden = !['ready', 'paused', 'failed'].includes(task.state);
        node.cancel.textContent = labels.cancel; node.cancel.hidden = ['complete', 'cancelled', 'blocked'].includes(task.state); node.cancel.disabled = ['cancelling', 'saving'].includes(task.state);
        node.save.textContent = labels.downloadSave; node.save.hidden = task.state !== 'complete' || task.sink.kind !== 'memory';
        node.original.textContent = labels.downloadOriginal; node.original.title = labels.downloadOriginalHint;
        node.remove.textContent = labels.downloadRemove; node.remove.hidden = !['complete', 'cancelled', 'blocked', 'failed', 'paused'].includes(task.state);
        if (task.state === 'complete' && task.sink.kind === 'disk') node.state.textContent = labels.downloadSaved;
      });
    }
    async function add(fileId, file, sessionId) {
      container.hidden = false; render(manager.tasks);
      if (choosing) { showNotice('downloadChoosing'); return; }
      var old = manager.tasks.find(function (t) { return t.fileId === fileId && t.sessionId === sessionId && t.state !== 'cancelled'; });
      if (old) { showNotice(null); manager.start(old); nodes.get(old).row.scrollIntoView({ block: 'nearest' }); return; }
      choosing = true; showNotice(null);
      try {
        if (manager.tasks.length >= 20) throw Object.assign(new Error(), { code: 'taskLimit' });
        var sink;
        if (file.size > engine.BUFFER_LIMIT) {
          if (!root.isSecureContext || !root.showSaveFilePicker) throw Object.assign(new Error(), { code: 'storageUnsupported' });
          showNotice('downloadChoosing');
          // Invoked synchronously from the click, before network awaits, to retain user activation.
          var handle = await root.showSaveFilePicker({ suggestedName: file.fileName.replace(/[\\/]/g, '-') });
          if (closed) return; sink = new engine.DiskSink(handle);
        } else sink = new engine.MemorySink(file.size);
        var task = manager.add({ fileId: fileId, sessionId: sessionId, name: file.fileName, size: file.size }, sink);
        showNotice(null); manager.start(task); nodes.get(task).row.scrollIntoView({ block: 'nearest' });
      } catch (error) {
        if (!closed) {
          if (error.name === 'AbortError') showNotice(null);
          else showNotice('dlError_' + error.code, { sessionId: sessionId, fileId: fileId });
        }
      } finally { choosing = false; }
    }
    render(manager.tasks);
    return { add: add, manager: manager, pauseAll: function () { manager.tasks.forEach(function (task) { manager.pause(task); }); }, setLabels: function (value) { labels = value; renderNotice(); render(manager.tasks); },
      close: function () { closed = true; manager.close(); nodes.forEach(function (node) { node.release(); }); nodes.clear(); } };
  }
  root.LegnaDownloadUI = { mount: mount };
})(typeof globalThis !== 'undefined' ? globalThis : this);
