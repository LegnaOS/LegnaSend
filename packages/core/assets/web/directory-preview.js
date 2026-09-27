(function (root) {
  'use strict';
  var extensions = {
    text: ['txt', 'log'], markdown: ['md', 'markdown'],
    img: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp'],
    video: ['mp4', 'm4v', 'mov', 'webm', 'ogv'],
    audio: ['mp3', 'm4a', 'wav', 'ogg', 'oga', 'opus', 'weba', 'flac', 'aac']
  };
  function kind(name) {
    var extension = String(name || '').split('.').pop().toLowerCase();
    if (String(name || '').indexOf('.') < 0) return null;
    return Object.keys(extensions).find(function (key) { return extensions[key].indexOf(extension) >= 0; }) || null;
  }
  function error(code, status) { var result = new Error(code); result.code = code; result.status = status; return result; }
  function metadata(response, file) {
    var length = response.headers.get('Content-Length'), tag = response.headers.get('ETag');
    var mime = (response.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
    if (response.status !== 200) throw error('failed', response.status);
    if (!/^\d+$/.test(length || '') || !Number.isSafeInteger(Number(length)) || Number(length) !== file.size) throw error('changed', 412);
    if (!/^"[a-f0-9]{64}"$/i.test(tag || '') || response.headers.get('Accept-Ranges') !== 'bytes') throw error('unsupported');
    var type = kind(file.name), allowed = type === 'markdown' || type === 'text' ? mime === 'text/plain' :
      type === 'img' ? /^image\/(png|jpeg|gif|webp|avif|bmp)$/.test(mime) :
      type === 'video' ? /^video\/(mp4|webm|ogg|quicktime)$/.test(mime) :
      type === 'audio' && /^audio\/(mpeg|mp4|wav|x-wav|ogg|webm|flac|aac)$/.test(mime);
    if (!allowed) throw error('unsupported');
    return {tag: tag, mime: mime, kind: type};
  }
  function pinnedUrl(url, tag, base) {
    var parsed = new URL(url, base);
    if (parsed.origin !== new URL(base).origin || !/^"[a-f0-9]{64}"$/i.test(tag)) throw error('unsupported');
    parsed.searchParams.set('preview', '1'); parsed.searchParams.set('version', tag);
    return parsed.pathname + parsed.search;
  }
  // A document preview leases one already-open descriptor. This is deliberately
  // separate from its ordinary download URL and never buffers the source file.
  function documentLease(options) {
    var source = new URL(options.url, options.base), base = new URL(options.base);
    var match = source.pathname.match(/^(\/api\/legnasend\/v1\/workspaces\/[^/]+)\/files\/[^/]+\/content$/);
    var generation = source.searchParams.get('generation');
    if (source.origin !== base.origin || !match || !/^\d+$/.test(generation || '') || !options.file || typeof options.file.id !== 'string') throw error('unsupported');
    var endpoint = match[1], closed = false, lease = null, released = false, pending = null;
    function post(operation, value, signal, keepalive) {
      return options.fetch(endpoint + '/' + operation + '?generation=' + encodeURIComponent(generation), {
        method:'POST', credentials:'same-origin', cache:'no-store', redirect:'error',
        headers:{'Content-Type':'application/json'}, body:JSON.stringify(value), signal:signal, keepalive:keepalive === true
      });
    }
    function release() {
      if (!lease || released) return Promise.resolve();
      released = true;
      var controller=new AbortController(),timer=setTimeout(function(){controller.abort();},2000);
      return post('close-preview', {lease:lease}, controller.signal, true).then(function(response){
        if(response.body) return response.body.cancel().catch(function(){});
      }).catch(function(){}).finally(function(){clearTimeout(timer);});
    }
    function close() { closed = true; return release(); }
    async function json(response) {
      if (!response.ok) { if(response.body)response.body.cancel().catch(function(){});throw error('failed',response.status); }
      var reader=response.body&&response.body.getReader?response.body.getReader():null;
      if(!reader)throw error('unsupported');
      var chunks=[],length=0;
      try {
        while(true){var part=await reader.read();if(part.done)break;length+=part.value.length;if(length>8192)throw error('unsupported');chunks.push(part.value);}
      } catch(issue){await reader.cancel().catch(function(){});throw issue;} finally {reader.releaseLock();}
      var bytes=new Uint8Array(length),offset=0;chunks.forEach(function(chunk){bytes.set(chunk,offset);offset+=chunk.length;});
      return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
    }
    function prepare() {
      if(closed)return Promise.reject(error('closed'));
      if(pending)return pending;
      pending=(async function(){
        var controller=new AbortController(),timer=setTimeout(function(){controller.abort();},options.timeout||12000);
        try {
          // Do not abort solely because the dialog closes: consume the bounded
          // response and immediately return a late lease instead of leaking it.
          var value=await json(await post('prepare-preview',{id:options.file.id},controller.signal,false));
          if(!value||typeof value.lease!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value.lease))throw error('unsupported');
          lease=value.lease;
          if(closed){await release();throw error('closed');}
          var url=new URL(value.url,base);
          if(typeof value.url!=='string'||url.origin!==source.origin||url.pathname!==source.pathname||
            url.searchParams.get('generation')!==generation||url.searchParams.get('lease')!==lease||url.searchParams.get('preview')!=='1'||
            !Number.isSafeInteger(value.size)||value.size<0||!/^"[a-f0-9]{64}"$/i.test(value.etag||'')||typeof value.mime!=='string'||value.mime.length>256)throw error('unsupported');
          return {url:url.pathname+url.search,size:value.size,tag:value.etag,mime:value.mime,lease:lease};
        } catch(issue){await release();throw issue;} finally {clearTimeout(timer);}
      })();
      return pending;
    }
    return {prepare:prepare,close:close};
  }
  function invalidMessage(language, removed) {
    if(language==='zh-CN')return removed?'文件已删除或共享已关闭。预览已停止，可重试检查是否恢复。':'文件已更新，旧预览已停止。点击重试载入新版本。';
    if(language==='zh-TW'||language==='zh-HK')return removed?'檔案已刪除或分享已關閉。預覽已停止，可重試檢查是否恢復。':'檔案已更新，舊預覽已停止。點擊重試載入新版本。';
    return removed?'The file was removed or sharing ended. Preview stopped; retry to check availability.':'The file changed. The old preview stopped; retry to load the new version.';
  }
  function create(options) {
    var doc = root.document, $ = function (id) { return doc.getElementById('directory-preview' + (id ? '-' + id : '')); };
    var dialog = $(''), content = $('content'), status = $('status'), current = null, restoreFocus = null;
    function live(op) { return current === op && !op.halted; }
    function release(op) {
      op.halted = true; clearTimeout(op.timer);
      if (op.documentLease) { op.documentLease.close(); op.documentLease = null; }
      if (op.controller) op.controller.abort();
      if (op.imageView) { op.imageView.close(); op.imageView = null; }
      if (op.reader) { op.reader.close(); op.reader = null; }
      if (op.mediaController) { op.mediaController.close(); op.mediaController = null; op.media = null; }
      if (op.media) {
        op.media.onload = op.media.onloadedmetadata = op.media.onerror = null;
        if (op.media.pause) op.media.pause();
        op.media.removeAttribute('src');
        if (op.media.load) op.media.load();
        op.media = null;
      }
      content.replaceChildren();
    }
    function close() {
      var previous = current; current = null;
      if (previous) release(previous);
      $('download').removeAttribute('href'); $('download').removeAttribute('download'); $('download').onclick=null;
      $('title').textContent = status.textContent = ''; $('retry').hidden = true;
      if (dialog.open) dialog.close();
      if (restoreFocus && restoreFocus.isConnected) restoreFocus.focus();
      restoreFocus = null;
    }
    function failed(op, issue) {
      if (!live(op)) return;
      if ([401, 404, 409, 410, 412].indexOf(issue.status) >= 0) {
        if(issue.status===401){close();options.onInvalid(issue.status);return;}
        release(op);op.invalid=true;op.invalidStatus=issue.status;
        status.textContent=invalidMessage(op.language,issue.status===404||issue.status===410);
        $('retry').hidden=false;$('download').removeAttribute('href');$('download').onclick=function(event){event.preventDefault();};
        if(options.onChanged)options.onChanged(issue.status);
        return;
      }
      release(op);
      status.textContent = issue.code === 'image-budget' ? op.labels.webUi.imageBudgetExceeded : issue.code === 'image-inspect' ? op.labels.webUi.imageInspectUnsupported : issue.code === 'unsupported' ? op.labels.previewUnsupported : op.labels.previewError;
      $('retry').hidden = ['unsupported','image-budget','image-inspect'].indexOf(issue.code)>=0;
    }
    async function guardedFetch(op, url, init) {
      if (!live(op)) throw error('closed');
      try {
        // Keep the reader's AbortSignal attached for the entire response body.
        var response = await root.fetch(url, Object.assign({}, init, {credentials: 'same-origin', cache: 'no-store', redirect: 'error'}));
        if (!live(op)) { if (response.body) response.body.cancel().catch(function () {}); throw error('closed'); }
        if (!response.ok) { if (response.body) response.body.cancel().catch(function () {}); throw error('failed', response.status); }
        return response;
      } catch (issue) {
        // Reader-local cancellation (encoding/search changes) is not revocation.
        if (live(op) && !(init.signal && init.signal.aborted)) failed(op, issue);
        throw issue;
      }
    }
    async function head(op, url) {
      var controller = op.controller = new AbortController();
      var deadline = setTimeout(function () { controller.abort(); }, 5000);
      try { return await guardedFetch(op, url, {method: 'HEAD', signal: controller.signal}); }
      finally { clearTimeout(deadline); if (op.controller === controller) op.controller = null; }
    }
    async function check() {
      var op = current;
      if (!op || !live(op) || !op.pinned || op.checking || doc.hidden) return;
      clearTimeout(op.timer); op.checking = true;
      try { metadata(await head(op, op.pinned), op.file); }
      catch (issue) { failed(op, issue); }
      finally { op.checking = false; if (live(op)) op.timer = setTimeout(check, 3000); }
    }
    async function open(file, url, language, refreshSize, mode) {
      close();
      var labels = root.LegnaWebLocales[language] || root.LegnaWebLocales.en;
      var op = current = {file: file, url: url, language: language, labels: labels, halted: false, refreshSize:refreshSize===true, mode:mode||{}, documents:!!(mode&&mode.documents)};
      restoreFocus = doc.activeElement;
      $('title').textContent = file.name;
      if (root.LegnaPreviewSupport) root.LegnaPreviewSupport.mount($('support'), labels.webUi);
      $('close').textContent = labels.closePreview;
      $('download').textContent = labels.downloadOriginal;
      $('download').href = url; $('download').download = file.name;
      $('download').onclick = function(event){if(!event.ctrlKey&&!event.metaKey&&!event.shiftKey&&!event.altKey&&options.onDownload&&options.onDownload(file))event.preventDefault();};
      $('retry').textContent = labels.webUi.retry;
      var type = kind(file.name);
      $('kind').textContent = type === 'markdown' ? 'Markdown' : labels.webUi[type === 'img' ? 'image' : type === 'text' ? 'text' : type] || labels.preview;
      status.textContent = labels.previewLoading; dialog.showModal(); $('close').focus();
      try {
        if (!type) throw error('unsupported');
        var previewUrl = new URL(url, root.location.href);
        if (previewUrl.origin !== root.location.origin) throw error('unsupported');
        previewUrl.searchParams.set('preview', '1');
        var leased=null;
        if(op.documents){
          op.documentLease=documentLease({url:url,base:root.location.href,file:file,fetch:root.fetch.bind(root)});
          leased=await op.documentLease.prepare();
          if(!live(op))return;
          previewUrl=new URL(leased.url,root.location.href);
          file=op.file=Object.assign({},file,{size:leased.size});
        }
        var response=await head(op, previewUrl.pathname + previewUrl.search);
        // Every explicit retry acquires a fresh size/version before mounting a
        // new reader; no byte/search/decoder state survives the old operation.
        if(op.refreshSize){var size=response.headers.get('Content-Length');if(!/^\d+$/.test(size||'')||!Number.isSafeInteger(Number(size)))throw error('unsupported');file=op.file=Object.assign({},file,{size:Number(size)});}
        var info = metadata(response, file);
        if (!live(op)) return;
        if(leased&&(leased.tag!==info.tag||leased.mime.split(';')[0].trim().toLowerCase()!==info.mime))throw error('changed',412);
        op.pinned = pinnedUrl(leased?leased.url:url, info.tag, root.location.href);
        if(!op.documents){
          var original = new URL(op.pinned, root.location.href); original.searchParams.set('preview', '0');
          $('download').href = original.pathname + original.search;
        }
        // A lease is preview-only. Original download keeps the ordinary URL.
        if (type === 'text' || type === 'markdown') {
          op.reader = root.LegnaTextPreview.mount({container: content, status: status, url: op.pinned, size: file.size,
            markdown: type === 'markdown', labels: Object.assign({}, labels.webUi, labels.textPreview), compact: true,
            fetch: function (source, init) { return guardedFetch(op, source, init); }});
        } else {
          var media = op.media = doc.createElement(type);
          if (type !== 'img') {
            if (!media.canPlayType(info.mime)) throw error('unsupported');
            media.controls = true; media.preload = 'metadata'; media.setAttribute('playsinline', '');
            media.onloadedmetadata = function () { if (live(op)) status.textContent = ''; };
          } else {
            media.alt = file.name;
            media.onload = function () {
              if (op.imageView) op.imageView.ready.then(function () { if (live(op)) status.textContent = ''; }, function () { failed(op, error('failed')); });
              else if (live(op)) status.textContent = '';
            };
          }
          media.onerror = function () { failed(op, error('failed')); };
          if (type === 'img' && root.LegnaImagePreview) op.imageView = root.LegnaImagePreview.mount({container: content, image: media, labels: labels});
          else if (type !== 'img' && root.LegnaMediaPreview) op.mediaController = root.LegnaMediaPreview.mount({container: content, media: media, url: op.pinned, labels: labels.webUi,
            onElement:function(next){op.media=next;},onReady:function(){if(live(op))status.textContent='';},onError:function(issue){failed(op,issue);}});
          else content.appendChild(media);
          if(type==='img'&&!root.LegnaImageSource)throw error('image-inspect');
          if(type==='img'&&root.LegnaImageSource){
            var imageController=op.controller=new AbortController();
            var inspected=await root.LegnaImageSource.inspect(op.pinned,{size:file.size,signal:imageController.signal,fetch:function(url,init){return guardedFetch(op,url,init);}});
            if(!live(op))return;op.controller=null;media.src=inspected.url;
          }else if (!op.mediaController) media.src = op.pinned;
        }
        if (live(op)) op.timer = setTimeout(check, 3000);
      } catch (issue) { failed(op, issue); }
    }
    $('close').onclick = close;
    $('retry').onclick = function () { if(!current)return;if(current.invalidStatus===409||current.invalidStatus===410){var code=current.invalidStatus;close();options.onInvalid(code);return;}open(current.file, current.url, current.language, true, current.mode); };
    dialog.addEventListener('cancel', function (event) { event.preventDefault(); close(); });
    dialog.addEventListener('keydown', function (event) {
      if (!event.defaultPrevented && (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') {
        var query = content.querySelector('.text-query');
        if (query && !query.disabled) { event.preventDefault(); query.focus(); query.select(); }
      }
    });
    dialog.addEventListener('click', function (event) { if (event.target === dialog) {
      var box = dialog.getBoundingClientRect();
      if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) close();
    } });
    // Hidden documents may have their timers suspended. Drop cached previews
    // rather than displaying an old protected document when the page resumes.
    doc.addEventListener('visibilitychange', function () { if (doc.hidden) close(); else check(); });
    root.addEventListener('focus', check); root.addEventListener('online',function(){if(current&&!current.invalid&&current.halted)open(current.file,current.url,current.language,true,current.mode);else check();});root.addEventListener('pagehide', close);
    return {open: open, close: close};
  }
  var api = {kind: kind, metadata: metadata, pinnedUrl: pinnedUrl, documentLease: documentLease, create: create};
  if (typeof module === 'object') module.exports = api;
  root.LegnaDirectoryPreview = api;
})(typeof window === 'object' ? window : globalThis);
