(function(root){
  'use strict';
  function Watch(options){this.options=options;this.source=null;this.timer=0;this.generation=0;this.failures=0;this.closed=true;this.url='';}
  Watch.prototype.stop=function(){this.closed=true;this.generation++;if(this.timer)this.options.clearTimeout(this.timer);this.timer=0;if(this.source)this.source.close();this.source=null;};
  Watch.prototype.start=function(url){if(!this.closed&&this.url===url)return;this.stop();this.closed=false;this.url=url;this.connect();};
  Watch.prototype.connect=function(){
    if(this.closed||!this.options.EventSource)return;
    var self=this,epoch=this.generation,source;
    try{source=new this.options.EventSource(this.url,{withCredentials:true});}catch(_){this.retry(epoch);return;}
    this.source=source;
    function current(){return !self.closed&&self.generation===epoch&&self.source===source;}
    source.addEventListener('ready',function(){if(current()){self.failures=0;if(self.options.onReady)self.options.onReady();}});
    source.addEventListener('invalidate',function(){if(current())self.options.onChange();});
    source.onerror=function(){if(!current())return;source.close();self.source=null;if(self.options.onFallback)self.options.onFallback();self.retry(epoch);};
  };
  Watch.prototype.retry=function(epoch){var self=this;if(this.closed||this.generation!==epoch)return;var delay=Math.min(30000,1000*Math.pow(2,Math.min(5,this.failures++)));this.timer=this.options.setTimeout(function(){self.timer=0;if(!self.closed&&self.generation===epoch)self.connect();},delay);};
  if(typeof module==='object')module.exports={Watch:Watch};root.LegnaDirectoryEvents={Watch:Watch};
})(typeof window==='object'?window:globalThis);
