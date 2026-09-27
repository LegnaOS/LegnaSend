'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../../assets/web/directories.js'),'utf8');
const body=source.match(/  function resumeBrowsing\(\)\{[\s\S]*?\n  \}/)[0];
function fixture(overrides={}){const events=[],nodes={auth:{open:false},unlock:{hidden:true}},controller=new AbortController();controller.abort();const sandbox={controller,AbortController,authBusy:false,workspace:{id:'workspace'},stamp:null,$:id=>nodes[id],load:value=>events.push(['load',value]),scheduleProbe:value=>events.push(['probe',value]),...overrides};vm.createContext(sandbox);vm.runInContext(body,sandbox);return {sandbox,nodes,events,resume:()=>sandbox.resumeBrowsing()};}
test('foreground resume leaves an open PIN modal and its auth request untouched',()=>{const f=fixture();f.nodes.auth.open=true;f.resume();assert.deepEqual(f.events,[]);assert.equal(f.sandbox.controller.signal.aborted,false);});
test('network recovery does not reload a locked workspace with no listing stamp',()=>{const f=fixture();f.nodes.unlock.hidden=false;f.resume();assert.deepEqual(f.events,[]);});
test('pending authentication suppresses listing restoration',()=>{const f=fixture({authBusy:true});f.resume();assert.deepEqual(f.events,[]);});
test('unlocked incomplete browsing reloads while existing listings only schedule a probe',()=>{const a=fixture();a.resume();assert.deepEqual(a.events,[['load',true]]);const b=fixture({stamp:'stamp'});b.resume();assert.deepEqual(b.events,[['probe',true]]);});
