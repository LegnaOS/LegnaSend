const {test} = require('node:test');
const assert = require('node:assert/strict');
const api = require('../../assets/web/media-preview.js');
const wait = (ms=170) => new Promise(r=>setTimeout(r,ms));
function fixture(tag='video') {
 const snapshots=[];
 const doc={createElement(kind){
   const listeners=new Map(),attrs={};
   const node={tagName:kind.toUpperCase(),ownerDocument:doc,children:[],dataset:{},style:{setProperty(k,v){this[k]=v;}},hidden:false,
     attributes:attrs,textContent:'',setAttribute(k,v){attrs[k]=String(v);},getAttribute(k){return attrs[k]??null;},removeAttribute(k){delete attrs[k];},
     appendChild(n){n.parent=this;this.children.push(n);},replaceWith(n){n.parent=this.parent;this.parent.children=this.parent.children.map(x=>x===this?n:x);this.parent=null;},remove(){if(this.parent)this.parent.children=this.parent.children.filter(n=>n!==this);},
     addEventListener(k,f){if(!listeners.has(k))listeners.set(k,new Set());listeners.get(k).add(f);},removeEventListener(k,f){listeners.get(k)?.delete(f);},
     emit(k){for(const f of listeners.get(k)||[])f();},listenerCount(){return [...listeners.values()].reduce((n,s)=>n+s.size,0);}};
   for(const key of ['src','poster'])Object.defineProperty(node,key,{get(){return attrs[key]||'';},set(v){attrs[key]=v;}});
   if(kind==='canvas')Object.assign(node,{width:0,height:0,getContext:()=>({drawImage(){}}),toDataURL(){snapshots.push([this.width,this.height]);return 'data:image/jpeg;fixture';}});
   if(['video','audio'].includes(kind))Object.assign(node,{paused:true,currentTime:0,duration:60,volume:.37,muted:true,playbackRate:1.5,readyState:4,
     videoWidth:kind==='video'?3840:0,videoHeight:kind==='video'?2160:0,seeking:false,ended:false,loads:0,
     pause(){this.paused=true;this.emit('pause');},load(){this.loads++;this.currentTime=0;this.readyState=0;},
     play(){this.paused=false;this.emit('play');return this.playPromise||Promise.resolve();}});
   return node;
 }};
 const media=doc.createElement(tag),container=doc.createElement('div');
 const controller=api.mount({container,media,url:'/same-origin?token=fixed',labels:{mediaPlay:'播放',mediaResume:'继续播放',mediaPosition:'播放位置',mediaPaused:'暂停'}});
 return {get media(){return controller.element();},container,controller,snapshots,doc,tools:container.children[0].children[1]};
}
test('initial metadata reads are explicitly released with bounded poster and a usable localized play control',async()=>{
 const f=fixture();assert.equal(f.media.preload,'metadata');assert.equal(f.media.controls,true);assert.equal(f.media.src,'/same-origin?token=fixed');
 f.media.emit('loadedmetadata');await wait();
 assert.equal(f.controller.snapshot().detached,true);assert.equal(f.media.src,'');assert.deepEqual(f.snapshots,[[640,360]]);
 assert.equal(f.tools.hidden,false);assert.equal(f.tools.children[0].textContent,'播放');assert.equal(f.tools.children[1].getAttribute('aria-label'),'播放位置');
 f.tools.children[1].value='42.5';f.tools.children[1].oninput();
 await f.controller.resume();f.media.duration=60;f.media.playbackRate=1;f.media.emit('loadedmetadata');
 assert.equal(f.media.currentTime,42.5);assert.equal(f.media.volume,.37);assert.equal(f.media.playbackRate,1.5);assert.equal(f.media.muted,true);
 assert.equal(f.tools.hidden,true);assert.equal(f.media.src,'/same-origin?token=fixed');f.controller.close();
 assert.equal(f.media.listenerCount(),0);assert.equal(f.media.poster,'');assert.equal(f.container.children.length,0);
});
test('native pause does not tear down an in-progress seek; stable pause preserves the sought position',async()=>{
 const f=fixture();await f.media.play();f.media.currentTime=9;f.media.seeking=true;f.media.pause();await wait();
 assert.notEqual(f.media.src,'');f.media.currentTime=35;f.media.seeking=false;f.media.emit('seeked');await wait();
 assert.equal(f.media.src,'');assert.equal(f.controller.snapshot().time,35);assert.equal(f.tools.children[0].textContent,'继续播放');f.controller.close();
});
test('autoplay rejection preserves the desired seek and stops its failed request without unhandled errors',async()=>{
 const f=fixture('audio');f.media.emit('loadedmetadata');await wait();
 f.tools.children[1].value='30';f.tools.children[1].oninput();f.media.playPromise=Promise.reject(new Error('NotAllowedError'));
 await f.controller.resume();assert.equal(f.media.src,'');assert.equal(f.controller.snapshot().time,30);assert.equal(f.tools.hidden,false);
 assert.deepEqual(f.snapshots,[]);f.controller.close();
});
test('a late rejected play promise after replacement never clears the new player',async()=>{
 const old=fixture();old.media.emit('loadedmetadata');await wait();
 let reject;old.media.playPromise=new Promise((_,r)=>reject=r);const pending=old.controller.resume();
 const current=fixture('audio');assert.equal(old.media.src,'');assert.equal(old.media.listenerCount(),0);
 reject(new Error('late AbortError'));await pending;assert.equal(current.media.src,'/same-origin?token=fixed');assert.equal(current.controller.snapshot().closed,false);
 old.controller.close();current.controller.close();
});
test('ended playback releases resources and restarts from zero; repeated close is idempotent',async()=>{
 const f=fixture();await f.media.play();f.media.currentTime=60;f.media.ended=true;f.media.emit('ended');
 assert.equal(f.controller.snapshot().time,0);assert.equal(f.tools.children[0].textContent,'播放');assert.equal(f.media.src,'');
 const last=f.media, loads=last.loads;f.controller.close();f.controller.close();assert.equal(last.loads,loads+1);
});
test('rapid pause then play keeps current native controls and cancels the release timer',async()=>{
 const f=fixture();await f.media.play();f.media.pause();await f.media.play();await wait();
 assert.notEqual(f.media.src,'');assert.equal(f.controller.snapshot().detached,false);assert.equal(f.media.controls,true);f.controller.close();
});
test('native fullscreen and picture-in-picture retain native resume until they exit',async()=>{
 for(const property of ['fullscreenElement','pictureInPictureElement']){
  const f=fixture();await f.media.play();f.doc[property]=f.media;f.media.pause();await wait();
  assert.notEqual(f.media.src,'');assert.equal(f.media.controls,true);
  f.doc[property]=null;f.media.emit('leavepictureinpicture');await wait();assert.equal(f.media.src,'');f.controller.close();
 }
});
test('pause remembers the event position before an asynchronous native rate/clock reset',async()=>{
 const f=fixture();await f.media.play();f.media.currentTime=42.3;f.media.playbackRate=1.25;f.media.pause();
 // Observed in WebKit: the paused AV clock can return to zero after a rate
 // change, before our 120ms source-release grace period has elapsed.
 f.media.currentTime=0;await wait();assert.equal(f.controller.snapshot().time,42.3);
 await f.controller.resume();f.media.duration=60;f.media.emit('loadedmetadata');assert.equal(f.media.currentTime,42.3);f.controller.close();
});

test('pause retires the old native resource owner instead of reusing its loader',async()=>{
 const f=fixture();const old=f.media;await old.play();old.currentTime=19;old.pause();await wait();
 assert.notEqual(f.media,old);assert.equal(old.parent,null);assert.equal(old.src,'');assert.equal(old.listenerCount(),0);
 await f.controller.resume();assert.equal(f.media.src,'/same-origin?token=fixed');f.media.emit('loadedmetadata');assert.equal(f.media.currentTime,19);f.controller.close();
});
