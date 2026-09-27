'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const assets = path.join(__dirname, '../../assets/web');
const ui = require(path.join(assets, 'directories.js'));
test('directory language selection covers simplified, traditional and fallback', () => {
  for (const value of ['zh-CN','zh-SG','zh-Hans']) assert.equal(ui.locale(value), 'zh-CN');
  for (const value of ['zh-TW','zh-Hant']) assert.equal(ui.locale(value), 'zh-TW');
  assert.equal(ui.locale('zh-HK'), 'zh-HK');
  assert.equal(ui.messages['zh-HK'], ui.messages['zh-TW']);
  for (const value of ['en','de','ar']) assert.equal(ui.locale(value), 'en');
});
test('directory translations contain the same complete nonempty keys', () => {
  const keys = Object.keys(ui.messages.en).sort();
  for (const values of Object.values(ui.messages)) {
    assert.deepEqual(Object.keys(values).sort(), keys);
    assert.ok(Object.values(values).every(value => typeof value === 'string' && value.length));
  }
});
test('relative path joining retains Unicode and literal file names', () => {
  assert.equal(ui.filePath('', '文档'), '文档');
  assert.equal(ui.filePath('文档', '<script>.txt'), '文档/<script>.txt');
});
test('directory UI uses external assets and text nodes for user-controlled names', () => {
  const html = fs.readFileSync(path.join(assets, 'directories.html'),'utf8');
  const js = fs.readFileSync(path.join(assets, 'directories.js'),'utf8');
  assert.ok(html.includes('src="/assets/directories.js"'));
  assert.ok(!js.includes('innerHTML'));
  assert.ok(!js.includes('alert('));
  assert.ok(js.includes('textContent=value'));
  assert.ok(js.includes('encodeURIComponent(item.id)'));
  assert.ok(js.includes('if(active!==epoch)return'));
});
test('pagination bounds DOM work, serializes fetches and retains a manual load path', () => {
  const js = fs.readFileSync(path.join(assets, 'directories.js'),'utf8');
  assert.ok(js.includes('Math.ceil(viewport.clientHeight/rowHeight)+10'));
  assert.ok(js.includes('loading||finished'));
  assert.ok(js.includes("$('more').addEventListener('click',next)"));
  assert.ok(js.includes('staleRetry++<1'));
  assert.ok(js.includes('controller.abort()'));
});
test('workspace unlock uses an in-page dialog and POST without script-readable credential storage', () => {
  const html = fs.readFileSync(path.join(assets, 'directories.html'),'utf8');
  const js = fs.readFileSync(path.join(assets, 'directories.js'),'utf8');
  assert.ok(html.includes('<dialog id="auth"'));
  assert.ok(html.includes('type="password"'));
  assert.ok(js.includes("routeUrl()+'/unlock'"));
  assert.ok(js.includes("method:'POST'"));
  assert.ok(js.includes("headers:{'Content-Type':'application/json'}"));
  assert.ok(!js.includes('document.cookie'));
  assert.ok(!js.includes('sessionStorage'));
  assert.ok(js.includes('active!==authEpoch'));
});
