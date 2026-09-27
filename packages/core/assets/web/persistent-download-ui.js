(function (root) {
  'use strict';
  function mount(options) {
    var doc = root.document,
      engine = root.LegnaPersistentDownloads,
      container = options.container,
      labels = options.labels,
      nodes = new Map(),
      closed = false,
      ready = false,
      notice = null,
      choosing = false,
      confirmation = null, batchController = null, destinationState = null;
    function el(tag, cls, text) {
      var n = doc.createElement(tag);
      n.className = cls || '';
      if (text != null) n.textContent = text;
      return n;
    }
    function action(parent, fn) {
      var b = el('button');
      b.type = 'button';
      b.onclick = fn;
      parent.appendChild(b);
      return b;
    }
    function bytes(n) {
      var unit = ['B', 'KiB', 'MiB', 'GiB', 'TiB'],
        i = 0;
      while (n >= 1024 && i < 4) {
        n /= 1024;
        i++;
      }
      return (i ? n.toFixed(1) : n) + ' ' + unit[i];
    }
    container.hidden = false;
    container.className = 'download-panel persistent-download-panel';
    var top = el('div', 'download-panel-top'),
      heading = el('h2'),
      folder = action(top, async function () {
        if (!manager) { details.open = true; notice = 'downloadNativeHint'; render(); return; }
        if (choosing) return;
        choosing = true;
        render();
        try {
          var directory = await root.showDirectoryPicker({ id: 'legnasend-downloads', startIn: 'downloads', mode: 'readwrite' });
          if (closed) return;
          await manager.registry.directory(directory);
          manager.directory = directory;
          notice = null;
        } catch (e) {
          if (e.name !== 'AbortError') notice = 'dlError_' + engine.code(e);
        } finally {
          choosing = false;
          render();
        }
      });
    var browserFolder = action(top, async function () {
      if (!manager || choosing) return;
      choosing = true; render();
      try { await manager.registry.directory(null); manager.directory = null; notice = null; }
      catch (e) { notice = 'dlError_' + engine.code(e); }
      finally { choosing = false; render(); }
    });
    top.insertBefore(heading, folder);
    container.appendChild(top);
    var details = el('details', 'download-hint'),
      summary = el('summary'),
      copy = el('p');
    details.append(summary, copy);
    container.appendChild(details);
    var retention = el('div', 'download-retention'), retentionLabel = el('label'), retentionSelect = el('select'), retentionStatus = el('span');
    var retentionOptions = [-2,0,1,7,30].map(function(days) { var option=el('option'); option.value=String(days); retentionSelect.appendChild(option); return option; });
    retentionLabel.appendChild(retentionSelect);
    retention.append(retentionLabel, retentionStatus);
    retentionStatus.setAttribute('role','status'); retentionStatus.setAttribute('aria-live','polite');
    container.appendChild(retention);
    var retentionBusy=false;
    retentionSelect.onchange=async function() {
      if(!manager||!manager.setRetention||retentionBusy)return;
      var days=Number(retentionSelect.value);
      retentionBusy=true;render();
      try { await manager.setRetention(days); notice=null; }
      catch(e){notice='dlError_'+engine.code(e);}
      finally {retentionBusy=false;render();}
    };
    function retentionText() {
      var language=(doc.documentElement&&doc.documentElement.lang||root.navigator&&root.navigator.language||'en').toLowerCase();
      if(language==='zh-tw'||language==='zh-hk'||language.startsWith('zh-hant'))return ['未完成下載保留','1 小時（預設）','保留，手動移除','1 天後清理','7 天後清理','30 天後清理','已清理','保留／待重試','清理已授權目錄中未完成的單檔與批次快取；保留完整檔案及目錄。'];
      if(language.startsWith('zh'))return ['未完成下载保留','1 小时（默认）','保留，手动移除','1 天后清理','7 天后清理','30 天后清理','已清理','保留／待重试','清理已授权目录中未完成的单文件与批次缓存；保留完整文件及目录。'];
      return ['Keep unfinished downloads','1 hour (default)','Keep until removed','Clean after 1 day','Clean after 7 days','Clean after 30 days','Removed','Retained / retry needed','Clean unfinished individual and batch caches in authorized folders; preserve complete files and directories.'];
    }
    var scheduling = el('details', 'download-hint'), scheduleTitle = el('summary'), scheduleFields = el('div', 'download-actions download-transfer-settings');
    var fileLabel = el('label'), fileCount = el('select'), rangeLabel = el('label'), rangeCount = el('select');
    var reconnectLabel = el('label'), reconnect = el('input'), reconnectText = el('span'), scheduleHint = el('p');
    reconnect.type = 'checkbox'; reconnectLabel.append(reconnect, reconnectText);
    [1,2,4].forEach(function(value) {
      [fileCount,rangeCount].forEach(function(select){var option=el('option', '', String(value));option.value=String(value);select.appendChild(option);});
    });
    fileLabel.appendChild(fileCount); rangeLabel.appendChild(rangeCount);
    scheduleFields.append(fileLabel, rangeLabel, reconnectLabel); scheduling.append(scheduleTitle, scheduleFields, scheduleHint); container.appendChild(scheduling);
    var settingBusy = false, bulkBusy = false;
    async function configure() {
      if(!manager || !manager.configureTransfers || settingBusy || !ready) return;
      settingBusy=true;
      var settings={files:Number(fileCount.value),ranges:Number(rangeCount.value),autoReconnect:reconnect.checked};
      render();
      try {await manager.configureTransfers(settings);notice=null;} catch(e){notice='dlError_'+engine.code(e);}
      finally {settingBusy=false;render();}
    }
    fileCount.onchange=rangeCount.onchange=reconnect.onchange=configure;
    var bulk = el('div','download-actions');
    async function all(operation) {
      if(bulkBusy || !ready) return;
      bulkBusy=true;
      var owners=(batches?batches.list().map(function(t){return [batches,t];}):[])
        .concat(manager?manager.tasks.filter(function(t){return !t.record.batchId;}).map(function(t){return [manager,t];}):[]);
      // Snapshot queued work before pausing active jobs, so a finishing task
      // cannot pump another item between the two operations.
      if(operation==='pause') {
        manager.holdScheduling=true;
        if(batches)batches.holdScheduling=true;
      }
      render();
      try {
        var outcomes = await Promise.allSettled(owners.map(async function(pair) {
          var owner=pair[0],task=pair[1];
          if(operation==='pause') await owner.pause(task);
          else if(operation==='resume' && ['ready','paused','failed'].includes(task.state)) await owner.start(task);
          else if(operation==='clear' && task.state==='complete') await owner.remove(task);
        }));
        var failed=outcomes.find(function(result){return result.status==='rejected';});
        if(failed)throw failed.reason;
        notice=null;
      } catch(e){notice='dlError_'+engine.code(e);}
      finally {
        if(operation==='pause') {manager.holdScheduling=false;if(batches)batches.holdScheduling=false;manager.pump();}
        bulkBusy=false;render();
      }
    }
    var pauseAll=action(bulk,function(){invoke(all('pause'));}),resumeAll=action(bulk,function(){invoke(all('resume'));}),clearFinished=action(bulk,function(){invoke(all('clear'));});
    container.appendChild(bulk);
    var message = el('p', 'download-message');
    message.setAttribute('role', 'status');
    message.setAttribute('aria-live', 'polite');
    container.appendChild(message);
    var list = el('div', 'download-task-list');
    container.appendChild(list);
    var dialog = el('dialog', 'download-confirm'),
      title = el('h2'),
      description = el('p'),
      buttons = el('div', 'download-actions');
    dialog.setAttribute('aria-label', labels.downloadRemove);
    dialog.append(title, description, buttons);
    container.appendChild(dialog);
    var no = action(buttons, function () {
        confirmation = null;
        dialog.close();
      }),
      yes = action(buttons, async function () {
        var selected = confirmation;
        if (!selected) return;
        yes.disabled = true;
        try {
          await selected.owner.remove(selected.task);
          confirmation = null;
          dialog.close();
          notice = null;
        } catch (e) {
          notice = 'dlError_' + engine.code(e);
        } finally {
          yes.disabled = false;
          render();
        }
      });
    dialog.addEventListener('cancel', function () {
      confirmation = null;
    });
    function confirmRemoval(task,owner) {
      confirmation = {task:task,owner:owner};
      title.textContent = task.name;
      description.textContent = labels.downloadRemoveHint;
      dialog.showModal();
      no.focus();
    }
    var manager = engine && engine.supported() ? new engine.Manager({ onChange: render, onAuth: options.onAuth }) : null;
    var batches = manager && root.LegnaBatchDownloads ? new root.LegnaBatchDownloads.Manager({manager:manager,onChange:render,onInvalidated:function(code){notice='dlError_'+code;render();}}) : null;
    function invoke(operation) {
      Promise.resolve(operation).catch(function (e) {
        notice = 'dlError_' + engine.code(e);
        render();
      });
    }
    function row(task) {
      var owner=task.isBatch?batches:manager;
      var node = el('article', 'download-task'),
        line = el('div', 'download-task-top'),
        name = el('span', 'download-name', task.name),
        state = el('span', 'download-state');
      name.title = task.name;
      line.append(name, state);
      node.appendChild(line);
      var progress = el('progress', 'download-progress');
      progress.max = task.size || 1;
      progress.setAttribute('aria-label', task.name);
      node.appendChild(progress);
      var metrics = el('div', 'download-metrics'),
        amount = el('span'),
        speed = el('span');
      metrics.append(amount, speed);
      node.appendChild(metrics);
      var error = el('p', 'download-error');
      error.setAttribute('role', 'status');
      node.appendChild(error);
      var actions = el('div', 'download-actions'),
        pause = action(actions, function () {
          invoke(owner.pause(task));
        }),
        resume = action(actions, function () {
          invoke(owner.start(task));
        }),
        remove = action(actions, function () {
          if (task.state === 'complete') invoke(owner.remove(task));
          else confirmRemoval(task,owner);
        });
      var original = el('a', 'download-original');
      actions.appendChild(original);
      node.appendChild(actions);
      list.appendChild(node);
      return {
        node: node,
        state: state,
        progress: progress,
        amount: amount,
        speed: speed,
        error: error,
        pause: pause,
        resume: resume,
        remove: remove,
        original: original
      };
    }
    function render() {
      if (closed) return;
      var tasks = (batches ? batches.list() : []).concat(manager ? manager.tasks.filter(function(t){return !t.record.batchId;}) : []);
      var destination=!!(manager&&manager.directory&&batches);
      if(destination!==destinationState){destinationState=destination;if(options.onDestinationChange)options.onDestinationChange(destination);}
      heading.textContent = tasks.length ? labels.downloadTasks : labels.downloadSettings;
      summary.textContent = labels.downloadScope;
      copy.textContent = labels.downloadSessionHint;
      folder.textContent =
        manager && manager.directory ? (manager.directory.name ? labels.downloadFolder + ': ' + manager.directory.name : labels.downloadFolderChosen) : labels.downloadChooseFolder;
      folder.hidden = false;
      folder.disabled = !!manager && (!ready || choosing);
      browserFolder.textContent = labels.downloadBrowserFolder;
      browserFolder.hidden = !manager || !manager.directory;
      browserFolder.disabled = choosing;
      message.textContent = notice ? labels[notice] || labels.error : !manager ? labels.downloadNativeHint : !ready ? labels.indexing : '';
      var retentionCopy=retentionText();
      retention.hidden=!manager||!manager.setRetention;
      retentionLabel.setAttribute('aria-label',retentionCopy[0]); retentionSelect.setAttribute('aria-label',retentionCopy[0]);
      retention.title=retentionCopy[8];
      retentionOptions.forEach(function(option,index){option.textContent=retentionCopy[index+1];});
      retentionSelect.value=String(manager&&manager.retentionDays||0); retentionSelect.disabled=!ready||retentionBusy;
      var cleanup=manager&&manager.cleanupReport;
      retentionStatus.textContent=cleanup?retentionCopy[6]+': '+cleanup.removed+' · '+retentionCopy[7]+': '+(cleanup.retained+cleanup.failed):retentionCopy[0];
      scheduling.hidden=!manager||!manager.configureTransfers;
      scheduleTitle.textContent=labels.downloadTransferSettings;
      fileLabel.setAttribute('aria-label',labels.downloadParallelFiles);fileCount.setAttribute('aria-label',labels.downloadParallelFiles);fileLabel.title=labels.downloadParallelFiles;
      rangeLabel.setAttribute('aria-label',labels.downloadParallelRanges);rangeCount.setAttribute('aria-label',labels.downloadParallelRanges);rangeLabel.title=labels.downloadParallelRanges;
      // Visible labels are separate from select nodes, preserving focus on rerender.
      if(!fileLabel.firstCopy){fileLabel.firstCopy=el('span');fileLabel.insertBefore(fileLabel.firstCopy,fileCount);}
      if(!rangeLabel.firstCopy){rangeLabel.firstCopy=el('span');rangeLabel.insertBefore(rangeLabel.firstCopy,rangeCount);}
      fileLabel.firstCopy.textContent=labels.downloadParallelFiles;rangeLabel.firstCopy.textContent=labels.downloadParallelRanges;
      fileCount.value=String(manager&&manager.parallelFiles||2);rangeCount.value=String(manager&&manager.parallelRanges||4);
      reconnect.checked=!!(manager&&manager.autoReconnect);reconnectText.textContent=labels.downloadAutoReconnect;
      scheduleHint.textContent=labels.downloadTransferSettingsHint;
      fileCount.disabled=rangeCount.disabled=reconnect.disabled=!ready||settingBusy;
      bulk.hidden=!manager||!tasks.length;
      pauseAll.textContent=labels.downloadPauseAll;resumeAll.textContent=labels.downloadResumeAll;clearFinished.textContent=labels.downloadClearFinished;
      pauseAll.disabled=bulkBusy||!tasks.some(function(t){return ['planning','checking','queued','downloading','checkpointing','saving','waiting'].includes(t.state);});
      resumeAll.disabled=bulkBusy||!tasks.some(function(t){return ['ready','paused','failed'].includes(t.state);});
      clearFinished.disabled=bulkBusy||!tasks.some(function(t){return t.state==='complete';});
      no.textContent = labels.cancel;
      dialog.setAttribute('aria-label', labels.downloadRemove);
      yes.textContent = labels.downloadRemove;
      description.textContent = labels.downloadRemoveHint;
      nodes.forEach(function (n, t) {
        if (!tasks.includes(t)) {
          n.node.remove();
          nodes.delete(t);
        }
      });
      tasks.forEach(function (t) {
        var n = nodes.get(t);
        if (!n) {
          n = row(t);
          nodes.set(t, n);
        }
        n.node.dataset.state = t.state;n.node.dataset.batch = t.isBatch ? 'true' : 'false';
        n.state.textContent = t.state === 'complete' ? labels.downloadSaved : labels['dl_' + (t.state === 'failed' && t.error === 'authRequired' ? 'authRequired' : t.state)];
        n.progress.max = t.size || 1;
        n.progress.value = t.size ? t.offset : t.state === 'complete' ? 1 : 0;
        n.amount.textContent =
          (t.restored ? labels.downloadRecorded + ': ' : '') +
          bytes(t.offset) +
          ' / ' +
          bytes(t.size) +
          (t.pendingBytes ? ' · ' + labels.downloadPending + ': ' + bytes(t.pendingBytes) : '') +
          (t.record.outputName ? ' · ' + t.record.outputName : '') + (t.isBatch ? ' · '+t.record.savedFiles+' / '+t.record.files+' '+labels.batchFiles : '');
        n.speed.textContent =
          t.state === 'downloading' ? labels.speed + ': ' + (t.speed == null ? labels.measuringSpeed : bytes(t.speed) + '/s') : '';
        n.error.textContent = t.error ? labels['dlError_' + t.error] || labels.error : '';
        n.pause.textContent = labels.downloadPause;
        n.pause.hidden = !['planning', 'checking', 'queued', 'downloading', 'checkpointing', 'saving', 'waiting'].includes(t.state);
        n.resume.textContent = t.state === 'failed' ? labels.retry : labels.continue;
        n.resume.hidden = !['ready', 'paused', 'failed'].includes(t.state);
        n.resume.disabled = !!t.promise;
        n.remove.textContent = labels.downloadRemove;
        n.remove.disabled = ['cancelling', 'pausing'].includes(t.state);
        n.original.textContent = labels.downloadOriginal;
        n.original.href = t.isBatch ? '#' : engine.sourceUrl(t.source, manager.session);
        n.original.setAttribute('download', '');
        n.original.hidden = t.isBatch || !['failed','blocked'].includes(t.state) || t.source.kind === 'web' && (!manager.session || !manager.files[t.source.fileId]);
      });
    }
    if (manager)
      manager.ready
        .then(function () {
          ready = true;
          render();
        })
        .catch(function () {
          notice = 'dlError_storage';
          render();
        });
    if(batches)batches.ready.catch(function(e){notice='dlError_'+engine.code(e);render();});
    render();
    return {
      manager: manager, batches: batches,
      usesDirectory: function(){return !!(manager&&ready&&manager.directory&&batches);},
      downloadBatch: function(spec,url,fields){
        if(manager&&ready&&manager.directory&&batches){
          if(choosing)return;choosing=true;notice=null;render();
          invoke(batches.create(spec).finally(function(){choosing=false;render();}));return;
        }
        return this.batch(url,fields);
      },
      ready: manager ? manager.ready : Promise.resolve(),
      available: !!manager,
      // Returning false leaves the real anchor entirely under browser control.
      // The setting, not a second per-file button, chooses the storage adapter.
      downloadSource: function (source) {
        if (!manager || !ready || !manager.directory) return false;
        this.addSource(source); return true;
      },
      batch: async function (url, fields) {
        if (batchController) return;
        batchController = new AbortController(); notice = 'downloadPreparing'; render();
        try {
          var options = {method: fields ? 'POST' : 'HEAD', credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: batchController.signal};
          if (fields) { options.headers = {'Content-Type':'application/x-www-form-urlencoded'}; options.body = new URLSearchParams(fields).toString(); }
          var response = await root.fetch(url + (fields ? '?prepare=1' : ''), options);
          if (!response.ok) {
            var status = response.status;
            throw {code: [401,403].includes(status) ? 'authRequired' : [404,410].includes(status) ? 'sourceEnded' : status === 409 ? 'archiveConflict' : status === 413 ? 'archiveLimit' : status === 429 ? 'busy' : 'network'};
          }
          var downloadUrl = url;
          if (fields) {
            var prepared = await response.json();
            // Only the same-origin archive endpoint may receive this download.
            // Never navigate the live /share pane with a POST form.
            var target = new URL(prepared.downloadUrl, root.location.href), endpoint = new URL(url, root.location.href);
            if (target.origin !== root.location.origin || target.pathname !== endpoint.pathname || !target.searchParams.get('selection') || target.hash)
              throw {code:'network'};
            downloadUrl = target.href;
          } else if (response.body) await response.body.cancel();
          if (closed) return;
          var link = el('a'); link.href = downloadUrl; link.setAttribute('download','');
          doc.body.appendChild(link); link.click(); link.remove();
          notice = 'downloadStartedHint';
        } catch (e) { if (e.name !== 'AbortError') notice = 'dlError_' + (engine ? engine.code(e) : e.code || 'network'); }
        finally { batchController = null; render(); }
      },
      attachSession: function (session, files) {
        if (manager) manager.attachSession(session, files);
      },
      add: async function (id, file, session) {
        if (manager) manager.attachSession(session, manager.files);
        return this.addSource({ kind: 'web', fileId: id, name: file.fileName, size: file.size, sha256: file.sha256 || null });
      },
      addSource: async function (source) {
        if (!manager || !ready) {
          notice = manager ? 'indexing' : 'downloadNativeHint';
          render();
          return;
        }
        if (choosing) return;
        choosing = true;
        notice = null;
        render();
        try {
          var task = await manager.add(source);
          if (!closed && nodes.has(task)) nodes.get(task).node.scrollIntoView({ block: 'nearest' });
        } catch (e) {
          if (e.name !== 'AbortError') notice = 'dlError_' + engine.code(e);
        } finally {
          choosing = false;
          render();
        }
      },
      setLabels: function (value) {
        labels = value;
        render();
      },
      pauseAll: function () {
        if(batches)batches.batches.forEach(function(b){invoke(batches.pause(b));});
        if (manager)
          manager.tasks.forEach(function (t) {
            invoke(manager.pause(t));
          });
      },
      close: function () {
        closed = true;
        if (batchController) batchController.abort();
        if (batches) batches.close();
        if (manager) manager.close();
        if (dialog.open) dialog.close();
        nodes.clear();
      }
    };
  }
  root.LegnaPersistentDownloadUI = { mount: mount };
})(typeof globalThis === 'object' ? globalThis : this);
