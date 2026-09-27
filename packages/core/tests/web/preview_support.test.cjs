const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {mount,keys} = require('../../assets/web/preview-support.js');
const {domFixture} = require('./dom_fixture.cjs');
for(const locale of ['en','zh-CN','zh-TW','zh-HK']) test(`preview boundaries expose complete safe ${locale} copy`,()=>{
  const labels=require(`../../assets/web/i18n/${locale}.json`);
  const fixture=domFixture(),host=fixture.element('div');host.ownerDocument=fixture.document;
  host.replaceChildren=function(...nodes){this.textContent='';nodes.forEach(n=>this.appendChild(n));};
  fixture.document.body.appendChild(host);
  mount(host,labels);
  assert.equal(fixture.descendants().filter(n=>n.tag==='summary').length,1);
  assert.equal(host.children.length,1);assert.equal(host.children[0].tag,'details');
  assert.equal(host.children[0].open,undefined);
  assert.equal(fixture.descendants().filter(n=>n.tag==='p').length,keys.length+1);
  for(const key of keys)assert.ok(labels[key]?.length>30,key);
  assert.match(host.textContent,/UTF-16 LE\/BE/);assert.match(host.textContent,/GB18030\/GBK/);
  assert.match(host.textContent,/MP4\/M4V\/MOV/);assert.match(host.textContent,/HTML.*SVG.*PDF/);
  mount(host,{...labels,previewSupportHint:'<img src=x onerror=alert(1)>'});
  assert.equal(fixture.descendants().filter(n=>n.tag==='img'||n.tag==='script').length,0);
  assert.equal(fixture.descendants().filter(n=>n.tag==='details').length,1);
});
test('both production preview entries load local guidance outside releasable media content',()=>{
  for(const [file,prefix] of [['download.html','preview'],['directories.html','directory-preview']]){
    const html=fs.readFileSync(require.resolve('../../assets/web/'+file),'utf8');
    assert.match(html,/src="\/assets\/preview-support.js"/);
    assert.ok(html.includes(`id="${prefix}-support"`));
    assert.ok(html.includes(`id="${prefix}-download"`));
  }
  assert.match(fs.readFileSync(require.resolve('../../assets/web/directory-preview.js'),'utf8'),/LegnaPreviewSupport.mount\(\$\('support'\), labels.webUi\)/);
});
