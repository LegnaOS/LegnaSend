(function (root) {
  'use strict';
  var MAX_ENTRIES=1000, MAX_BYTES=4*1024*1024, MAX_PAGES=16, MAX_HISTORY=64;
  function Window() { this.reset(); }
  Window.prototype.reset=function(offset,history){this.pages=[];this.history=(history||[]).slice(-MAX_HISTORY);this.offset=offset||0;this.bytes=0;this.length=0;};
  Window.prototype.append=function(page,requestCursor){
    if(!page||!Array.isArray(page.entries)||page.entries.length>100||!(page.cursor===null||typeof page.cursor==='string'&&page.cursor.length<=128))throw new Error('Invalid directory page');
    page.entries.forEach(function(entry){if(!entry||typeof entry.id!=='string'||typeof entry.name!=='string'||typeof entry.directory!=='boolean'||(!(Number.isSafeInteger(entry.size)&&entry.size>=0)&&!(entry.size===null&&(entry.directory||entry.downloadable===false))))throw new Error('Invalid directory entry');});
    var bytes=JSON.stringify(page.entries).length*2;
    if(bytes>MAX_BYTES)throw new Error('Directory page exceeds metadata budget');
    // Empty scan continuations hold no visible metadata. Retaining them would
    // evict rare search matches solely because many later entries do not match.
    if(page.entries.length===0)return 0;
    var before=this.offset;
    this.pages.push({entries:page.entries,bytes:bytes,start:this.offset+this.length,cursor:requestCursor||null});
    this.bytes+=bytes;this.length+=page.entries.length;
    while(this.pages.length>1&&(this.length>MAX_ENTRIES||this.bytes>MAX_BYTES||this.pages.length>MAX_PAGES)){
      var old=this.pages.shift();this.history.push({start:old.start,cursor:old.cursor});
      if(this.history.length>MAX_HISTORY)this.history.shift();
      this.offset+=old.entries.length;this.length-=old.entries.length;this.bytes-=old.bytes;
    }
    return this.offset-before;
  };
  Window.prototype.items=function(){return [].concat.apply([],this.pages.map(function(p){return p.entries;}));};
  Window.prototype.previous=function(){return this.history.length?this.history.pop():null;};
  function prefetchDistance(height,velocity,latency){return Math.max(312,Math.min(height*2,312+Math.max(0,velocity)*Math.min(3000,Math.max(0,latency))*1.5));}
  function delay(unchanged,latency,failed){return Math.min(30000,Math.max(5000,latency*4,5000*Math.pow(2,Math.min(3,failed||unchanged||0))));}
  function probeIds(items,start,count,budget){
    budget=Math.min(6000,budget===undefined?6000:Math.max(0,budget));
    var result=[],size=0;
    for(var i=Math.max(0,start);i<Math.min(items.length,start+count)&&result.length<64;i++){
      var id=items[i].id, next=encodeURIComponent(id).length+3;
      if(size+next>budget)break;
      result.push(id);size+=next;
    }
    return result;
  }
  var api={Window:Window,prefetchDistance:prefetchDistance,delay:delay,probeIds:probeIds,limits:{entries:MAX_ENTRIES,bytes:MAX_BYTES,pages:MAX_PAGES,history:MAX_HISTORY}};
  if(typeof module==='object')module.exports=api;
  root.LegnaDirectoryWindow=api;
})(typeof window==='object'?window:globalThis);
