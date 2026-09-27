(function (root) {
  'use strict';
  var messages = {
    en: {contentRevision:'Content R',contentPending:'Update pending verification',contentHint:'Observed metadata revision, not a whole-folder hash. File downloads still verify their own versions.',anchorLost:'The previous position is no longer available within the refresh budget. Use Refresh to browse from the start.',searching:'Searching this directory…',filterLabel:'Search file and folder names',filterHint:'Current directory only · literal name matches · results load in pages',filterClear:'Clear search',filterMore:'Continue searching',noMatches:'No matching names in this directory.',matches:'matches loaded',uploadAllowed:'Uploads allowed',updates:'Updates available · reload',previous:'Previous entries',start:'Browse from start',preview:'Preview',"locked":"Password required","unlock":"Unlock","logout":"Lock workspace","password":"Workspace password or PIN","cancel":"Cancel","wrongPassword":"Incorrect password. Try again.","rateLimited":"Too many attempts. Wait one minute and try again.","authHint":"The password controls access. It does not encrypt saved files.","httpPassword":"HTTP does not protect the password in transit. HTTPS transport is configured in the host app.","unlocking":"Verifying…",title:'Workspaces',refresh:'Refresh',readOnly:'Read only',empty:'No visible workspaces are open.',loading:'Loading…',failed:'The workspace or directory is unavailable. Refresh to try again.',changed:'The directory changed or the page expired. Refresh to reload the list.',files:'items loaded',more:'Load more',up:'Parent directory',temporary:'Temporary sharing',temporaryHint:'Existing bidirectional file sharing',open:'Open workspace',http:'HTTP · no TLS',https:'HTTPS · TLS',end:'All entries loaded.'},
    'zh-CN': {contentRevision:'内容 R',contentPending:'更新待核验',contentHint:'已观察到的元数据代次，不是整个目录的内容哈希；下载仍按每个文件的版本核验。',anchorLost:'在刷新预算内未找到原位置。请点击刷新，从头浏览。',searching:'正在搜索当前目录…',filterLabel:'搜索文件和文件夹名称',filterHint:'仅当前目录 · 名称字面匹配 · 结果分页加载',filterClear:'清除搜索',filterMore:'继续搜索',noMatches:'当前目录中没有匹配的名称。',matches:'项匹配已加载',uploadAllowed:'允许上传',updates:'列表有更新 · 重新加载',previous:'上一段条目',start:'从头浏览',preview:'预览',"locked":"需要密码","unlock":"解锁","logout":"锁定工作区","password":"工作区密码或 PIN","cancel":"取消","wrongPassword":"密码不正确，请重试。","rateLimited":"尝试过于频繁，请等待一分钟后重试。","authHint":"密码控制访问权限，不加密保存的文件。","httpPassword":"HTTP 不保护传输中的密码，HTTPS 传输在发送端应用设置。","unlocking":"正在验证…",title:'工作区',refresh:'刷新',readOnly:'只读共享',empty:'暂无已开启的可见工作区。',loading:'正在加载…',failed:'工作区或目录暂不可用，请刷新重试。',changed:'目录已变化或分页已过期，请刷新列表。',files:'项已加载',more:'加载更多',up:'上级目录',temporary:'临时共享',temporaryHint:'现有双向文件共享',open:'打开工作区',http:'HTTP · 未使用 TLS',https:'HTTPS · TLS',end:'已加载全部条目。'},
    'zh-TW': {contentRevision:'內容 R',contentPending:'更新待核驗',contentHint:'已觀察到的中繼資料代次，不是整個目錄的內容雜湊；下載仍按每個檔案的版本核驗。',anchorLost:'在重新整理預算內找不到原位置。請點擊重新整理，從頭瀏覽。',searching:'正在搜尋目前目錄…',filterLabel:'搜尋檔案與資料夾名稱',filterHint:'僅目前目錄 · 名稱字面比對 · 結果分頁載入',filterClear:'清除搜尋',filterMore:'繼續搜尋',noMatches:'目前目錄中沒有符合的名稱。',matches:'項符合已載入',uploadAllowed:'允許上傳',updates:'清單有更新 · 重新載入',previous:'上一段項目',start:'從頭瀏覽',preview:'預覽',"locked":"需要密碼","unlock":"解鎖","logout":"鎖定工作區","password":"工作區密碼或 PIN","cancel":"取消","wrongPassword":"密碼不正確，請重試。","rateLimited":"嘗試過於頻繁，請等待一分鐘後重試。","authHint":"密碼控制存取權限，不加密儲存的檔案。","httpPassword":"HTTP 不保護傳輸中的密碼，HTTPS 傳輸在傳送端應用設定。","unlocking":"正在驗證…",title:'工作區',refresh:'重新整理',readOnly:'唯讀分享',empty:'暫無已開啟的可見工作區。',loading:'正在載入…',failed:'工作區或目錄暫不可用，請重新整理後重試。',changed:'目錄已變更或分頁已過期，請重新整理列表。',files:'項已載入',more:'載入更多',up:'上層目錄',temporary:'臨時分享',temporaryHint:'既有雙向檔案分享',open:'開啟工作區',http:'HTTP · 未使用 TLS',https:'HTTPS · TLS',end:'已載入全部項目。'}
  };
  Object.assign(messages.en,{selectLoaded:'Select loaded (up to 128)',clearSelection:'Clear selection',downloadSelection:'Download selected ZIP',selected:'selected',selectionLimit:'Selection limit reached or encoded paths are too long.',browserDownload:'Download handed to your browser.',selectItem:'Select',selectionHint:'Selection applies to this folder and clears on refresh or navigation.'});
  Object.assign(messages['zh-CN'],{selectLoaded:'选择已加载（最多128项）',clearSelection:'清除选择',downloadSelection:'下载所选 ZIP',selected:'项已选择',selectionLimit:'已达选择上限，或所选路径过长。',browserDownload:'已交给浏览器下载。',selectItem:'选择',selectionHint:'选择仅限当前目录，刷新或切换目录后清空。'});
  Object.assign(messages['zh-TW'],{selectLoaded:'選擇已載入（最多128項）',clearSelection:'清除選擇',downloadSelection:'下載所選 ZIP',selected:'項已選擇',selectionLimit:'已達選擇上限，或所選路徑過長。',browserDownload:'已交給瀏覽器下載。',selectItem:'選擇',selectionHint:'選擇僅限目前目錄，重新整理或切換目錄後清空。'});
  Object.assign(messages.en,{selectLoadedLarge:'Select loaded',selectionHintLarge:'Selections persist across visited pages in this folder (20,000 items / 2 MiB metadata). Refresh or navigation to another folder clears them.',selectionLimitLarge:'Selection reached 20,000 items or the 2 MiB metadata limit.',archivePreparing:'Preparing selected ZIP…',archiveCancelPrepare:'Cancel preparation',archiveCancelDownload:'Cancel latest browser ZIP',archiveCancelled:'Preparation cancelled.',archiveDownloadCancelled:'Cancellation requested for this ZIP only.',archiveFailed:'ZIP preparation failed. Retry or refresh the list.',archiveExpired:'The selection expired or changed. Refresh and select again.',archiveBusy:'Up to four ZIP preparations or downloads can be active. Wait or cancel one.',archiveTimeout:'Preparation timed out. No download was started; retry when the connection recovers.',archiveCancelFailed:'Cancellation was not confirmed. Retry or use your browser download controls.'});
  Object.assign(messages['zh-CN'],{selectLoadedLarge:'选择已加载',selectionHintLarge:'可跨当前目录已访问分页保留选择，最多20,000项或2 MiB元数据；刷新或切换目录会清空。',selectionLimitLarge:'已达20,000项或2 MiB元数据上限。',archivePreparing:'正在准备所选 ZIP…',archiveCancelPrepare:'取消准备',archiveCancelDownload:'取消最近的浏览器 ZIP',archiveCancelled:'已取消准备。',archiveDownloadCancelled:'仅对此 ZIP 请求取消。',archiveFailed:'ZIP准备失败，请重试或刷新列表。',archiveExpired:'选择已过期或内容已变化，请刷新后重新选择。',archiveBusy:'最多同时准备或下载4个ZIP，请稍候或取消其中一个。',archiveTimeout:'准备超时，尚未启动下载；网络恢复后可重试。',archiveCancelFailed:'尚未确认取消，请重试或使用浏览器下载管理。'});
  Object.assign(messages['zh-TW'],{selectLoadedLarge:'選擇已載入',selectionHintLarge:'可跨目前目錄已瀏覽分頁保留選擇，最多20,000項或2 MiB中繼資料；重新整理或切換目錄會清空。',selectionLimitLarge:'已達20,000項或2 MiB中繼資料上限。',archivePreparing:'正在準備所選 ZIP…',archiveCancelPrepare:'取消準備',archiveCancelDownload:'取消最近的瀏覽器 ZIP',archiveCancelled:'已取消準備。',archiveDownloadCancelled:'僅對此 ZIP 請求取消。',archiveFailed:'ZIP準備失敗，請重試或重新整理清單。',archiveExpired:'選擇已過期或內容已變更，請重新整理後再選擇。',archiveBusy:'最多同時準備或下載4個ZIP，請稍候或取消其中一個。',archiveTimeout:'準備逾時，尚未啟動下載；網絡恢復後可重試。',archiveCancelFailed:'尚未確認取消，請重試或使用瀏覽器下載管理。'});
  messages['zh-HK'] = messages['zh-TW'];
  function locale(value) { return /^zh/i.test(value) ? (/HK/i.test(value) ? 'zh-HK' : /TW|Hant/i.test(value) ? 'zh-TW' : 'zh-CN') : 'en'; }
  function filePath(path, name) { return path ? path + '/' + name : name; }
  function preparedArchiveCapability(workspace){return !!(workspace&&workspace.capabilities&&workspace.capabilities.archiveSelection===true);}
  function workspaceCapability(workspace,name){return !!workspace&&(workspace.backend==='documents'?!!workspace.capabilities&&workspace.capabilities[name]===true:!workspace.capabilities||workspace.capabilities[name]!==false);}
  function documentTrailFor(trail,path,label,fallback){if(!path)return [];var found=trail.findIndex(function(item){return item.path===path;});return found>=0?trail.slice(0,found+1):trail.concat([{path:path,name:label||fallback}]);}
  function documentRevision(previous,state){
    if(!state||state.refreshFromStart!==true||typeof state.stamp!=='string'||!state.stamp.length||state.stamp.length>256||typeof state.observing!=='boolean')throw new Error('Invalid provider notification');
    return {stamp:state.stamp,changed:previous!==null&&previous!==state.stamp,observing:state.observing};
  }
  function archiveSelectionUrl(route,generation,path,ids){
    if(!Number.isSafeInteger(generation)||generation<1||typeof path!=='string'||!Array.isArray(ids)||ids.length>128||new Set(ids).size!==ids.length||ids.some(function(id){return typeof id!=='string'||!id.length;}))throw new Error('selection-limit');
    var query='generation='+generation+'&path='+encodeURIComponent(path);
    if(ids.length)query+='&ids='+encodeURIComponent(JSON.stringify(ids));
    if(query.length>7800)throw new Error('selection-limit');
    return route+'/archive?'+query;
  }
  function Selection(){this.items=new Map();}
  Selection.prototype.clear=function(){this.items.clear();};
  Selection.prototype.toggle=function(item,selected,validate){
    if(!selected){this.items.delete(item.id);return true;}
    if(item.downloadable===false&&!item.directory)return false;
    var ids=Array.from(this.items.keys());if(!this.items.has(item.id))ids.push(item.id);
    if(ids.length>128)return false;
    try{validate(ids);}catch(_){return false;}
    this.items.set(item.id,{id:item.id,name:item.name,directory:item.directory});return true;
  };
  if (typeof module === 'object') module.exports = {locale:locale, filePath:filePath, messages:messages,documentRevision:documentRevision,Selection:Selection,archiveSelectionUrl:archiveSelectionUrl,workspaceCapability:workspaceCapability,preparedArchiveCapability:preparedArchiveCapability,documentTrailFor:documentTrailFor};
  if (!root.document) return;
  var doc=root.document, $=function(id){return doc.getElementById(id);}, language=locale(root.navigator.language), text;
  try { language=locale(root.localStorage.getItem('legnasend-directory-language') || language); } catch (_) {}
  var filterValue='',filterTimer=0,selection=new Selection(),selectionMessage='',archiveController=null,archiveCancelling=false;
  function preparedArchive(){return !!(root.LegnaDirectoryArchiveSelection&&preparedArchiveCapability(workspace));}
  function abandonArchive(){var old=archiveController;archiveController=null;archiveCancelling=false;if(old)old.close();}
  function archivePreparing(){return !!(archiveController&&archiveController.snapshot().preparing);}
  var workspace=null, directory='', items=[], cursor=null, finished=false, loading=false, epoch=0, controller=null, indexData=null;
  var uploads=null,uploadRefresh=0,downloads=null, policy=root.LegnaDirectoryWindow, windowState=new policy.Window();
  var stamp=null, dirty=false, silentAuth=false, probeTimer=0, probeController=null, unchanged=0, failures=0, latency=250, pageActive=true;
  var eventWatch=root.LegnaDirectoryEvents?new root.LegnaDirectoryEvents.Watch({EventSource:root.EventSource,setTimeout:root.setTimeout.bind(root),clearTimeout:root.clearTimeout.bind(root),onChange:function(){if(foreground()&&workspace&&!loading&&!dirty)invalidate();},onFallback:function(){scheduleProbe(true);}}):null;
  function stopEvents(){if(eventWatch)eventWatch.stop();}
  function watchEvents(){if(eventWatch&&capability('events')&&foreground()&&workspace&&stamp&&!loading&&!authBusy&&!$('auth').open&&$('unlock').hidden)eventWatch.start(routeUrl()+'/events?generation='+workspace.generation+'&path='+encodeURIComponent(directory));}
  var documentTrail=[],documentScope=null,documentWatchStamp=null;
  function documents(){return !!workspace&&workspace.backend==='documents';}
  function capability(name){return workspaceCapability(workspace,name);}
  var lastScroll=0, lastScrollAt=0, lastPrefetch=0, fillCount=0, fillTimer=0;
  var viewport=$('viewport'), rowHeight=52, frame=0, staleRetry=0, statusKey='', authBusy=false, authController=null, authEpoch=0, authError='';
  function node(tag, cls, value){var element=doc.createElement(tag); if(cls)element.className=cls;if(value!==undefined)element.textContent=value;return element;}
  function status(key){statusKey=key;$('status').textContent=key?text[key]:'';}
  function contentLabel(){
    var tag=$('content-state');if(!tag)return;
    var visible=!!(workspace&&typeof workspace.contentKnowledge==='string');tag.hidden=!visible;
    if(!visible){tag.textContent='';tag.removeAttribute('title');return;}
    var confirmed=workspace.contentKnowledge==='observed'&&!workspace.dirty&&typeof workspace.contentEpoch==='string';
    tag.textContent=confirmed?text.contentRevision+workspace.contentRevision:text.contentPending;
    tag.title=text.contentHint;
  }
  function contentSnapshot(value){
    if(!workspace||!value||!Number.isSafeInteger(value.contentRevision)||value.contentRevision<0||
      (value.contentEpoch!==null&&typeof value.contentEpoch!=='string')||
      ['unknown','observed'].indexOf(value.contentKnowledge)===-1||typeof value.dirty!=='boolean'||
      (value.lastObservedAt!==null&&(!Number.isSafeInteger(value.lastObservedAt)||value.lastObservedAt<0)))return;
    ['contentEpoch','contentRevision','contentKnowledge','lastObservedAt','dirty'].forEach(function(key){workspace[key]=value[key];});
    contentLabel();
  }
  function labels(){text=messages[language];$('directory-filter-form').hidden=!workspace;$('directory-filter-label').textContent=text.filterLabel;$('directory-filter').placeholder=text.filterLabel;$('directory-filter-hint').textContent=text.filterHint;$('directory-filter-clear').textContent=text.filterClear;$('directory-filter-clear').disabled=!filterValue;doc.documentElement.lang=language;$('language').value=language;$('refresh').textContent=text.refresh;$('more').textContent=filterValue?text.filterMore:text.more;$('mode').textContent=workspace&&workspace.allowUpload===true?text.uploadAllowed:text.readOnly;$('transport').textContent=root.location.protocol==='https:'?text.https:text.http;$('title').textContent=workspace?workspace.name:text.title;viewport.setAttribute('aria-label',text.title);$('count').textContent=workspace?countLabel():'';$('previous').textContent=text.previous;$('start').textContent=text.start;$('updates').textContent=text.updates;var up=$('path').querySelector('button');if(up)up.textContent=text.up;status(statusKey);authLabels();selectionControls();contentLabel();if(uploads)uploads.setLocale(language);}
  function routeUrl(){return '/api/legnasend/v1/workspaces/'+encodeURIComponent(workspace.id);}
  function countLabel(){return (windowState.offset?(windowState.offset+1)+'–'+(windowState.offset+items.length):items.length)+' '+(filterValue?text.matches:text.files);}
  function stopProbe(){if(probeTimer)root.clearTimeout(probeTimer);probeTimer=0;if(probeController)probeController.abort();probeController=null;}
  function foreground(){return pageActive&&!doc.hidden&&root.navigator.onLine!==false;}
  function scheduleProbe(immediate){
    if(probeTimer)root.clearTimeout(probeTimer);probeTimer=0;
    if(!foreground()||loading||authBusy||$('auth').open||workspace&&!$('unlock').hidden)return;
    watchEvents();
    probeTimer=root.setTimeout(probe,immediate?0:documents()?Math.min(15000,policy.delay(unchanged,latency,failures)):policy.delay(unchanged,latency,failures));
  }
  async function get(url, signal){
    var request=new AbortController(), timed=false;
    function abort(){request.abort();}
    if(signal){if(signal.aborted)request.abort();else signal.addEventListener('abort',abort,{once:true});}
    var timer=root.setTimeout(function(){timed=true;request.abort();},10000);
    try{var response=await root.fetch(url,{credentials:'same-origin',cache:'no-store',signal:request.signal});if(!response.ok){var error=new Error(String(response.status));error.status=response.status;throw error;}return await response.json();}
    catch(error){if(timed)throw new Error('Directory request timed out');throw error;}
    finally{root.clearTimeout(timer);if(signal)signal.removeEventListener('abort',abort);}
  }
  function reset(keepSelection){documentWatchStamp=null;abandonArchive();if(!keepSelection)selection=preparedArchive()?new root.LegnaDirectoryArchiveSelection.Selection(directory):new Selection();selectionMessage='';refreshBlocked=false;if(refreshController)refreshController.abort();refreshController=null;if(filterTimer)root.clearTimeout(filterTimer);filterTimer=0;if(fillTimer)root.clearTimeout(fillTimer);fillTimer=0;fillCount=0;preview.close();stopEvents();stopProbe();epoch++;if(controller)controller.abort();controller=new AbortController();loading=false;cursor=null;finished=false;items=[];windowState.reset();stamp=null;dirty=false;silentAuth=false;unchanged=0;failures=0;lastScroll=0;lastScrollAt=0;viewport.scrollTop=0;$('rows').replaceChildren();$('spacer').style.height='0px';$('more').hidden=true;$('more').disabled=false;$('previous').hidden=true;$('start').hidden=true;$('updates').hidden=true;selectionControls();return epoch;}
  var refreshController=null,refreshBlocked=false;
  async function refreshWindow(){
    if(!workspace||loading||refreshController||refreshBlocked||!foreground())return;
    abandonArchive();stopProbe();loading=true;selectionControls();
    var own=refreshController=new AbortController(),active=epoch,began=Date.now();
    var top=Math.min(items.length-1,Math.max(0,Math.floor(viewport.scrollTop/rowHeight))),within=viewport.scrollTop%rowHeight;
    var visible=items.slice(Math.max(0,top),Math.max(0,top)+32),focus=doc.activeElement,row=focus&&focus.closest('.row'),focusId=row&&row.dataset.id,focusClass=focus&&focus.className;
    try{
      var anchor=null;
      if(!documents()&&capability('state')&&(top>0||windowState.offset)){
        var ids=policy.probeIds(visible,0,visible.length,Math.max(0,7800-encodeURIComponent(directory).length));
        var state=await get(routeUrl()+'/state?generation='+workspace.generation+'&path='+encodeURIComponent(directory)+(documents()?'':'&ids='+encodeURIComponent(ids.join(','))),own.signal);
        var available=new Set(state.entries.map(function(entry){return entry.id;}));
        anchor=visible.find(function(entry){return available.has(entry.id);});
        if(!anchor){refreshBlocked=true;status('anchorLost');$('start').hidden=false;return;}
      }
      var token=null,page,steps=0;
      do{
        if(active!==epoch||!foreground())return;
        var url=routeUrl()+'/files?generation='+workspace.generation+'&path='+encodeURIComponent(directory)+(filterValue?'&filter='+encodeURIComponent(filterValue):'')+(token?'&cursor='+encodeURIComponent(token):anchor?'&anchor='+encodeURIComponent(anchor.id):'');
        page=await get(url,own.signal);token=page.cursor;
        if(page.generation!==workspace.generation||page.path!==directory||(page.filter||'')!==filterValue)throw new Error('Stale refresh');
        if(page.anchorMissing||++steps>65){refreshBlocked=true;status('anchorLost');$('start').hidden=false;return;}
      }while(page.anchorPending&&token);
      if(active!==epoch)return;
      selection.clear();selectionMessage='';windowState.reset(page.offset||0);windowState.append(page,null);items=windowState.items();cursor=page.cursor;stamp=page.stamp;finished=!cursor;dirty=false;
      viewport.scrollTop=0;draw();viewport.scrollTop=anchor?within:0;
      if(focusId){var restored=Array.from($('rows').children).find(function(entry){return entry.dataset.id===focusId;});if(restored){var control=Array.from(restored.children).find(function(entry){return entry.className===focusClass;});if(control)control.focus({preventScroll:true});}}
      $('updates').hidden=true;$('more').hidden=finished;status(finished?'end':'');uploadContext();
    }catch(error){
      if(active!==epoch||error.name==='AbortError')return;
      if(error.status===401)lock(false);else status(error.status===409||error.status===410?'changed':'failed');
    }finally{
      if(refreshController===own){refreshController=null;loading=false;selectionControls();latency=latency*.7+(Date.now()-began)*.3;scheduleProbe(false);}
    }
  }
  function invalidate(){
    abandonArchive();dirty=true;selectionControls();$('updates').hidden=false;$('more').hidden=true;status(refreshBlocked?'anchorLost':'changed');
    // Reposition by the actual visible entry through a bounded server scan.
    // Keep the existing view until the replacement window is fully validated.
    refreshWindow();
  }
  async function probe(){
    probeTimer=0;if(!foreground()||loading||refreshController||probeController||authBusy||$('auth').open)return;
    var own=new AbortController(),active=epoch,began=Date.now(),checkingDirectory=false;probeController=own;
    try{
      if(!workspace){
        if(root.location.pathname.split('/').filter(Boolean)[0]){load(true);return;}
        var updated=await get('/api/legnasend/v1/workspaces',own.signal);
        if(active!==epoch||probeController!==own)return;
        if(JSON.stringify(updated)!==JSON.stringify(indexData)){indexData=updated;index();unchanged=0;}else unchanged++;
      }else{
        var meta=await get('/'+encodeURIComponent(workspace.slug)+'/?meta',own.signal);
        if(active!==epoch||probeController!==own)return;
        if(uploads)uploads.observe(meta);if(meta.id===workspace.id&&meta.generation===workspace.generation)contentSnapshot(meta);if(meta.id!==workspace.id||meta.generation!==workspace.generation||meta.allowUpload!==workspace.allowUpload||meta.backend!==workspace.backend||JSON.stringify(meta.capabilities)!==JSON.stringify(workspace.capabilities)){load(true);return;}
        if(!capability('state')){unchanged++;return;}
        var start=Math.max(0,Math.floor(viewport.scrollTop/rowHeight)-5);
        var ids=policy.probeIds(items,start,Math.ceil(viewport.clientHeight/rowHeight)+10,Math.max(0,7800-encodeURIComponent(directory).length));
        checkingDirectory=true;
        var state=await get(routeUrl()+'/state?generation='+workspace.generation+'&path='+encodeURIComponent(directory)+(documents()?'':'&ids='+encodeURIComponent(ids.join(','))),own.signal);
        if(active!==epoch||probeController!==own)return;
        if(state.generation!==workspace.generation||state.path!==directory)throw new Error('Stale directory state');contentSnapshot(state);
        if(documents()){
          var notification=documentRevision(documentWatchStamp,state);documentWatchStamp=notification.stamp;
          if(notification.changed){unchanged=0;invalidate();return;}
          unchanged++;failures=0;if(statusKey==='failed')status(finished?'end':'');return;
        }
        if(stamp&&state.stamp!==stamp||state.missing.length){invalidate();return;}
        var byId=new Map(state.entries.map(function(entry){return [entry.id,entry];})),changed=false;
        items.forEach(function(entry){var next=byId.get(entry.id);if(next){if(entry.directory!==next.directory){dirty=true;return;}if(entry.size!==next.size){entry.size=next.size;changed=true;}}});
        if(dirty){invalidate();return;}
        if(changed){if(!$('rows').contains(doc.activeElement))draw();unchanged=0;}else unchanged++;
      }
      failures=0;if(statusKey==='failed')status(finished?'end':'');
    }catch(error){
      if(active!==epoch||probeController!==own||error.name==='AbortError')return;
      if(error.status===401){lock(false);return;}
      if(error.status===409||error.status===410){invalidate();return;}
      if(error.status===404){if(checkingDirectory&&directory){openDirectory(documents()?(documentTrail.length>1?documentTrail[documentTrail.length-2].path:''):directory.split('/').slice(0,-1).join('/'),true);return;}reset();workspace=null;if(uploads)uploads.revoke('unavailable');viewport.hidden=true;labels();}
      failures++;status('failed');
    }finally{
      if(probeController===own){probeController=null;latency=latency*.7+(Date.now()-began)*.3;scheduleProbe(false);}
      else if(active!==epoch&&!loading)scheduleProbe(false);
    }
  }
  function index(){selectionControls();$('download-folder').hidden=true;var container=$('index');container.replaceChildren();(indexData.workspaces||[]).forEach(function(w){var card=node('a','card');card.href='/'+encodeURIComponent(w.slug)+'/';card.append(node('strong','',w.name),node('small','',text.open),node('span','tag',w.protected?text.locked:w.allowUpload===true?text.uploadAllowed:text.readOnly));container.append(card);});if(indexData.temporary){var link=node('a','card');link.href='/share';link.append(node('strong','',text.temporary),node('small','',text.temporaryHint));container.append(link);} status(container.children.length?'':'empty');}
  var previewsAvailable=root.LegnaDirectoryPreview&&root.LegnaWebLocales&&root.LegnaTextPreview&&root.LegnaTextSearch&&root.LegnaMarkdown;
  var preview=previewsAvailable?root.LegnaDirectoryPreview.create({onDownload:function(file){return !!workspace&&!documents()&&downloads&&downloads.downloadSource({kind:'directory',workspaceId:workspace.id,generation:workspace.generation,fileId:file.id,name:file.name,size:file.size});},onInvalid:function(code){
    if(code===401){lock(true);}else{load(false,'changed');}
  },onChanged:function(){abandonArchive();dirty=true;selectionControls();$('updates').hidden=false;$('more').hidden=true;status('changed');}}):{close:function(){}};
  function draw(){
    $('download-folder').hidden=!workspace||!capability('archive'); $('download-folder').textContent=(root.LegnaWebLocales[language]||root.LegnaWebLocales.en).webUi[!documents()&&downloads&&downloads.usesDirectory()?'downloadFolderFiles':'downloadFolderZip'];
    selectionControls();frame=0;
    viewport.style.height=finished ? Math.max(rowHeight,Math.min(items.length*rowHeight+2,Math.max(200,root.innerHeight-270)))+'px' : '';
    viewport.style.minHeight=finished?'0':'';
    var start=Math.max(0,Math.floor(viewport.scrollTop/rowHeight)-5), end=Math.min(items.length,start+Math.ceil(viewport.clientHeight/rowHeight)+10);
    var rows=$('rows');rows.replaceChildren();rows.style.transform='translateY('+(start*rowHeight)+'px)';$('spacer').style.height=(items.length*rowHeight)+'px';
    for(var i=start;i<end;i++){
      var item=items[i], row=node('div','row'), link=node('a','file-link');row.title=item.name;row.dataset.id=item.id;
      link.append(node('span','icon',item.directory?'▣':'↓'),node('span','name',item.name),node('span','size',item.directory?'':item.size===null?'—':formatSize(item.size)));
      if(item.directory){
        link.href='#';link.dataset.directory=documents()?item.id:filePath(directory,item.name);link.dataset.name=item.name;
        link.addEventListener('click',function(event){event.preventDefault();openDirectory(event.currentTarget.dataset.directory,false,null,null,event.currentTarget.dataset.name);});
      }else{
        link.href=routeUrl()+'/files/'+encodeURIComponent(item.id)+'/content?generation='+workspace.generation;link.setAttribute('download',item.name);
      }
      if(documents()&&!item.directory&&item.downloadable===false){link.removeAttribute('href');link.removeAttribute('download');link.setAttribute('aria-disabled','true');}
      if(capability('archive')){
        var checkbox=node('input','directory-select');checkbox.type='checkbox';checkbox.checked=selection.items.has(item.id);
        checkbox.dataset.unavailable=String(documents()&&!item.directory&&item.downloadable!==true);checkbox.disabled=archivePreparing()||checkbox.dataset.unavailable==='true';
        checkbox.setAttribute('aria-label',text.selectItem+': '+item.name);
        (function(control,file){control.addEventListener('change',function(){
          var accepted=selection.toggle(file,control.checked,function(ids){archiveSelectionUrl(routeUrl(),workspace.generation,directory,ids);});
          control.checked=selection.items.has(file.id);selectionMessage=accepted?'':'selectionLimit';selectionControls();
        });})(checkbox,item);row.append(checkbox);
      }
      row.append(link);
      if(downloads&&!documents()&&!item.directory){
        (function(control,source){control.addEventListener('click',function(event){if(!event.ctrlKey&&!event.metaKey&&!event.shiftKey&&!event.altKey&&downloads.downloadSource(source))event.preventDefault();});})(
          link,{kind:'directory',workspaceId:workspace.id,generation:workspace.generation,fileId:item.id,name:item.name,size:item.size});
      }
      if(capability('archive')&&item.directory){
        var folderDownload=node('button','folder-download',(root.LegnaWebLocales[language]||root.LegnaWebLocales.en).webUi[!documents()&&downloads&&downloads.usesDirectory()?'downloadFolderFiles':'downloadFolderZip']);
        folderDownload.type='button';folderDownload.setAttribute('aria-label',folderDownload.textContent+': '+item.name);
        (function(control,path){control.addEventListener('click',function(){startFolderDownload(path);});})(folderDownload,documents()?item.id:filePath(directory,item.name));row.append(folderDownload);
      }
      if(previewsAvailable&&capability('preview')&&!item.directory&&(!documents()||item.downloadable===true)&&root.LegnaDirectoryPreview.kind(item.name)){
        var button=node('button','preview-button',text.preview);button.type='button';button.setAttribute('aria-haspopup','dialog');button.setAttribute('aria-controls','directory-preview');button.setAttribute('aria-label',text.preview+': '+item.name);
        (function(file,url,control){control.addEventListener('click',function(){preview.open(file,url,language,false,{documents:documents()});});})(item,link.href,button);
        row.append(button);
      }
      rows.append(row);
    }
    $('count').textContent=countLabel();$('previous').hidden=!windowState.history.length;$('start').hidden=!windowState.offset;
  }
  if(root.LegnaPersistentDownloadUI&&root.LegnaWebLocales){downloads=root.LegnaPersistentDownloadUI.mount({container:$('download-tasks'),labels:(root.LegnaWebLocales[language]||root.LegnaWebLocales.en).webUi,onDestinationChange:function(){if(workspace)draw();},onAuth:function(task){if(workspace&&task.source.workspaceId===workspace.id)lock(true);}});}
  if(root.LegnaDirectoryUpload){uploads=root.LegnaDirectoryUpload.mount({container:$('workspace-upload'),dropTarget:doc.querySelector('main'),locale:language,onAuth:function(){lock(true);},onInvalid:function(){load(true);},onComplete:function(task){
    if(!workspace||workspace.id!==task.workspaceId||String(workspace.generation)!==String(task.generation)||directory!==task.base||uploadRefresh)return;
    uploadRefresh=root.setTimeout(function(){uploadRefresh=0;if(workspace&&workspace.id===task.workspaceId&&String(workspace.generation)===String(task.generation)&&directory===task.base&&!loading)openDirectory(directory,true);},600);
  }});}
  function uploadContext(){if(uploads&&workspace)uploads.setContext({id:workspace.id,slug:workspace.slug,name:workspace.name,generation:workspace.generation,backend:workspace.backend,path:directory,displayPath:documents()?documentTrail.map(function(item){return item.name;}).join('/'):directory,allowUpload:workspace.allowUpload===true,uploadApproval:workspace.uploadApproval===true,authorized:true});}
  function handoffArchive(url){var link=node('a');link.href=url;link.download='';link.hidden=true;doc.body.append(link);link.click();link.remove();}
  function getArchiveController(){
    if(archiveController)return archiveController;
    var ownEpoch=epoch,ownId=workspace.id,ownGeneration=workspace.generation,ownPath=directory;
    var own=new root.LegnaDirectoryArchiveSelection.Controller({route:routeUrl(),base:root.location.href,generation:ownGeneration,path:ownPath,fetch:root.fetch.bind(root),handoff:handoffArchive,
      isCurrent:function(){return archiveController===own&&epoch===ownEpoch&&workspace&&workspace.id===ownId&&workspace.generation===ownGeneration&&directory===ownPath&&!dirty&&pageActive&&$('unlock').hidden;},
      onChange:function(){if(archiveController===own)selectionControls();}});
    archiveController=own;return own;
  }
  async function browserArchive(path,ids){
    if(ids.length&&preparedArchive()){
      var own=getArchiveController(),active=epoch;selectionMessage='';
      try{await own.download(ids);if(active===epoch&&archiveController===own)selectionMessage='browserDownload';}
      catch(error){
        if(active!==epoch||archiveController!==own||error.code==='stale')return;
        if(error.status===401||error.status===403){lock(true);return;}
        selectionMessage=error.code==='selection-limit'||error.status===413?'selectionLimitLarge':error.code==='busy'||error.status===429?'archiveBusy':error.code==='timeout'?'archiveTimeout':error.code==='expired'||error.status===409||error.status===410?'archiveExpired':'archiveFailed';
      }
    }else{
      try{handoffArchive(archiveSelectionUrl(routeUrl(),workspace.generation,path,ids));selectionMessage='browserDownload';}
      catch(_){selectionMessage='selectionLimit';}
    }
    selectionControls();
  }
  function selectionControls(){
    var bar=$('directory-selection');if(!bar)return;
    var state=archiveController?archiveController.snapshot():{preparing:false,tickets:[]},preparing=state.preparing,large=preparedArchive();

    bar.hidden=!workspace||!capability('archive')||!$('unlock').hidden;
    $('select-loaded').textContent=text?(large?text.selectLoadedLarge:text.selectLoaded):'';$('clear-selection').textContent=text?text.clearSelection:'';
    $('download-selection').textContent=text?text.downloadSelection:'';$('selection-count').textContent=text?selection.items.size+' '+text.selected:'';
    bar.title=text?(large?text.selectionHintLarge:text.selectionHint):'';bar.setAttribute('aria-label',text?text.selectItem:'');
    var message=preparing?'archivePreparing':large&&selectionMessage==='selectionLimit'?'selectionLimitLarge':selectionMessage;
    $('selection-status').textContent=text&&message?text[message]:'';$('selection-status').hidden=!message;
    $('clear-selection').disabled=!selection.items.size;$('download-selection').disabled=!selection.items.size||dirty||loading||preparing||archiveCancelling;
    $('select-loaded').disabled=loading||!items.length||dirty||preparing;
    $('rows').querySelectorAll('.directory-select').forEach(function(control){control.disabled=preparing||control.dataset.unavailable==='true';});
    var cancel=$('cancel-archive-selection');if(cancel){cancel.hidden=!preparing&&!state.tickets.length;cancel.disabled=archiveCancelling;cancel.textContent=text?(preparing?text.archiveCancelPrepare:text.archiveCancelDownload):'';}
  }
  function startFolderDownload(path){
    if(!workspace||!capability('archive'))return;
    if(documents()||!downloads){browserArchive(path,[]);return;}
    downloads.downloadBatch({kind:'directory',workspaceId:workspace.id,generation:workspace.generation,path:path,name:path?path.split('/').pop():workspace.name},routeUrl()+'/archive?generation='+workspace.generation+'&path='+encodeURIComponent(path));
  }
  function formatSize(size){if(size<1024)return size+' B';if(size<1048576)return(size/1024).toFixed(1)+' KiB';return(size/1048576).toFixed(1)+' MiB';}
  async function next(event){
    if(fillTimer)root.clearTimeout(fillTimer);fillTimer=0;
    if(event&&event.type==='click')fillCount=0;
    if(!workspace||loading||finished||dirty||!foreground())return;
    stopProbe();loading=true;selectionControls();var active=epoch,signal=controller.signal,requested=cursor,began=Date.now(),loaded=false;status('loading');$('more').disabled=true;
    try{
      var url=routeUrl()+'/files?generation='+workspace.generation+'&path='+encodeURIComponent(directory)+(filterValue?'&filter='+encodeURIComponent(filterValue):'')+(cursor?'&cursor='+encodeURIComponent(cursor):'');
      if(documents()&&capability('state')&&documentWatchStamp===null){
        var initial=await get(routeUrl()+'/state?generation='+workspace.generation+'&path='+encodeURIComponent(directory),signal);if(active!==epoch)return;
        if(initial.generation!==workspace.generation||initial.path!==directory)throw new Error('Stale provider notification');
        documentWatchStamp=documentRevision(null,initial).stamp;
      }
      var page=await get(url,signal);if(active!==epoch)return;
      if(page.generation!==workspace.generation||page.path!==directory||(page.filter||'')!==filterValue||stamp&&stamp!==page.stamp){invalidate();return;}contentSnapshot(page);
      var removed=windowState.append(page,requested);items=windowState.items();stamp=page.stamp;cursor=page.cursor;finished=!cursor;
      if(removed)viewport.scrollTop=Math.max(0,viewport.scrollTop-removed*rowHeight);
      draw();loaded=true;uploadContext();$('unlock').hidden=true;$('logout').hidden=!workspace.protected;status(finished?(filterValue&&!items.length?'noMatches':'end'):(filterValue&&!items.length?'searching':''));$('more').hidden=finished;
    }catch(error){
      if(active!==epoch||error.name==='AbortError')return;
      if(error.status===401){lock(!silentAuth);}else if(error.status===409||error.status===410){if(staleRetry++<1){load(true,'changed');}else{status('changed');$('more').hidden=false;}}else{status('failed');$('more').hidden=false;}
    }finally{if(active===epoch){loading=false;selectionControls();latency=latency*.7+(Date.now()-began)*.3;$('more').disabled=false;scheduleProbe(false);if(loaded&&!finished&&!dirty&&items.length<Math.ceil(viewport.clientHeight/rowHeight)&&(filterValue||fillCount++<2)){fillTimer=root.setTimeout(function(){fillTimer=0;if(active===epoch)next();},200);}}}
  }
  function openDirectory(path,automatic,anchor,history,label){
    if(uploads)uploads.suspend();if(!automatic)staleRetry=0;if(path!==directory){filterValue='';$('directory-filter').value='';}
    if(documents()){
      documentTrail=documentTrailFor(documentTrail,path,label,workspace.name);
    }
    var keepSelection=!!anchor&&path===directory&&preparedArchive();directory=path;var active=reset(keepSelection);silentAuth=automatic===true;if(anchor){windowState.reset(anchor.start,history);cursor=anchor.cursor;}
    $('path').replaceChildren();if(path){var up=node('button','',text.up);up.type='button';up.addEventListener('click',function(){openDirectory(documents()?(documentTrail.length>1?documentTrail[documentTrail.length-2].path:''):path.split('/').slice(0,-1).join('/'));});$('path').append(up,node('span','',' / '+(documents()?documentTrail.map(function(item){return item.name;}).join(' / '):path)));}
    labels();return next().then(function(){return active===epoch;});
  }

  async function load(automatic,notice){if(uploads)uploads.suspend();automatic=automatic===true;if(!automatic)staleRetry=0;closeAuth();$('unlock').hidden=true;$('logout').hidden=true;var active=reset();workspace=null;indexData=null;viewport.hidden=true;$('index').hidden=false;$('index').replaceChildren();$('path').replaceChildren();labels();status('loading');try{var slug=root.location.pathname.split('/').filter(Boolean)[0];if(slug){var data=await get('/'+encodeURIComponent(slug)+'/?meta',controller.signal);if(active!==epoch)return;workspace=data;if(documents()){var scope=data.id+':'+data.generation;if(scope!==documentScope){documentScope=scope;documentTrail=[];directory='';}}else{documentScope=null;documentTrail=[];}if(uploads)uploads.observe(data);viewport.hidden=false;$('index').hidden=true;labels();if(await openDirectory(directory,automatic)&&notice)status(notice);}else{var newIndex=await get('/api/legnasend/v1/workspaces',controller.signal);if(active!==epoch)return;indexData=newIndex;index();}}catch(error){if(active===epoch&&error.name!=='AbortError'){if(uploads)uploads.revoke('unavailable');status('failed');}}finally{if(!loading)scheduleProbe(false);}}
  function authLabels(){
    $('unlock').textContent=text.unlock;$('logout').textContent=text.logout;
    $('auth-title').textContent=text.locked;$('auth-label').textContent=text.password;
    $('auth-hint').textContent=text.authHint;$('auth-http').textContent=root.location.protocol==='https:'?'':text.httpPassword;
    $('auth-cancel').textContent=text.cancel;$('auth-submit').textContent=authBusy?text.unlocking:text.unlock;
    $('auth-error').textContent=authError?text[authError]:'';
  }
  function closeAuth(){authEpoch++;if(authController)authController.abort();authController=null;authBusy=false;authError='';$('auth-password').value='';$('auth-submit').disabled=false;if($('auth').open)$('auth').close();}
  function lock(show){if(uploads)uploads.revoke('auth');reset();viewport.hidden=true;$('count').textContent='';$('unlock').hidden=false;$('logout').hidden=true;selectionControls();status('locked');if(show&&!$('auth').open){authError='';authLabels();$('auth').showModal();$('auth-password').focus();}}
  $('unlock').addEventListener('click',function(){lock(true);});
  $('auth-cancel').addEventListener('click',closeAuth);
  $('auth').addEventListener('cancel',function(event){event.preventDefault();closeAuth();});
  $('auth-form').addEventListener('submit',async function(event){
    event.preventDefault();if(authBusy||!workspace)return;
    var active=++authEpoch, expected=workspace.id;
    authBusy=true;authError='';authController=new AbortController();$('auth-submit').disabled=true;authLabels();
    var body=JSON.stringify({password:$('auth-password').value,generation:workspace.generation});$('auth-password').value='';
    try{
      var response=await root.fetch(routeUrl()+'/unlock',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:body,signal:authController.signal,cache:'no-store'});
      if(active!==authEpoch||!workspace||workspace.id!==expected)return;
      if(response.ok){closeAuth();viewport.hidden=false;openDirectory(directory);}
      else if(response.status===409){closeAuth();load();}
      else{authError=response.status===401?'wrongPassword':response.status===429?'rateLimited':'failed';}
    }catch(error){if(active===authEpoch&&error.name!=='AbortError')authError='failed';}
    finally{if(active===authEpoch){authBusy=false;$('auth-submit').disabled=false;authLabels();}}
  });
  $('logout').addEventListener('click',async function(){
    if(!workspace)return;if(uploads)uploads.revoke('auth');var active=epoch;this.disabled=true;
    try{var response=await root.fetch(routeUrl()+'/logout',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store'});if(active!==epoch)return;if(response.ok)lock(false);else status('failed');}
    catch(_){if(active===epoch)status('failed');}finally{this.disabled=false;}
  });
  function applyFilter(immediate){
    var value=$('directory-filter').value;if(value===filterValue&&!immediate)return;
    filterValue=value;var active=reset();labels();status('loading');
    function apply(){filterTimer=0;if(active===epoch&&workspace)openDirectory(directory,true);}
    if(immediate)apply();else filterTimer=root.setTimeout(apply,250);
  }
  $('directory-filter').addEventListener('input',function(){applyFilter(false);});
  $('directory-filter-form').addEventListener('submit',function(event){event.preventDefault();applyFilter(true);});
  $('directory-filter-clear').addEventListener('click',function(){$('directory-filter').value='';applyFilter(true);$('directory-filter').focus();});
  $('download-folder').onclick=function(){if(workspace)startFolderDownload(directory);};
  $('select-loaded').onclick=function(){
    if(!workspace||dirty||loading)return;var limited=false;
    items.forEach(function(item){if(documents()&&!item.directory&&item.downloadable!==true)return;if(!selection.toggle(item,true,function(ids){archiveSelectionUrl(routeUrl(),workspace.generation,directory,ids);}))limited=true;});
    selectionMessage=limited?'selectionLimit':'';draw();
  };
  $('clear-selection').onclick=function(){if(archiveController)archiveController.cancel();selection.clear();selectionMessage='';draw();};
  $('cancel-archive-selection').onclick=async function(){
    var own=archiveController;if(!own||archiveCancelling)return;var state=own.snapshot(),ticket=state.tickets[state.tickets.length-1];archiveCancelling=true;selectionControls();
    try{await own.cancel(state.preparing?null:ticket&&ticket.selection);if(archiveController===own)selectionMessage=state.preparing?'archiveCancelled':'archiveDownloadCancelled';}
    catch(_){if(archiveController===own)selectionMessage='archiveCancelFailed';}
    finally{if(archiveController===own){archiveCancelling=false;selectionControls();}}
  };
  $('download-selection').onclick=function(){if(workspace&&!dirty&&!loading&&selection.items.size)browserArchive(directory,Array.from(selection.items.keys()));};
  $('language').addEventListener('change',function(){preview.close();language=locale(this.value);try{root.localStorage.setItem('legnasend-directory-language',language);}catch(_){} labels();if(downloads)downloads.setLabels((root.LegnaWebLocales[language]||root.LegnaWebLocales.en).webUi);if(indexData)index();else{draw();}});
  $('updates').addEventListener('click',function(){refreshBlocked=false;refreshWindow();});$('start').addEventListener('click',function(){openDirectory(directory);});
  $('previous').addEventListener('click',function(){if(loading)return;var anchor=windowState.previous(),history=windowState.history.slice();if(anchor)openDirectory(directory,false,anchor,history);});
  $('refresh').addEventListener('click',load);$('more').addEventListener('click',next);
  viewport.addEventListener('scroll',function(){
    if(!frame)frame=root.requestAnimationFrame(draw);
    var now=Date.now(),delta=viewport.scrollTop-lastScroll,velocity=delta/Math.max(1,now-lastScrollAt);lastScroll=viewport.scrollTop;lastScrollAt=now;
    if(delta>0&&now-lastPrefetch>=200&&viewport.scrollTop+viewport.clientHeight>items.length*rowHeight-policy.prefetchDistance(viewport.clientHeight,velocity,latency)){lastPrefetch=now;next();}
  },{passive:true});
  function resumeBrowsing(){
    if(controller&&controller.signal.aborted)controller=new AbortController();
    // A locked workspace has no listing stamp by design. Returning to the tab
    // or reconnecting must not reload metadata and dismiss an active PIN form.
    if(authBusy||$('auth').open||workspace&&!$('unlock').hidden)return;
    if(dirty&&workspace)refreshWindow();else if(!stamp&&workspace)load(true);else scheduleProbe(true);
  }
  doc.addEventListener('visibilitychange',function(){if(doc.hidden){stopEvents();stopProbe();if(controller)controller.abort();if(refreshController)refreshController.abort();}else resumeBrowsing();});
  root.addEventListener('offline',function(){abandonArchive();selectionControls();stopEvents();stopProbe();if(controller)controller.abort();if(refreshController)refreshController.abort();});
  root.addEventListener('online',resumeBrowsing);
  root.addEventListener('pagehide',function(event){pageActive=false;abandonArchive();stopProbe();if(uploadRefresh)root.clearTimeout(uploadRefresh);uploadRefresh=0;if(uploads){if(event.persisted)uploads.manager.cancelAll();else uploads.close();}if(downloads){if(event.persisted)downloads.pauseAll();else downloads.close();}closeAuth();if(event.persisted){stopEvents();preview.close();if(controller)controller.abort();if(refreshController)refreshController.abort();}else reset();if(frame)root.cancelAnimationFrame(frame);frame=0;});
  root.addEventListener('pageshow',function(event){pageActive=true;if(event.persisted)resumeBrowsing();});
  labels();load();
})(typeof window==='object'?window:globalThis);
