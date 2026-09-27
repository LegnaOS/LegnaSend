/* LegnaSend page UI: local assets, non-blocking dialogs, bounded file-list DOM. */
(function (root) {
  'use strict';
  var defaults = {
    "mediaRetry": "Retry playback",
    "previewSourceChanged": "The shared file changed or ended. Refresh the file list before opening it again.",
    "imageBudgetExceeded": "This image exceeds the preview pixel budget. Download the original to open it in an image app.",
    "imageInspectUnsupported": "Image dimensions could not be inspected within the preview budget. The original is still available to download.",
    "downloadTransferSettings": "Transfer settings",
    "downloadParallelFiles": "Concurrent files",
    "downloadParallelRanges": "Ranges per file",
    "downloadAutoReconnect": "Reconnect interrupted downloads automatically",
    "downloadTransferSettingsHint": "Changes apply as slots become available; at most 8 requests share this site\u2019s network budget. Automatic reconnect retries temporary errors up to 5 times, rechecks the source version, and never prompts for permission in the background. Paused or restored tasks do not start automatically.",
    "downloadPauseAll": "Pause all",
    "downloadResumeAll": "Resume / retry all",
    "downloadClearFinished": "Clear completed records",
    "dl_waiting": "Waiting for connection",

    "mediaPlay": "Play",
    "mediaResume": "Resume playback",
    "mediaPaused": "Paused · buffer released",
    "mediaPosition": "Playback position",

    "receiveTitle": "Shared files",
    "receiveSubtitle": "Preview what you need. Download the original when you are ready.",
    "uploadTitle": "Send to this device",
    "uploadSubtitle": "Choose files or drop them here to begin a transfer.",
    "workspace": "FILE TRANSFER",
    "search": "Search files",
    "all": "All types",
    "image": "Images",
    "video": "Video",
    "audio": "Audio",
    "text": "Text",
    "other": "Other",
    "files": "files",
    "name": "File",
    "actions": "Actions",
    "download": "Download",
    "preview": "Preview",
    "empty": "No matching files",
    "indexing": "Preparing file list…",
    "previous": "Previous",
    "next": "Next",
    "section": "Section",
    "local": "Shared directly from this device",
    "footer": "LegnaSend · 1.0.0",
    "https": "HTTPS · TLS",
    "http": "HTTP · no TLS",
    "httpsHint": "TLS protects this connection, not saved files.",
    "httpHint": "This HTTP connection does not use TLS.",
    "pinTitle": "Enter sharing PIN",
    "pinCopy": "Enter the PIN shown on the sharing device to continue.",
    "pinLabel": "PIN",
    "cancel": "Cancel",
    "continue": "Continue",
    "verifying": "Verifying…",
    "cancelled": "Request cancelled.",
    "retry": "Try again",
    "error": "The request failed. Please try again.",
    "selectFiles": "Choose files",
    "uploadReady": "Ready when you are",
    "uploadDrop": "Drop files here, or choose files from your device.",
    "completed": "Transfer complete",
    "unavailable": "Sharing is not active",
    "unavailableHint": "Start a new link share on the sending device, then open its current address.",
    "chooseFolder": "Choose folder",
    "readingFiles": "Reading files…",
    "busyDrop": "A transfer is active. Add files after it finishes.",
    "emptyFolder": "No files found in this selection.",
    "readError": "Some files could not be read. Select the files again.",
    "duplicatePath": "Duplicate relative paths. Send these selections separately.",
    "invalidPath": "Invalid relative file path.",
    "directoryHint": "Folders keep their relative paths. Empty folders are not transferred by the original protocol.",
    "speed": "Speed",
    "averageSpeed": "Average speed",
    "measuringSpeed": "Measuring…",
    "transferring": "Transferring…",
    "confirming": "Waiting for the receiving device to confirm…",
    "transferProgress": "Transfer progress",
    "takeFiles": "Get files",
    "sendFiles": "Send files",
    "noSharedFiles": "No shared files yet. Files added by the device will appear here.",
    "uploadDisabled": "Web uploads are disabled by this device.",
    "uploadAllowed": "Web uploads allowed",
    "workspaceLoading": "Connecting…",
    "connectionLost": "Connection interrupted. Reconnecting…",
    "refreshSharedFiles": "Refresh shared files",
    "downloadTasks": "Downloads",
    "downloadSessionHint": "The same Download action uses your configured destination. Browser-default batch downloads are ZIPs. An authorized directory saves original files and subfolders, with batch pause/retry and same-address refresh recovery; completed files are kept. Partial data is handled automatically.",
    "downloadChoosing": "Choose where to save the file…",
    "downloadPause": "Pause",
    "downloadStart": "Start",
    "downloadSave": "Save file",
    "downloadSaved": "Saved to file",
    "downloadRemove": "Remove task",
    "downloadOriginal": "Download again in browser",
    "downloadOriginalHint": "Let the browser manage a separate whole-file download.",
    "downloadPartialKept": "Task cancelled. Completed original files are kept.",
    "dl_ready": "Ready",
    "dl_queued": "Queued",
    "dl_checking": "Checking source",
    "dl_downloading": "Downloading",
    "dl_pausing": "Pausing…",
    "dl_paused": "Paused",
    "dl_saving": "Saving…",
    "dl_complete": "Saved",
    "dl_failed": "Retry available",
    "dl_authRequired": "Authorization required",
    "dl_blocked": "Source unavailable",
    "dl_cancelling": "Cancelling…",
    "dl_cancelled": "Cancelled",
    "dlError_sourceEnded": "This source is no longer available. This task cannot resume; other downloads are unaffected.",
    "dlError_sourceChanged": "This resource changed. The old task is stopped and its registered cache is discarded; start from the current file list.",
    "dlError_localChanged": "The selected cache or destination changed. Existing data was kept; check the folder before retrying.",
    "dlError_rangeUnsupported": "This source does not support verified partial reads. Use the browser download.",
    "dlError_invalidRange": "Invalid range response. Existing completed parts were kept; retry checks the source again.",
    "dlError_shortResponse": "The response ended early. Retry to continue from the last complete part.",
    "dlError_network": "Connection interrupted. Retry rechecks the source and resumes completed parts.",
    "dlError_timeout": "The request timed out. Completed parts were kept; try again.",
    "dlError_storage": "Writing failed. Check free space and file permissions before retrying.",
    "dlError_storageUnsupported": "This browser manages the save location. Use its download settings to change it.",
    "dlError_taskLimit": "Retained download limit reached. Remove old tasks or batches first.",
    "dlError_memoryBudget": "The 64 MiB buffer budget is reserved. Save and remove previous tasks first.",
    "dlError_incomplete": "The saved size is incomplete. Retry before saving the result.",
    "downloadScope": "Location and download controls",
    "managedDownload": "Resume",
    "downloadChooseFolder": "Save location",
    "downloadFolder": "Folder",
    "downloadNativeHint": "Downloads use your browser’s download location. To choose each time, enable “Ask where to save each file” in browser settings. Direct folder selection is available only in browsers that support it in a secure context (HTTPS or localhost); ordinary LAN HTTP keeps browser-managed saving.",
    "downloadRemoveHint": "Remove this download and its unfinished data? Completed files are kept.",
    "dlError_permission": "Directory access is needed. Continue to grant access again.",
    "dlError_authRequired": "Access needs renewal. Unlock the workspace or refresh its approved file list, then retry manually. Saved ranges are kept; authorization failures are not retried automatically.",
    "dlError_cacheFormat": "The cache format or checksum is invalid. It was kept unchanged; choose a new task rather than mixing its data.",
    "dlError_checksum": "The restored file differs from its expected checksum. The cache was retained.",
    "dlError_busy": "The source is busy or rate-limited, or another task holds this cache. Wait and retry.",
    "dlError_cleanupPending": "Cache cleanup needs another attempt. Original files were kept.",
    "dl_checkpointing": "Saving checkpoint…",
    "downloadPending": "Writing",
    "downloadRecorded": "Last saved, pending verification",
    "theme": "Appearance",
    "themeSystem": "System",
    "themeLight": "Light",
    "themeDark": "Dark",
    "downloadAll": "Download all · ZIP",
    "downloadSelected": "Download selected · ZIP",
    "selectVisible": "Select filtered files",
    "clearSelection": "Clear selection",
    "selectFile": "Select file",
    "downloadFolderZip": "Download folder · ZIP",
    "downloadSettings": "Download location",
    "downloadBrowserFolder": "Use browser default",
    "downloadPreparing": "Preparing download…",
    "downloadStartedHint": "Download handed to your browser. View progress and choose pause or cancel in its download list.",
    "dlError_archiveConflict": "Some paths conflict in this batch. Rename them on the sender or download a smaller selection.",
    "dlError_archiveLimit": "This batch exceeds the entry or path budget. Download individual subfolders.",
    "downloadAllFiles": "Download all · files",
    "downloadSelectedFiles": "Download selected · files",
    "downloadFolderFiles": "Download folder · files",
    "batchFiles": "files saved",
    "dl_planning": "Preparing file list…",
    "downloadFolderChosen": "Authorized directory",
    "previewSupportTitle": "Supported formats and preview limits",
    "previewSupportHint": "File extensions identify candidates, not guaranteed decoding support. Download original remains available.",
    "previewSupportImages": "Images: PNG, JPEG, GIF, WebP, AVIF and BMP, when this browser can decode them. Very large or animated images also depend on device memory.",
    "previewSupportVideo": "Video: MP4/M4V/MOV, WebM and OGV are containers, not codecs. Playback depends on the browser, operating system and the video/audio codecs inside. LegnaSend does not transcode files.",
    "previewSupportAudio": "Audio: MP3, M4A/AAC, WAV, OGG/OGA/Opus, WebA and FLAC are preview candidates. Actual playback is determined by this browser’s decoder.",
    "previewSupportText": "Text: TXT and LOG. Auto detects a UTF-8/UTF-16 byte-order mark; without one it uses UTF-8. You can select UTF-8, UTF-16 LE/BE or GB18030/GBK. Invalid or other encodings remain downloadable.",
    "previewSupportMarkdown": "Markdown: MD and MARKDOWN. Basic formatting, Mermaid and Markmap (also markedmap) have parsing/rendering budgets. Large code fences and tables use reading windows; extreme nested blocks retain Source. Raw HTML is displayed as text; remote images are not fetched.",
    "previewSupportOther": "Other formats, including HTML, SVG, PDF and office documents, are download-only in this preview. A renamed extension does not make a file decodable.",
    "previewSupportDownload": "If decoding fails, use Download original and open the file with a suitable local app. Preview never sends your file to an external conversion service.",
    "textJumpLine": "Go to line",
    "textJumpGo": "Go",
    "textJumpCancel": "Stop indexing",
    "textJumpIndexing": "Indexing toward line",
    "textJumpStopped": "Line indexing stopped. The current view is unchanged.",
    "textJumpFound": "Showing line",
    "textJumpMissing": "That line is beyond the end of this file. Total lines",
    "textJumpInvalid": "Enter a whole line number starting at 1."
  };
  var paths = {
    send: 'M4 12h14M12 5l7 7-7 7M4 5v14', search: 'm20 20-5-5M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0',
    lock: 'M6 10h12v10H6zM8 10V7a4 4 0 0 1 8 0v3', download: 'M12 3v12m-5-5 5 5 5-5M4 16v4h16v-4',
    preview: 'M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7m13 0a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
    other: 'M6 3h8l4 4v14H6zM14 3v5h4', text: 'M6 3h8l4 4v14H6zM9 11h6M9 15h6',
    image: 'M3 4h18v16H3zM3 16l5-5 4 4 3-3 6 6M15 8h.01', video: 'M3 5h18v14H3zM10 9l5 3-5 3z',
    audio: 'M9 18V5l10-2v13M9 5v4l10-2M9 18a3 3 0 1 1-3-3M19 16a3 3 0 1 1-3-3', upload: 'M12 16V3m-5 5 5-5 5 5M4 15v6h16v-6'
  };
  function el(tag, cls, text) { var node = document.createElement(tag); if (cls) node.className = cls; if (text != null) node.textContent = text; return node; }
  function icon(name) {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.6'); svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('class', 'icon'); svg.setAttribute('aria-hidden', 'true');
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path'); path.setAttribute('d', paths[name] || paths.other); svg.appendChild(path); return svg;
  }
  function labels(custom) { return Object.assign({}, defaults, custom || {}); }
  function translateStatus(node, previous, current) {
    if (!node || !node.textContent) return;
    var keys = Object.keys(previous).filter(function (key) { return typeof previous[key] === 'string' && previous[key].length && typeof current[key] === 'string'; });
    keys.sort(function (a, b) { return previous[b].length - previous[a].length; });
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      if (node.textContent.indexOf(previous[key]) === 0) { node.textContent = current[key] + node.textContent.slice(previous[key].length); return; }
    }
  }
  var selectedLanguage;
  function setLocale(locale) {
    if (!(root.LegnaWebLocales || {})[locale]) return;
    selectedLanguage = locale;
    try { root.localStorage.setItem('legnasend.webLanguage', locale); } catch (_) {}
    if (api.onLanguageChange) api.onLanguageChange();
  }
  function localize(server) {
    var locales = root.LegnaWebLocales || {}, selected = selectedLanguage;
    if (!selected) {
      try { selected = root.localStorage.getItem('legnasend.webLanguage'); } catch (_) {}
      if (!locales[selected]) {
        var preferred = root.navigator && root.navigator.language || 'en';
        selected = /^zh/i.test(preferred) ? /TW|HK|Hant/i.test(preferred) ? /HK/i.test(preferred) ? 'zh-HK' : 'zh-TW' : 'zh-CN' : 'en';
      }
      selectedLanguage = selected;
    }
    document.documentElement.lang = selected;
    return Object.assign({}, server || {}, locales[selected] || {});
  }
  function apply(mode, custom) {
    var l = labels(custom);
    document.querySelectorAll('[data-ui]').forEach(function (node) { var key = node.getAttribute('data-ui'); if (l[key]) node.textContent = l[key]; });
    document.querySelectorAll('[data-icon]').forEach(function (node) { node.textContent = ''; node.appendChild(icon(node.getAttribute('data-icon'))); });
    var title = document.getElementById('page-title'), subtitle = document.getElementById('page-subtitle');
    if (title) title.textContent = l[mode === 'upload' ? 'uploadTitle' : 'receiveTitle'];
    if (subtitle) subtitle.textContent = l[mode === 'upload' ? 'uploadSubtitle' : 'receiveSubtitle'];
    var badge = document.getElementById('connection-badge');
    if (badge) {
      var secure = root.location.protocol === 'https:'; badge.dataset.secure = String(secure); badge.textContent = '';
      badge.appendChild(icon('lock')); badge.appendChild(el('span', '', secure ? l.https : l.http)); badge.title = secure ? l.httpsHint : l.httpHint;
    }
    var language = document.getElementById('web-language');
    if (language) {
      language.value = selectedLanguage || 'en';
      language.onchange = function () {
        selectedLanguage = language.value;
        try { root.localStorage.setItem('legnasend.webLanguage', selectedLanguage); } catch (_) {}
        if (api.onLanguageChange) api.onLanguageChange();
      };
    }
    return l;
  }
  function backgroundInert(value) {
    var saved = [];
    document.querySelectorAll('.web-shell,.app-header').forEach(function (node) { saved.push([node, node.inert]); node.inert = value; });
    return function () { saved.forEach(function (pair) { pair[0].inert = pair[1]; }); };
  }
  function pin(options) {
    var l = labels(options.labels), closed = false, busy = false, controller = null, focus = document.activeElement;
    var restore = backgroundInert(true), oldOverflow = document.body.style.overflow; document.body.style.overflow = 'hidden';
    var overlay = el('div', 'modal-overlay is-open'), form = el('form', 'pin-card'); form.setAttribute('role', 'dialog'); form.setAttribute('aria-modal', 'true');
    form.setAttribute('aria-labelledby', 'pin-title'); form.setAttribute('aria-describedby', 'pin-copy');
    var symbol = el('div', 'pin-symbol'); symbol.appendChild(icon('lock')); form.appendChild(symbol);
    var heading = el('h2', '', l.pinTitle); heading.id = 'pin-title'; form.appendChild(heading);
    var copy = el('p', 'pin-copy', l.pinCopy); copy.id = 'pin-copy'; form.appendChild(copy);
    var label = el('label', 'pin-label', l.pinLabel); label.htmlFor = 'sharing-pin'; form.appendChild(label);
    var input = el('input', 'pin-input'); input.id = 'sharing-pin'; input.type = 'password'; input.inputMode = 'numeric'; input.autocomplete = 'one-time-code';
    input.maxLength = 64; input.required = true; input.setAttribute('aria-describedby', 'pin-error'); form.appendChild(input);
    var error = el('p', 'pin-error', options.error || ''); error.id = 'pin-error'; error.setAttribute('role', 'status'); error.setAttribute('aria-live', 'polite'); form.appendChild(error);
    var actions = el('div', 'pin-actions'), cancel = el('button', '', l.cancel), submit = el('button', 'primary', l.continue);
    cancel.type = 'button'; submit.type = 'submit'; actions.appendChild(cancel); actions.appendChild(submit); form.appendChild(actions); overlay.appendChild(form); document.body.appendChild(overlay);
    function close(cancelled) {
      if (closed) return; closed = true; if (controller) controller.abort(); input.value = ''; overlay.remove(); restore(); document.body.style.overflow = oldOverflow;
      if (focus && focus.isConnected && focus.focus) focus.focus(); if (cancelled && options.onCancel) options.onCancel();
    }
    cancel.onclick = function () { close(true); };
    form.onsubmit = async function (event) {
      event.preventDefault(); if (closed || busy || !input.value.trim()) return;
      busy = true; input.disabled = true; submit.disabled = true; submit.textContent = l.verifying; error.textContent = '';
      controller = new AbortController();
      try {
        var result = await options.verify(input.value.trim(), controller.signal);
        if (closed) return;
        if (result.ok) { close(false); options.onSuccess(result); return; }
        error.textContent = result.error || l.error;
        if (result.blocked) { submit.disabled = true; return; }
      } catch (_) { if (!closed) error.textContent = l.error; }
      finally {
        if (!closed) { busy = false; input.disabled = false; submit.textContent = l.continue;
          if (!submit.disabled || !error.textContent || !(typeof result !== 'undefined' && result.blocked)) submit.disabled = false;
          input.focus(); input.select(); }
      }
    };
    form.onkeydown = function (event) {
      if (event.key === 'Escape') { event.preventDefault(); close(true); }
      if (event.key === 'Tab') {
        var first = input.disabled ? cancel : input, last = submit.disabled ? cancel : submit;
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    };
    input.focus(); return { close: function () { close(false); } };
  }
  function kind(file, previewKind) { var type = previewKind(file.fileType, file.fileName); return type === 'img' ? 'image' : type === 'markdown' ? 'text' : type || 'other'; }
  function size(bytes) {
    if (bytes < 1024) return bytes + ' B';
    var units = ['KB', 'MB', 'GB', 'TB'], n = bytes / 1024, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return n.toFixed(1) + ' ' + units[i];
  }
  async function buildIndex(files, previewKind, alive) {
    var ids = Object.keys(files), entries = [], totalBytes = 0;
    for (var i = 0; i < ids.length; i++) {
      if (i % 1000 === 0) { await new Promise(function (resolve) { setTimeout(resolve, 0); }); if (!alive()) return null; }
      var file = files[ids[i]], name = String(file.fileName || '');
      entries.push({ id: ids[i], file: file, name: name, search: name.toLocaleLowerCase(), kind: kind(file, previewKind) });
      totalBytes += Number.isFinite(file.size) ? file.size : 0;
    }
    return { entries: entries, totalBytes: totalBytes };
  }
  async function filterIndex(entries, query, type, alive) {
    var result = [], search = query.trim().toLocaleLowerCase();
    for (var i = 0; i < entries.length; i++) {
      if (i % 2000 === 0) { await new Promise(function (resolve) { setTimeout(resolve, 0); }); if (!alive()) return null; }
      var entry = entries[i]; if ((!search || entry.search.indexOf(search) !== -1) && (type === 'all' || entry.kind === type)) result.push(i);
    }
    return result;
  }
  function mountFiles(options) {
    var l = labels(options.labels), container = options.container, closed = false, generation = 0, entries = [], filtered = [], totalBytes = 0;
    var scheduled = false, filterTimer, page = 0, ROW = 56, SECTION = 10000, nodes = new Map(), selected = new Set(options.state && options.state.selected || []);
    container.textContent = ''; container.className = 'file-panel';
    var toolbar = el('div', 'files-toolbar'), searchWrap = el('div', 'search-wrap'); searchWrap.appendChild(icon('search'));
    var search = el('input'); search.type = 'search'; search.placeholder = l.search; search.setAttribute('aria-label', l.search); searchWrap.appendChild(search); toolbar.appendChild(searchWrap);
    var select = el('select'); select.setAttribute('aria-label', l.all);
    ['all', 'image', 'video', 'audio', 'text', 'other'].forEach(function (value) { var option = el('option', '', l[value]); option.value = value; select.appendChild(option); }); toolbar.appendChild(select);
    var summary = el('span', 'file-summary'); toolbar.appendChild(summary); container.appendChild(toolbar);
    var batchBar = el('div', 'batch-toolbar'), allDownload = el('button','',l.downloadAll), selectedDownload = el('button','',l.downloadSelected), selectAll = el('button','',l.selectVisible), clearSelection = el('button','',l.clearSelection);
    if (options.onBatch) {
      [allDownload,selectedDownload,selectAll,clearSelection].forEach(function(b){b.type='button';batchBar.appendChild(b);});
      allDownload.onclick = function(){options.onBatch(null);};
      selectedDownload.onclick = function(){if(selected.size)options.onBatch(Array.from(selected));};
      selectAll.onclick = function(){filtered.forEach(function(i){selected.add(entries[i].id);});updateSelection();};
      clearSelection.onclick = function(){selected.clear();updateSelection();};
      container.appendChild(batchBar);
    }
    function updateSelection(){ allDownload.textContent=options.directoryMode?l.downloadAllFiles:l.downloadAll; selectedDownload.disabled=!selected.size;selectedDownload.textContent=(options.directoryMode?l.downloadSelectedFiles:l.downloadSelected)+(selected.size?' ('+selected.size+')':'');clearSelection.disabled=!selected.size;nodes.forEach(function(node){var check=node.querySelector?node.querySelector('.file-select'):node.children.find(function(n){return n.className==='file-select';});if(check)check.checked=selected.has(check.dataset.selectId);}); }
    var caption = el('div', 'list-caption'); caption.appendChild(el('span', '', l.name)); caption.appendChild(el('span', '', l.actions)); container.appendChild(caption);
    var viewport = el('div', 'file-viewport'); viewport.tabIndex = 0; viewport.setAttribute('aria-label', l.receiveTitle); viewport.setAttribute('role', 'list');
    var spacer = el('div', 'file-spacer'), rows = el('div', 'file-rows'), empty = el('div', 'list-empty', l.indexing);
    spacer.appendChild(rows); viewport.appendChild(spacer); container.appendChild(viewport); container.appendChild(empty);
    var footer = el('div', 'list-footer'), note = el('span', '', l.indexing), nav = el('div');
    var previous = el('button', '', l.previous), next = el('button', '', l.next); previous.type = next.type = 'button'; nav.appendChild(previous); nav.appendChild(next);
    footer.appendChild(note); footer.appendChild(nav); container.appendChild(footer);
    function resetRows() { nodes.forEach(function (node) { node.remove(); }); nodes.clear(); }
    function update() {
      var count = Math.max(0, Math.min(SECTION, filtered.length - page * SECTION));
      spacer.style.height = count * ROW + 'px'; viewport.style.height = Math.min(count * ROW, 560) + 'px';
      summary.textContent = filtered.length.toLocaleString() + ' / ' + entries.length.toLocaleString() + ' ' + l.files + ' · ' + size(totalBytes);
      empty.hidden = count > 0; empty.textContent = l.empty; note.textContent = filtered.length > SECTION ? l.section + ' ' + (page + 1) : l.local;
      nav.hidden = filtered.length <= SECTION; previous.disabled = page === 0; next.disabled = (page + 1) * SECTION >= filtered.length;
      updateSelection(); render();
    }
    function createRow(entry, index) {
      var row = el('div', 'file-row'); row.setAttribute('role', 'listitem'); row.setAttribute('aria-posinset', String(index + 1)); row.setAttribute('aria-setsize', String(filtered.length));
      row.style.position = 'absolute'; row.style.top = (index - page * SECTION) * ROW + 'px'; row.style.left = row.style.right = '0';
      if(options.onBatch){var check=el('input','file-select');check.type='checkbox';check.dataset.selectId=entry.id;check.checked=selected.has(entry.id);check.setAttribute('aria-label',l.selectFile+': '+entry.name);row.appendChild(check);}
      var symbol = el('span', 'file-symbol'); symbol.dataset.kind = entry.kind; symbol.appendChild(icon(entry.kind)); row.appendChild(symbol);
      var link = el('a', 'file-main'); link.href = options.downloadUrl(entry.id); link.title = entry.name; if (options.onDownload) link.dataset.downloadId = entry.id;
      link.appendChild(el('span', 'file-name', entry.name)); link.appendChild(el('span', 'file-meta', size(entry.file.size) + ' · ' + l[entry.kind])); row.appendChild(link);
      var actions = el('div', 'file-actions');
      if (entry.kind !== 'other') { var preview = el('button', 'icon-button'); preview.type = 'button'; preview.title = l.preview;
        preview.setAttribute('aria-label', l.preview + ': ' + entry.name); preview.dataset.previewId = entry.id; preview.appendChild(icon('preview')); actions.appendChild(preview); }
      var download = el('a', 'icon-button'); download.href = options.downloadUrl(entry.id); download.title = l.download; if (options.onDownload) download.dataset.downloadId = entry.id;
      download.setAttribute('aria-label', l.download + ': ' + entry.name); download.appendChild(icon('download')); actions.appendChild(download); row.appendChild(actions); return row;
    }
    function render() {
      scheduled = false; if (closed) return;
      var base = page * SECTION, start = base + Math.max(0, Math.floor(viewport.scrollTop / ROW) - 4);
      var end = Math.min(filtered.length, base + SECTION, start + Math.ceil((viewport.clientHeight || 560) / ROW) + 8);
      nodes.forEach(function (node, index) { if ((index < start || index >= end) && !node.contains(document.activeElement)) { node.remove(); nodes.delete(index); } });
      for (var i = start; i < end; i++) if (!nodes.has(i)) { var node = createRow(entries[filtered[i]], i); nodes.set(i, node); rows.appendChild(node); }
    }
    function schedule() { if (!scheduled && !closed) { scheduled = true; root.requestAnimationFrame(render); } }
    async function filter() {
      if (closed) return; var token = ++generation; note.textContent = l.indexing; container.setAttribute('aria-busy', 'true');
      var result = await filterIndex(entries, search.value, select.value, function () { return !closed && token === generation; });
      if (result === null || closed || token !== generation) return;
      filtered = result; page = 0; viewport.scrollTop = 0; resetRows(); container.setAttribute('aria-busy', 'false'); update();
    }
    search.oninput = function () { generation++; clearTimeout(filterTimer); filterTimer = setTimeout(filter, 100); };
    select.onchange = filter; viewport.onscroll = schedule;
    rows.onclick = function (event) {
      var button = event.target.closest('[data-preview-id]'); if (button && rows.contains(button)) options.onPreview(button.dataset.previewId, button);
      var check=event.target.closest('[data-select-id]');if(check){if(check.checked)selected.add(check.dataset.selectId);else selected.delete(check.dataset.selectId);updateSelection();return;}
      var download = event.target.closest('[data-download-id]');
      if (download && rows.contains(download) && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey && (!event.button || event.button === 0)) {
        if(options.onDownload(download.dataset.downloadId, download)!==false)event.preventDefault();
      }
    };
    previous.onclick = function () { if (page > 0) { page--; viewport.scrollTop = 0; resetRows(); update(); } };
    next.onclick = function () { if ((page + 1) * SECTION < filtered.length) { page++; viewport.scrollTop = 0; resetRows(); update(); } };
    root.addEventListener('resize', schedule);
    search.disabled = select.disabled = true;
    var ready = buildIndex(options.files, options.previewKind, function () { return !closed; }).then(async function (index) {
      if (!index || closed) return; entries = index.entries; totalBytes = index.totalBytes; selected.forEach(function(id){if(!Object.prototype.hasOwnProperty.call(options.files,id))selected.delete(id);});
      if (options.state) { search.value = options.state.query; select.value = options.state.type; }
      search.disabled = select.disabled = false; await filter();
      if (options.state && !closed) { page = Math.min(options.state.page, Math.max(0, Math.ceil(filtered.length / SECTION) - 1)); viewport.scrollTop = options.state.scrollTop; resetRows(); update(); }
    });
    return { ready: ready, setDestination:function(value){options.directoryMode=value;updateSelection();}, state: function () { return { query: search.value, type: select.value, page: page, scrollTop: viewport.scrollTop, selected:Array.from(selected) }; },
      close: function () { closed = true; generation++; clearTimeout(filterTimer); root.removeEventListener('resize', schedule); viewport.onscroll = rows.onclick = null; resetRows(); } };
  }
  var api = { setLocale: setLocale, apply: apply, localize: localize, translateStatus: translateStatus, pin: pin, mountFiles: mountFiles, buildIndex: buildIndex, filterIndex: filterIndex, defaults: defaults, icon: icon, backgroundInert: backgroundInert };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.LegnaWebUI = api;
  if (root.parent && root.parent !== root && /[?&]workspace=1(?:&|$)/.test(root.location.search)) {
    document.body.classList.add('workspace-embedded');
    root.addEventListener('message', function (event) {
      if (event.origin !== root.location.origin || event.source !== root.parent || !event.data) return;
      if (event.data.type === 'legna-locale') setLocale(event.data.locale);
    });
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
