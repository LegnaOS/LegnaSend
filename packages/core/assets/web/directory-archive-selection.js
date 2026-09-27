/* Bounded metadata tickets for native browser selected-ZIP downloads. */
(function(root){
  'use strict';
  var MAX_ITEMS=20000,MAX_BYTES=2*1024*1024,MAX_TICKETS=4,UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
  var encoder=new TextEncoder(),inflightTotal=0;
  function failure(code,status){var e=new Error(code);e.code=code;if(status)e.status=status;return e;}
  function bytes(value){return encoder.encode(value).length;}
  function validId(id){return typeof id==='string'&&id.length>0&&id.length<=MAX_BYTES&&!/[\u0000-\u001f\u007f]/.test(id);}
  function Selection(path){this.items=new Map();this.clear(path||'');}
  Selection.prototype.clear=function(path){if(path!==undefined){if(typeof path!=='string'||bytes(path)>MAX_BYTES)throw failure('selection-limit');this.path=path;}this.items.clear();this.costs=new Map();this.idBytes=0;this.baseBytes=bytes(JSON.stringify({path:this.path,ids:[]}));if(this.baseBytes>MAX_BYTES)throw failure('selection-limit');};
  Selection.prototype.toggle=function(item,selected){
    if(!item||!validId(item.id))return false;
    if(!selected){if(this.items.delete(item.id)){this.idBytes-=this.costs.get(item.id);this.costs.delete(item.id);}return true;}
    if(item.downloadable===false&&!item.directory)return false;
    if(this.items.has(item.id))return true;
    var cost=bytes(JSON.stringify(item.id));
    if(this.items.size>=MAX_ITEMS||this.baseBytes+this.idBytes+cost+this.items.size>MAX_BYTES)return false;
    // Do not keep file bodies or every evicted page's full entry metadata.
    this.items.set(item.id,{id:item.id});this.costs.set(item.id,cost);this.idBytes+=cost;return true;
  };
  Selection.prototype.body=function(){if(!this.items.size)throw failure('empty-selection');return body(this.path,Array.from(this.items.keys()));};
  function body(path,ids){
    if(typeof path!=='string'||!Array.isArray(ids)||!ids.length||ids.length>MAX_ITEMS||new Set(ids).size!==ids.length||ids.some(function(id){return !validId(id);}))throw failure('selection-limit');
    var length=bytes(JSON.stringify({path:path,ids:[]}));if(length>MAX_BYTES)throw failure('selection-limit');
    for(var i=0;i<ids.length;i++){length+=bytes(JSON.stringify(ids[i]))+(i?1:0);if(length>MAX_BYTES)throw failure('selection-limit');}
    return JSON.stringify({path:path,ids:ids});
  }
  async function boundedJson(response){
    if(!response.ok){if(response.body)response.body.cancel().catch(function(){});throw failure('prepare-failed',response.status);}
    var reader=response.body&&response.body.getReader?response.body.getReader():null;if(!reader)throw failure('invalid-receipt');
    var chunks=[],size=0;
    try{while(true){var next=await reader.read();if(next.done)break;size+=next.value.length;if(size>8192)throw failure('invalid-receipt');chunks.push(next.value);}}
    catch(e){await reader.cancel().catch(function(){});throw e;}finally{reader.releaseLock();}
    var buffer=new Uint8Array(size),offset=0;chunks.forEach(function(chunk){buffer.set(chunk,offset);offset+=chunk.length;});
    try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(buffer));}catch(_){throw failure('invalid-receipt');}
  }
  function Controller(options){
    this.options=options;this.base=new URL(options.base||root.location.href);var route=new URL(options.route,this.base);
    if(route.origin!==this.base.origin||route.search||route.hash||!/^\/api\/legnasend\/v1\/workspaces\/[^/]+$/.test(route.pathname)||!Number.isSafeInteger(options.generation)||options.generation<1||typeof options.path!=='string')throw failure('invalid-scope');
    this.route=route.pathname;this.generation=options.generation;this.path=options.path;this.pending=null;this.closed=false;this.tickets=new Map();this.inflight=new Set();this.revoking=new Map();this.now=options.now||Date.now;
  }
  Controller.prototype.current=function(){return !this.closed&&(!this.options.isCurrent||this.options.isCurrent());};
  Controller.prototype.post=function(op,value,signal,keepalive){return this.options.fetch(this.route+'/'+op+'?generation='+this.generation,{method:'POST',credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json'},body:typeof value==='string'?value:JSON.stringify(value),signal:signal,keepalive:keepalive===true});};
  Controller.prototype.prune=function(){
    var now=this.now();this.tickets.forEach(function(ticket,id){if(!ticket.handedOff&&ticket.expiresAt<=now)this.tickets.delete(id);},this);
    // Admission expiry is not download completion. Keep handed-off cancellation
    // handles until explicit cancellation or a successful replacement handoff.
  };
  Controller.prototype.snapshot=function(){this.prune();return {preparing:!!this.pending,tickets:Array.from(this.tickets.values()).map(function(t){return {selection:t.selection,selectedEntries:t.selectedEntries,expiresAt:t.expiresAt,handedOff:t.handedOff};})};};
  Controller.prototype.notify=function(){if(this.options.onChange)this.options.onChange(this.snapshot());};
  Controller.prototype.revoke=function(selection,bestEffort){
    var self=this,pending=this.revoking.get(selection);
    if(!pending){
      var controller=new AbortController(),timer=setTimeout(function(){controller.abort();},2000);
      pending=Promise.resolve().then(function(){return self.post('cancel-archive',{selection:selection},controller.signal,true);}).then(function(response){
        if(response.body)response.body.cancel().catch(function(){});
        if(!response.ok&&response.status!==410)throw failure('cancel-failed',response.status);
        self.tickets.delete(selection);return true;
      }).finally(function(){clearTimeout(timer);self.revoking.delete(selection);self.notify();});
      this.revoking.set(selection,pending);
    }
    return bestEffort?pending.catch(function(){return false;}):pending;
  };
  Controller.prototype.cancel=function(selection){
    if(selection){if(!this.tickets.has(selection))return Promise.resolve(false);return this.revoke(selection).then(function(){return true;});}
    if(this.pending){this.pending.abandoned=true;this.pending=null;this.notify();}
    return Promise.resolve(true);
  };
  // Navigation/refresh/auth invalidation never silently cancels handed-off ZIPs.
  // A pending late receipt is still consumed and revoked within its deadline.
  Controller.prototype.close=function(){this.closed=true;return this.cancel();};
  Controller.prototype.download=function(ids){
    var self=this,request;
    if(!this.current())return Promise.reject(failure('stale'));
    try{request=body(this.path,ids);}catch(e){return Promise.reject(e);}
    if(this.pending)return this.pending.body===request?this.pending.promise:Promise.reject(failure('busy'));
    this.prune();var replace=null;
    if(this.tickets.size>=MAX_TICKETS){var now=this.now();replace=Array.from(this.tickets.values()).find(function(t){return t.handedOff&&t.expiresAt<=now;});if(!replace)return Promise.reject(failure('busy'));}
    if(inflightTotal>=MAX_TICKETS)return Promise.reject(failure('busy'));
    var op={body:request,abandoned:false,started:this.now(),controller:new AbortController(),promise:null,count:ids.length};this.pending=op;this.inflight.add(op);inflightTotal++;
    var timeoutReject,timer,deadline=new Promise(function(_,reject){timeoutReject=reject;});
    timer=setTimeout(function(){op.abandoned=true;op.controller.abort();if(self.pending===op){self.pending=null;self.notify();}timeoutReject(failure('timeout'));},this.options.timeout||12000);
    var work=(async function(){
      var selection=null;
      try{
        var value=await boundedJson(await self.post('prepare-archive',request,op.controller.signal,false));
        if(value&&typeof value.selection==='string'&&UUID.test(value.selection))selection=value.selection;
        if(!selection)throw failure('invalid-receipt');
        if(self.tickets.has(selection)){selection=null;throw failure('invalid-receipt');}
        if(op.abandoned||!self.current())throw failure('stale');
        var url=typeof value.downloadUrl==='string'?new URL(value.downloadUrl,self.base):null;
        if(!url||url.origin!==self.base.origin||url.pathname!==self.route+'/archive'||url.hash||url.username||url.password||
          url.searchParams.getAll('generation').length!==1||url.searchParams.get('generation')!==String(self.generation)||
          url.searchParams.getAll('selection').length!==1||url.searchParams.get('selection')!==selection||Array.from(url.searchParams.keys()).some(function(k){return k!=='generation'&&k!=='selection';})||
          !Number.isSafeInteger(value.expiresIn)||value.expiresIn<1||value.expiresIn>120||!Number.isSafeInteger(value.selectedEntries)||value.selectedEntries!==op.count)throw failure('invalid-receipt');
        var ticket={selection:selection,selectedEntries:value.selectedEntries,expiresAt:op.started+value.expiresIn*1000,handedOff:false,url:url.pathname+url.search};
        if(ticket.expiresAt<=self.now())throw failure('expired');
        // The handoff callback must synchronously click an ordinary download link.
        // It must not fetch or buffer the ZIP and must not claim download success.
        if(typeof self.options.handoff!=='function')throw failure('invalid-handoff');
        self.options.handoff(ticket.url);ticket.handedOff=true;if(replace)self.tickets.delete(replace.selection);self.tickets.set(selection,ticket);return Object.assign({},ticket);
      }catch(e){if(selection)await self.revoke(selection,true);throw e;}
      finally{clearTimeout(timer);self.inflight.delete(op);inflightTotal--;if(self.pending===op)self.pending=null;self.notify();}
    })();
    op.promise=Promise.race([work,deadline]);this.notify();return op.promise;
  };
  var api={Selection:Selection,Controller:Controller,body:body,limits:{items:MAX_ITEMS,bytes:MAX_BYTES,tickets:MAX_TICKETS,ttl:120}};
  if(typeof module==='object')module.exports=api;root.LegnaDirectoryArchiveSelection=api;
})(typeof window==='object'?window:globalThis);
