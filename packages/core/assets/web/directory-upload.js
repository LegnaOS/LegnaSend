(function (root) {
  'use strict';
  var MAX_TASKS=10000, PAGE=24, CONCURRENCY=2;
  var messages={
    en:{unconfirmed:'Host result unconfirmed. Refresh the folder before retrying.',checking:'Checking workspace…',resume:'Continue queue',title:'Upload to workspace',files:'Choose files',folder:'Choose folder',drop:'Drop files or folders here',destination:'Destination',queued:'Queued',uploading:'Uploading',publishing:'Saving on host…',succeeded:'Complete',failed:'Failed',cancelled:'Cancelled',cancel:'Cancel',cancelAll:'Cancel pending',retry:'Retry whole file',rename:'Rename & retry',clear:'Clear finished',previous:'Previous',next:'Next',close:'Cancel',save:'Upload with new name',renameTitle:'Choose a different file name',name:'File name',nameHint:'Existing files are never overwritten. Only this file is renamed.',invalid:'This name or path is not supported.',conflict:'Name exists or workspace changed. Refresh, or rename this file.',auth:'Workspace locked. Unlock before selecting files again.',permission:'Uploads are disabled. Pending uploads were cancelled.',changed:'Workspace changed. Select files again for the new workspace.',network:'Connection failed. Retry sends the complete original file.',busy:'The host is busy. Retry when another upload finishes.',unavailable:'Workspace is unavailable.',response:'The host did not confirm this upload.',limit:'A queue can hold 10,000 entries. Clear finished items before adding more.',scan:'Reading selected files…',scanFailed:'Some selected files could not be read. Select them again.',skipped:'No files or folders were selected.',count:'items',of:'of',speed:'Speed',emptyHint:'Empty folders can be included by drag and drop where supported.',cancelledHint:'Cancelled uploads are not automatically retried.',waiting:'Files are ready; waiting for host permission.',page:'Upload queue page',total:'Uploads',ready:'Uploads allowed',whole:'Retry sends the whole file; upload resume is not advertised.'},
    'zh-CN':{unconfirmed:'保存结果待确认，请刷新目录核对后再重试。',checking:'正在核对工作区…',resume:'继续队列',title:'上传到工作区',files:'选择文件',folder:'选择文件夹',drop:'拖入文件或文件夹',destination:'目标目录',queued:'等待上传',uploading:'正在上传',publishing:'接收端正在保存…',succeeded:'已完成',failed:'失败',cancelled:'已取消',cancel:'取消',cancelAll:'取消待完成项',retry:'整文件重试',rename:'改名并重试',clear:'清除已结束项',previous:'上一页',next:'下一页',close:'取消',save:'使用新名称上传',renameTitle:'使用不同的文件名',name:'文件名',nameHint:'不会覆盖已有文件；仅更改此文件的名称。',invalid:'此文件名或路径不受支持。',conflict:'名称已存在或工作区已变化，请刷新或为此文件改名。',auth:'工作区已锁定，请解锁后重新选择文件。',permission:'上传权限已关闭，待完成项已取消。',changed:'工作区已变化，请为新的工作区重新选择文件。',network:'连接失败；重试会发送完整原文件。',busy:'接收端正忙，请等待其他上传结束后重试。',unavailable:'工作区暂不可用。',response:'接收端未确认此次上传。',limit:'队列最多保留 10,000 项，请清除已结束项后继续添加。',scan:'正在读取所选文件…',scanFailed:'部分所选文件读取失败，请重新选择。',skipped:'未选择文件或文件夹。',count:'项',of:'共',speed:'速度',emptyHint:'支持的浏览器可通过拖拽包含空文件夹。',cancelledHint:'取消的上传不会自动重试。',waiting:'文件已准备，正在等待接收端权限。',page:'上传队列分页',total:'上传任务',ready:'允许上传',whole:'重试会重新发送整文件，此入口不声明上传断点续传。'},
    'zh-TW':{unconfirmed:'儲存結果待確認，請重新整理目錄核對後再重試。',checking:'正在確認工作區…',resume:'繼續佇列',title:'上傳至工作區',files:'選擇檔案',folder:'選擇資料夾',drop:'拖入檔案或資料夾',destination:'目標目錄',queued:'等待上傳',uploading:'正在上傳',publishing:'接收端正在儲存…',succeeded:'已完成',failed:'失敗',cancelled:'已取消',cancel:'取消',cancelAll:'取消待完成項目',retry:'整檔重試',rename:'改名並重試',clear:'清除已結束項目',previous:'上一頁',next:'下一頁',close:'取消',save:'使用新名稱上傳',renameTitle:'使用不同的檔案名稱',name:'檔案名稱',nameHint:'不會覆寫既有檔案；僅更改此檔案的名稱。',invalid:'此檔案名稱或路徑不受支援。',conflict:'名稱已存在或工作區已變更，請重新整理或為此檔案改名。',auth:'工作區已鎖定，請解鎖後重新選擇檔案。',permission:'上傳權限已關閉，待完成項目已取消。',changed:'工作區已變更，請為新的工作區重新選擇檔案。',network:'連線失敗；重試會傳送完整原始檔案。',busy:'接收端忙碌中，請等待其他上傳結束後重試。',unavailable:'工作區暫時無法使用。',response:'接收端未確認此次上傳。',limit:'佇列最多保留 10,000 項，請清除已結束項目後繼續新增。',scan:'正在讀取所選檔案…',scanFailed:'部分所選檔案讀取失敗，請重新選擇。',skipped:'未選擇檔案或資料夾。',count:'項',of:'共',speed:'速度',emptyHint:'支援的瀏覽器可透過拖曳包含空資料夾。',cancelledHint:'已取消的上傳不會自動重試。',waiting:'檔案已備妥，正在等待接收端權限。',page:'上傳佇列分頁',total:'上傳任務',ready:'允許上傳',whole:'重試會重新傳送整個檔案，此入口不宣告上傳續傳功能。'}
  };
  Object.assign(messages.en,{approving:'Waiting for host approval',approvalDenied:'The host declined this batch. You can select files or retry again.',approvalExpired:'Approval timed out or expired. Retry to request fresh approval.',approvalRequired:'Host approval is required again. Retry to request it.',approvalCancel:'Cancel batch',approvalHint:'One host approval covers this selection. Cancelling an item cancels the remaining items in its batch.'});
  Object.assign(messages['zh-CN'],{approving:'等待接收端确认',approvalDenied:'接收端已拒绝此批次，可重新选择文件或重试。',approvalExpired:'确认已超时或失效，重试将重新申请确认。',approvalRequired:'需要接收端重新确认，请重试以申请。',approvalCancel:'取消批次',approvalHint:'一次确认适用于本次选择；取消其中一项会取消该批次剩余项目。'});
  Object.assign(messages['zh-TW'],{approving:'等待接收端確認',approvalDenied:'接收端已拒絕此批次，可重新選擇檔案或重試。',approvalExpired:'確認已逾時或失效，重試將重新申請確認。',approvalRequired:'需要接收端重新確認，請重試以申請。',approvalCancel:'取消批次',approvalHint:'一次確認適用於本次選擇；取消其中一項會取消該批次剩餘項目。'});
  messages['zh-HK']=Object.assign({},messages['zh-TW']);
  function locale(value){return /^zh/i.test(value)?(/HK/i.test(value)?'zh-HK':/TW|Hant/i.test(value)?'zh-TW':'zh-CN'):'en';}
  function requestId(){var c=root.crypto;if(!c||!c.getRandomValues)throw fault('unavailable');if(c.randomUUID)return c.randomUUID();var bytes=new Uint8Array(16);c.getRandomValues(bytes);bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;var hex=Array.from(bytes,function(b){return b.toString(16).padStart(2,'0');}).join('');return hex.slice(0,8)+'-'+hex.slice(8,12)+'-'+hex.slice(12,16)+'-'+hex.slice(16,20)+'-'+hex.slice(20);}

  function utf8(value){return new TextEncoder().encode(value).length;}
  function validPath(path){
    if(typeof path!=='string'||!path||utf8(path)>4096)return false;
    var parts=path.split('/');return parts.length<=64&&parts.every(function(p){return p&&p!=='.'&&p!=='..'&&utf8(p)<=255&&!/[\\:\x00-\x1f\x7f]/.test(p)&&!/[. ]$/.test(p)&&!/^\.legnasend/i.test(p)&&!/\.ls$/i.test(p)&&!/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(p);});
  }
  function join(base,path){return base?base+'/'+path:path;}
  function active(task){return task.state==='uploading'||task.state==='publishing'||task.state==='checking';}
  function pending(task){return active(task)||task.state==='queued'||task.state==='approving';}
  function same(a,b){return a&&b&&a.id===b.id&&String(a.generation)===String(b.generation);}
  function fault(key){var e=new Error(key);e.code=key;return e;}
  function Manager(options){this.options=options||{};this.tasks=[];this.context=null;this.sequence=0;this.running=0;this.closed=false;this.suspended=false;this.paused=false;this.holding=false;this.notice='';this.onChange=this.options.onChange||function(){};}
  Manager.prototype.notify=function(){this.onChange();};
  Manager.prototype.allowed=function(target){return !this.closed&&this.context&&this.context.allowUpload===true&&this.context.authorized===true&&(!target||same(target,this.context));};
  Manager.prototype.snapshot=function(){if(!this.allowed()||this.suspended)return null;return Object.assign({},this.context);};
  Manager.prototype.suspend=function(){this.suspended=true;this.notify();};
  Manager.prototype.observe=function(meta){if(this.context&&(!same(meta,this.context)||meta.allowUpload!==true||meta.uploadApproval!==this.context.uploadApproval))this.revoke(meta.allowUpload===true?'changed':'permission');};
  Manager.prototype.setContext=function(context){
    if(!context||!context.allowUpload||!context.authorized){this.revoke(context&&context.allowUpload?'auth':'permission');return;}
    if(this.context&&(!same(context,this.context)||context.uploadApproval!==this.context.uploadApproval))this.revoke('changed');
    this.context=Object.assign({},context);this.suspended=false;if(!this.paused)this.notice='';this.notify();this.pump();
  };
  Manager.prototype.revoke=function(reason){this.context=null;this.suspended=true;this.notice=reason||'permission';var self=this;this.tasks.forEach(function(t){if(pending(t))self.cancel(t,reason);});this.notify();};
  Manager.prototype.enqueue=function(entries,target){
    if(!this.allowed(target))throw fault('permission');
    if(!entries.length)return [];
    if(this.tasks.length+entries.length>MAX_TASKS)throw fault('limit');
    var self=this, prepared=entries.map(function(entry){var documents=target.backend==='documents',parent=documents?(target.path||''):'';if(parent.length>4096||/[\x00-\x1f\x7f]/.test(parent))throw fault('invalid');var path=documents?entry.path:join(target.path||'',entry.path);if(!validPath(path)||(!entry.directory&&(!entry.file||!Number.isSafeInteger(entry.file.size)||entry.file.size<0)))throw fault('invalid');return {id:++self.sequence,workspaceId:target.id,generation:target.generation,workspaceName:target.name||target.id,workspaceSlug:target.slug,backend:documents?'documents':'filesystem',parent:parent,base:target.path||'',path:path,directory:!!entry.directory,file:entry.file||null,size:entry.directory?0:entry.file.size,state:'queued',error:'',loaded:0,speed:0,xhr:null,attempt:0};});
    this.tasks.push.apply(this.tasks,prepared);this.notice='';if(target.uploadApproval===true)this.prepareGroup(prepared,target);else{this.notify();this.pump();}return prepared;
  };
  Manager.prototype.prepareGroup=function(tasks,target){
    var self=this,id;try{id=(this.options.requestId||requestId)();}catch(_){tasks.forEach(function(t){t.state='failed';t.error='unavailable';});this.notice='unavailable';this.notify();return null;}var group={requestId:id,workspaceId:target.id,generation:target.generation,tasks:tasks,controller:new AbortController(),token:null,closed:false};
    tasks.forEach(function(t){t.approval=group;t.state='approving';t.error='';});this.notify();
    var fetch=this.options.fetch||root.fetch.bind(root),timer=root.setTimeout(function(){group.controller.abort();},65000);
    var payload={requestId:group.requestId,generation:group.generation,files:tasks.map(function(t){return {path:t.path,size:t.size,directory:t.directory};})};
    if(tasks[0].backend==='documents')payload.parent=tasks[0].parent;
    group.promise=(async function(){
      try{
        var response=await fetch('/api/legnasend/v1/workspaces/'+encodeURIComponent(group.workspaceId)+'/prepare-upload',{method:'POST',credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-LegnaSend-Upload':'1'},body:JSON.stringify(payload),signal:group.controller.signal});
        if(group.closed||self.closed)return;
        if(!response.ok)throw fault(response.status===403?'approvalDenied':response.status===408?'approvalExpired':response.status===401?'auth':response.status===409?'changed':response.status===429?'busy':response.status===400||response.status===413?'invalid':'network');
        var data=await response.json();if(group.closed||self.closed)return;
        if(!data||typeof data.token!=='string'||!/^[a-f0-9]{64}$/i.test(data.token))throw fault('response');
        group.token=data.token;
        tasks.forEach(function(t){if(t.approval===group&&t.state==='approving')t.state='queued';});self.notify();self.pump();
      }catch(e){
        if(group.closed||self.closed)return;
        group.token=null;var code=e.name==='AbortError'?'approvalExpired':e.code||'network';
        tasks.forEach(function(t){if(t.approval===group&&t.state==='approving'){t.state='failed';t.error=code;}});
        self.notice=code;self.notify();
        if(code==='auth'||code==='changed'){self.revoke(code);if(code==='auth'&&self.options.onAuth)self.options.onAuth();else if(self.options.onInvalid)self.options.onInvalid(code);}
      }finally{root.clearTimeout(timer);}
    })();
    return group;
  };
  Manager.prototype.cancelGroup=function(group,reason){
    if(!group||group.closed)return;group.closed=true;group.token=null;group.controller.abort();var self=this,wasHolding=this.holding;this.holding=true;
    group.tasks.forEach(function(t){if(t.approval===group&&pending(t)){t.error=reason||'cancelledHint';if(t.abort)t.abort();else t.state='cancelled';}});
    this.holding=wasHolding;
    var controller=new AbortController(),timer=root.setTimeout(function(){controller.abort();},5000);
    Promise.resolve().then(function(){return(self.options.fetch||root.fetch.bind(root))('/api/legnasend/v1/workspaces/'+encodeURIComponent(group.workspaceId)+'/cancel-upload-approval',{method:'POST',credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-LegnaSend-Upload':'1'},body:JSON.stringify({requestId:group.requestId,generation:group.generation}),signal:controller.signal});}).catch(function(){}).finally(function(){root.clearTimeout(timer);});
    this.notify();this.pump();
  };
  Manager.prototype.pump=function(){if(!this.allowed()||this.paused||this.holding)return;for(var i=0;i<this.tasks.length&&this.running<CONCURRENCY;i++){var task=this.tasks[i];if(task.state==='queued'&&(!task.approval||task.approval.token&&!task.approval.closed)&&this.allowed({id:task.workspaceId,generation:task.generation}))this.start(task);}};
  Manager.prototype.start=function(task){
    var self=this,xhr=(this.options.xhrFactory||function(){return new root.XMLHttpRequest();})(),attempt=++task.attempt,ended=false,start=(this.options.now||Date.now)(),lastAt=start,lastBytes=0;
    task.xhr=xhr;task.state='uploading';task.error='';task.loaded=0;task.speed=0;this.running++;
    function finish(state,error,receipt){if(ended||task.attempt!==attempt)return;ended=true;self.running--;task.xhr=null;task.abort=null;task.state=state;task.error=error||'';task.speed=0;if(state==='succeeded')task.loaded=task.size;if(state==='failed'&&['busy','network','unavailable','response','conflict','approvalRequired','unconfirmed'].indexOf(error)>=0){self.paused=true;self.notice=error;}self.notify();if(state==='succeeded'&&self.options.onComplete)self.options.onComplete(task,receipt);if(state==='failed'&&(error==='auth'||error==='permission'||error==='changed')){self.revoke(error);if(self.options.onAuth&&error==='auth')self.options.onAuth();else if(self.options.onInvalid)self.options.onInvalid(error);}else if(state==='failed'&&error==='conflict'&&self.options.onInvalid)self.options.onInvalid(error);self.pump();}
    function abortOutcome(){if(task.state==='publishing'||task.directory)finish('failed','unconfirmed');else finish('cancelled',task.error||'cancelledHint');}
    task.abort=function(){var uncertain=task.state==='publishing'||task.directory;xhr.abort();if(uncertain)finish('failed','unconfirmed');else finish('cancelled',task.error||'cancelledHint');};
    xhr.upload.onprogress=function(event){if(ended)return;var now=(self.options.now||Date.now)(),loaded=Math.min(task.size,event.loaded);if(now>lastAt){task.speed=Math.max(0,(loaded-lastBytes)*1000/(now-lastAt));lastAt=now;lastBytes=loaded;}task.loaded=loaded;if(loaded===task.size)task.state='publishing';self.notify();};
    xhr.onload=function(){if(xhr.status===201){try{var data=JSON.parse(xhr.responseText);if(task.backend==='documents'&&data.parent!==task.parent||data.path!==task.path||data.size!==task.size||data.directory!==task.directory||!task.directory&&!/^[a-f0-9]{64}$/i.test(data.sha256))throw Error('receipt');finish('succeeded','',data);}catch(_){finish('failed','response');}}else if(xhr.status===409){task.state='checking';self.notify();Promise.resolve().then(function(){return (self.options.resolveConflict||checkConflict)(task);}).then(function(code){finish('failed',code);},function(){finish('failed','network');});}else{finish('failed',xhr.status===401?'auth':xhr.status===403?'permission':xhr.status===428?'approvalRequired':xhr.status===429?'busy':xhr.status===404||xhr.status===410?'unavailable':xhr.status===400||xhr.status===413||xhr.status===422?'invalid':'network');}};
    xhr.onerror=function(){finish('failed','network');};xhr.ontimeout=function(){finish('failed','network');};xhr.onabort=abortOutcome;
    try{xhr.open('POST','/api/legnasend/v1/workspaces/'+encodeURIComponent(task.workspaceId)+'/upload?generation='+encodeURIComponent(task.generation)+'&path='+encodeURIComponent(task.path)+(task.backend==='documents'?'&parent='+encodeURIComponent(task.parent):'')+(task.directory?'&directory=true':''),true);xhr.withCredentials=true;xhr.setRequestHeader('X-LegnaSend-Upload','1');if(task.approval)xhr.setRequestHeader('X-LegnaSend-Upload-Token',task.approval.token);xhr.setRequestHeader('Content-Type','application/octet-stream');xhr.send(task.directory?new Blob([]):task.file);}catch(_){finish('failed','network');}
    this.notify();
  };
  Manager.prototype.cancel=function(task,reason){if(!pending(task))return;if(task.approval){this.cancelGroup(task.approval,reason);return;}task.error=reason||'cancelledHint';if(task.abort){task.abort();}else{task.state='cancelled';this.notify();}};
  Manager.prototype.cancelAll=function(){var self=this;this.holding=true;this.tasks.forEach(function(t){self.cancel(t);});this.holding=false;};
  Manager.prototype.resume=function(){if(!this.allowed())return;this.paused=false;this.notice='';this.notify();this.pump();};
  Manager.prototype.retry=function(task,name){
    if(pending(task)||task.state==='succeeded'||!this.allowed({id:task.workspaceId,generation:task.generation}))return false;
    if(name!==undefined){if(task.directory||name.indexOf('/')>=0)throw fault('invalid');var path=join(task.path.split('/').slice(0,-1).join('/'),name);if(!validPath(path))throw fault('invalid');task.path=path;}
    this.paused=false;this.notice='';task.state='queued';task.loaded=0;task.error='';task.speed=0;if(this.context.uploadApproval===true){this.prepareGroup([task],this.context);}else{task.approval=null;this.notify();this.pump();}return true;
  };
  Manager.prototype.clear=function(){this.tasks=this.tasks.filter(pending);this.notice='';this.notify();};
  Manager.prototype.close=function(){this.closed=true;this.cancelAll();};
  async function checkConflict(task){
    if(!task.workspaceSlug)return 'changed';
    var controller=new AbortController(),timer=root.setTimeout(function(){controller.abort();},5000);
    try{var response=await root.fetch('/'+encodeURIComponent(task.workspaceSlug)+'/?meta',{credentials:'same-origin',cache:'no-store',signal:controller.signal});if(response.status===401)return 'auth';if(!response.ok)return 'unavailable';var meta=await response.json();if(meta.id!==task.workspaceId||String(meta.generation)!==String(task.generation))return 'changed';return meta.allowUpload===true?'conflict':'permission';}finally{root.clearTimeout(timer);}
  }
  // Capture DataTransfer entries synchronously: browser drag data is protected after the event returns.
  function captureDrop(data){return {entries:Array.from(data.items||[]).filter(function(i){return i.kind==='file';}).map(function(i){return i.webkitGetAsEntry?i.webkitGetAsEntry():null;}).filter(Boolean),files:Array.from(data.files||[])};}
  async function scanDrop(captured){
    if(!captured.entries.length)return fileEntries(captured.files);
    var result=[],stack=captured.entries.map(function(entry){return {entry:entry,parent:''};}).reverse();
    var visited=0;
    while(stack.length){if(++visited%128===0)await new Promise(function(resolve){root.setTimeout(resolve,0);});var item=stack.pop(),entry=item.entry,path=join(item.parent,entry.name);if(!validPath(path))throw fault('invalid');if(result.length+stack.length>MAX_TASKS)throw fault('limit');
      if(entry.isFile){var file=await new Promise(function(resolve,reject){entry.file(resolve,reject);});result.push({path:path,file:file});}
      else if(entry.isDirectory){var reader=entry.createReader(),children=[];while(true){var batch=await new Promise(function(resolve,reject){reader.readEntries(resolve,reject);});if(!batch.length)break;children.push.apply(children,batch);if(children.length+result.length+stack.length>MAX_TASKS)throw fault('limit');}if(!children.length)result.push({path:path,directory:true});else{for(var n=children.length-1;n>=0;n--)stack.push({entry:children[n],parent:path});}}
    }
    return result;
  }
  function fileEntries(files){var result=Array.from(files).map(function(file){return {path:file.webkitRelativePath||file.name,file:file};});if(result.length>MAX_TASKS)throw fault('limit');return result;}
  function bytes(value){var unit=['B','KiB','MiB','GiB','TiB'],i=0;while(value>=1024&&i<4){value/=1024;i++;}return(i?value.toFixed(1):value)+' '+unit[i];}
  function mount(options){
    var doc=root.document,container=options.container,language=locale(options.locale||'en'),text=messages[language],page=0,timer=0,scanning=0,notice='',selection=null,renameTask=null;
    function el(tag,cls,value){var n=doc.createElement(tag);n.className=cls||'';if(value!==undefined)n.textContent=value;return n;}
    function button(parent,fn){var b=el('button');b.type='button';b.onclick=fn;parent.append(b);return b;}
    var top=el('div','workspace-upload-top'),heading=el('h2'),tools=el('div','workspace-upload-tools'),target=el('p','workspace-upload-target'),hint=el('p','workspace-upload-hint'),status=el('p','workspace-upload-notice');
    status.setAttribute('role','status');top.append(heading,tools);container.append(top,target,hint,status);container.classList.add('workspace-upload');
    var files=el('input'),folder=el('input');files.type=folder.type='file';files.multiple=folder.multiple=true;folder.setAttribute('webkitdirectory','');files.hidden=folder.hidden=true;container.append(files,folder);
    var chooseFiles=button(tools,function(){selection=manager.snapshot();if(selection)files.click();}),chooseFolder=button(tools,function(){selection=manager.snapshot();if(selection)folder.click();});
    var resume=button(tools,function(){manager.resume();}),cancelAll=button(tools,function(){manager.cancelAll();}),clear=button(tools,function(){manager.clear();page=0;});
    var counts=el('p','workspace-upload-counts'),list=el('div','workspace-upload-list'),paging=el('nav','workspace-upload-paging'),previous=button(paging,function(){page=Math.max(0,page-1);render();}),range=el('span'),next=button(paging,function(){page++;render();});paging.insertBefore(range,next);container.append(counts,list,paging);
    var dialog=el('dialog','workspace-upload-rename'),form=el('form'),title=el('h2'),label=el('label'),input=el('input'),copy=el('p'),error=el('p','workspace-upload-error'),actions=el('div','workspace-upload-tools');input.type='text';input.required=true;input.maxLength=255;input.id='workspace-upload-name';label.htmlFor=input.id;error.setAttribute('role','alert');form.append(title,label,input,copy,error,actions);dialog.append(form);container.append(dialog);var close=button(actions,function(){dialog.close();renameTask=null;}),save=button(actions,function(){});save.type='submit';
    form.onsubmit=function(event){event.preventDefault();try{if(renameTask&&manager.retry(renameTask,input.value)){renameTask=null;dialog.close();}else error.textContent=text.changed;}catch(_){error.textContent=text.invalid;}};dialog.addEventListener('cancel',function(){renameTask=null;});
    function requestRender(){if(!timer)timer=root.setTimeout(function(){timer=0;render();},100);}
    var manager=new Manager({onChange:requestRender,onComplete:options.onComplete,onAuth:options.onAuth,onInvalid:options.onInvalid});
    function row(task){var box=el('article','workspace-upload-row'),line=el('div','workspace-upload-line'),name=el('span','workspace-upload-name'),state=el('span','tag'),progress=el('progress'),metrics=el('small'),controls=el('div','workspace-upload-tools');line.append(name,state);box.append(line,progress,metrics,controls);var cancel=button(controls,function(){manager.cancel(task);}),retry=button(controls,function(){manager.retry(task);}),rename=button(controls,function(){renameTask=task;input.value=task.path.split('/').pop();error.textContent='';dialog.showModal();input.focus();input.select();});return {box:box,name:name,state:state,progress:progress,metrics:metrics,cancel:cancel,retry:retry,rename:rename};}
    var rows=new Map();
    function render(){
      text=messages[language];if(renameTask&&!manager.allowed({id:renameTask.workspaceId,generation:renameTask.generation})){dialog.close();renameTask=null;}var allowed=manager.allowed()&&!manager.suspended,total=manager.tasks.length,max=Math.max(0,Math.ceil(total/PAGE)-1);page=Math.min(page,max);container.hidden=!allowed&&!total;
      heading.textContent=text.title;chooseFiles.textContent=text.files;chooseFolder.textContent=text.folder;chooseFiles.hidden=chooseFolder.hidden=!allowed;chooseFiles.disabled=chooseFolder.disabled=!!scanning;resume.textContent=text.resume;resume.hidden=!manager.paused||!manager.allowed();cancelAll.textContent=text.cancelAll;cancelAll.hidden=!manager.tasks.some(pending);clear.textContent=text.clear;clear.hidden=!manager.tasks.some(function(t){return !pending(t);});
      target.textContent=manager.context?text.destination+': '+manager.context.name+' /'+(manager.context.displayPath||manager.context.path||''):'';hint.textContent=text.drop+' · '+text.emptyHint+(manager.context&&manager.context.uploadApproval?' · '+text.approvalHint:'');hint.hidden=!allowed;status.textContent=scanning?text.scan:text[notice||manager.notice]||'';title.textContent=text.renameTitle;label.textContent=text.name;copy.textContent=text.nameHint;close.textContent=text.close;save.textContent=text.save;
      var tally={};manager.tasks.forEach(function(t){tally[t.state]=(tally[t.state]||0)+1;});counts.textContent=total?text.total+': '+total+' · '+Object.keys(tally).map(function(key){return text[key]+' '+tally[key];}).join(' · '):'';counts.hidden=!total;
      var shown=manager.tasks.slice(page*PAGE,page*PAGE+PAGE),ids=new Set(shown.map(function(t){return t.id;}));rows.forEach(function(r,id){if(!ids.has(id)){r.box.remove();rows.delete(id);}});
      shown.forEach(function(task){var r=rows.get(task.id);if(!r){r=row(task);rows.set(task.id,r);list.append(r.box);}r.box.dataset.state=task.state;r.name.textContent=(task.directory?'▣ ':'')+task.path;r.name.title=task.workspaceName+' /'+task.path;r.state.textContent=text[task.state];r.progress.max=task.size||1;r.progress.value=task.state==='succeeded'?(task.size||1):Math.min(task.loaded,task.size?task.size*.995:0);r.progress.setAttribute('aria-label',task.path);r.metrics.textContent=(task.directory?'':bytes(task.loaded)+' / '+bytes(task.size)+' · '+text.speed+' '+bytes(task.speed)+'/s')+(task.error?' · '+text[task.error]:'');r.cancel.textContent=task.approval?text.approvalCancel:text.cancel;r.cancel.hidden=!pending(task);r.retry.textContent=text.retry;r.retry.title=text.whole;r.retry.hidden=pending(task)||task.state==='succeeded';r.retry.disabled=!manager.allowed({id:task.workspaceId,generation:task.generation});r.rename.textContent=text.rename;r.rename.hidden=task.directory||task.error!=='conflict';r.rename.disabled=r.retry.disabled;});
      paging.hidden=total<=PAGE;paging.setAttribute('aria-label',text.page);previous.textContent=text.previous;next.textContent=text.next;previous.disabled=!page;next.disabled=page>=max;range.textContent=(page*PAGE+1)+'–'+Math.min(total,(page+1)*PAGE)+' / '+total;
    }
    async function accept(read,target){if(!target)return;scanning++;notice='';render();try{var entries=await read();if(!entries.length)notice='skipped';else manager.enqueue(entries,target);}catch(e){notice=e.code||'scanFailed';}finally{scanning--;requestRender();}}
    files.onchange=function(){var selected=Array.from(files.files),target=selection;files.value='';accept(function(){return fileEntries(selected);},target);};folder.onchange=function(){var selected=Array.from(folder.files),target=selection;folder.value='';accept(function(){return fileEntries(selected);},target);};
    var surface=options.dropTarget||container;
    function fileDrag(event){return Array.from(event.dataTransfer&&event.dataTransfer.types||[]).indexOf('Files')>=0;}
    function drag(event){if(!fileDrag(event))return;event.preventDefault();var allowed=manager.allowed()&&!manager.suspended;event.dataTransfer.dropEffect=allowed?'copy':'none';container.classList.toggle('is-dragging',allowed);}
    function leave(event){if(!surface.contains(event.relatedTarget))container.classList.remove('is-dragging');}
    function drop(event){if(!fileDrag(event))return;event.preventDefault();container.classList.remove('is-dragging');var target=manager.snapshot();if(!target)return;var captured=captureDrop(event.dataTransfer);accept(function(){return scanDrop(captured);},target);}
    surface.addEventListener('dragover',drag);surface.addEventListener('dragleave',leave);surface.addEventListener('drop',drop);
    render();return {manager:manager,setContext:function(c){manager.setContext(c);},observe:function(c){manager.observe(c);},suspend:function(){manager.suspend();},revoke:function(reason){manager.revoke(reason);},setLocale:function(value){language=locale(value);render();},close:function(){manager.close();if(timer)root.clearTimeout(timer);surface.removeEventListener('dragover',drag);surface.removeEventListener('dragleave',leave);surface.removeEventListener('drop',drop);},render:render};
  }
  var api={Manager:Manager,mount:mount,validPath:validPath,fileEntries:fileEntries,captureDrop:captureDrop,scanDrop:scanDrop,messages:messages,locale:locale,requestId:requestId,MAX_TASKS:MAX_TASKS,PAGE:PAGE};
  if(typeof module==='object'&&module.exports)module.exports=api;root.LegnaDirectoryUpload=api;
})(typeof window==='object'?window:globalThis);
