'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assets=path.join(__dirname,'../../assets/web');
function fixture(saved=null,throws=false) {
  const events={},attr={},writes=[],messages=[],media={matches:true,addEventListener:(name,fn)=>events.media=fn};
  const parent={location:{origin:'http://fixture'}};
  const context={document:{documentElement:{lang:'en',setAttribute:(k,v)=>attr[k]=v,getAttribute:k=>attr[k]},readyState:'loading',
    querySelectorAll:()=>[{contentWindow:{postMessage:(data,origin)=>messages.push({data,origin})}}],addEventListener:(k,fn)=>events[k]=fn},
    parent,location:{origin:'http://fixture'},localStorage:{getItem:()=>{if(throws)throw Error('storage');return saved;},setItem:(k,v)=>{if(throws)throw Error('storage');writes.push([k,v]);}},
    matchMedia:()=>media,addEventListener:(k,fn)=>events[k]=fn,dispatchEvent:event=>events[event.type]?.(event),CustomEvent:class{constructor(type,options){this.type=type;this.detail=options.detail;}}};
  context.window=context;vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(assets,'theme.js'),'utf8'),context);
  return {api:context.LegnaTheme,context,events,attr,writes,messages,media,parent};
}
test('theme follows the OS by default; explicit choices persist and override OS changes',()=>{
  const f=fixture();assert.equal(f.attr['data-theme'],'dark');f.api.set('light');assert.equal(f.attr['data-theme'],'light');
  f.events.media();assert.equal(f.attr['data-theme'],'light');assert.equal(f.writes[0][1],'light');
  f.api.set('system');f.media.matches=false;f.events.media();assert.equal(f.attr['data-theme'],'light');
});
test('invalid or unavailable storage never blocks a visible theme or manual choice',()=>{
  for(const [value,throws] of [['invalid',false],[null,true]]){const f=fixture(value,throws);assert.equal(f.api.preference(),'system');f.api.set('light');assert.equal(f.api.resolved(),'light');}
});
test('storage events synchronize the current page but reject unrelated keys and values',()=>{
  const f=fixture('light');f.events.storage({key:'unrelated',newValue:'dark'});assert.equal(f.api.resolved(),'light');
  f.events.storage({key:'legnasend.webTheme',newValue:'dark'});assert.equal(f.api.resolved(),'dark');
  f.events.storage({key:'legnasend.webTheme',newValue:'invalid'});assert.equal(f.api.preference(),'dark');
  f.events.storage({key:'legnasend.webTheme',newValue:null});assert.equal(f.api.preference(),'system');
});
test('only a same-origin parent can synchronize an embedded preference; frames are not navigated',()=>{
  const f=fixture('light');const send=(source,origin,preference)=>f.events.message({source,origin,data:{type:'legna-theme',preference}});
  send(f.parent,'http://elsewhere','dark');assert.equal(f.api.resolved(),'light');send({},'http://fixture','dark');assert.equal(f.api.resolved(),'light');
  send(f.parent,'http://fixture','dark');assert.equal(f.api.resolved(),'dark');assert.equal(f.messages.at(-1).data.preference,'dark');assert.equal(f.messages.at(-1).origin,'http://fixture');
  assert.doesNotMatch(fs.readFileSync(path.join(assets,'theme.js'),'utf8'),/location\.(?:reload|replace|assign)\s*\(/);
});
function luminance(hex){const values=hex.replace('#','').match(/../g).map(v=>parseInt(v,16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return values.reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);}
function ratio(a,b){a=luminance(a);b=luminance(b);return(Math.max(a,b)+.05)/(Math.min(a,b)+.05);}
test('all semantic normal, muted, selected, warning, error and highlight text pairs meet 4.5 to 1',()=>{
  const css=fs.readFileSync(path.join(assets,'theme.css'),'utf8');let vars={};
  for(const selector of [':root[data-theme]',':root[data-theme="dark"]']) {
    const start=css.indexOf(selector+' {'),body=css.slice(start,css.indexOf('}',start));
    for(const match of body.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})/g))vars[match[1]]=match[2];
    const pairs=[['ink','paper'],['ink','wash'],['ink','soft'],['muted','paper'],['muted','wash'],['muted','soft'],['tag-ink','tag-bg'],['link-ink','paper'],['link-ink','soft'],['danger','paper'],['danger','error-bg'],['warning-ink','warning-bg'],['ink','match-bg'],['ink','current-match-bg']];
    for(const [fg,bg] of pairs) assert.ok(ratio(vars[fg],vars[bg])>=4.5,`${selector} ${fg}/${bg}: ${ratio(vars[fg],vars[bg])}`);
  }
  assert.ok(ratio('#102d19','#54b865')>=4.5);
});
test('sharing pages load theme before content, all CSS supports explicit mode, and selectors have four locales',()=>{
  for(const name of ['workspace.html','download.html','upload.html','directories.html','error-403.html']){
    const html=fs.readFileSync(path.join(assets,name),'utf8');assert.ok(html.indexOf('/assets/theme.js')<html.indexOf('</head>'));assert.match(html,/data-theme-control/);assert.match(html,/\/assets\/theme.css/);
  }
  for(const name of ['web-ui.css','directories.css','text-reader.css','persistent-downloads.css','image-preview.css','diagram-preview.css','directory-preview.css']) assert.doesNotMatch(fs.readFileSync(path.join(assets,name),'utf8'),/prefers-color-scheme/);
  for(const locale of ['en','zh-CN','zh-TW','zh-HK']){const text=JSON.parse(fs.readFileSync(path.join(assets,'i18n',locale+'.json')));for(const key of ['theme','themeSystem','themeLight','themeDark'])assert.ok(text[key]);}
});
