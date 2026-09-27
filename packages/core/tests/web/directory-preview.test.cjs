'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const api = require('../../assets/web/directory-preview.js');
const tag = '"' + 'a'.repeat(64) + '"';
function response(headers = {}, status = 200) {
  return new Response(null, {status, headers: {'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': '10', 'Accept-Ranges': 'bytes', ETag: tag, ...headers}});
}
test('directory preview classification excludes active documents and preserves literal Unicode names', () => {
  for (const [name, kind] of [['资料.MD','markdown'],['文档.txt','text'],['video.MP4','video'],['music.opus','audio'],['photo.AVIF','img']]) assert.equal(api.kind(name),kind);
  for (const name of ['html','data.html','image.svg','code.js','file.pdf','name.txt.exe','source.ls']) assert.equal(api.kind(name),null);
});
test('preview metadata enforces size, strong resource version, byte ranges and inline allowlist', () => {
  assert.deepEqual(api.metadata(response(), {name:'readme.md',size:10}), {kind:'markdown',mime:'text/plain',tag});
  assert.throws(()=>api.metadata(response({'Content-Length':'11'}), {name:'notes.txt',size:10}), {status:412});
  assert.throws(()=>api.metadata(response({'Content-Length':''}), {name:'notes.txt',size:0}), {status:412});
  for(const headers of [{ETag:'*'}, {ETag:'W/'+tag}, {'Accept-Ranges':'none'}, {'Content-Type':'text/html'}])
    assert.throws(()=>api.metadata(response(headers), {name:'notes.txt',size:10}));
  assert.throws(()=>api.metadata(response({},401), {name:'notes.txt',size:10}), {status:401});
  assert.throws(()=>api.metadata(response({'Content-Type':'image/svg+xml'}),{name:'raster.png',size:10}));
});
test('media URLs pin the version on the same origin, not a password or bearer grant', () => {
  const result = api.pinnedUrl('/api/legnasend/v1/workspaces/id/files/encoded/content?generation=3',tag,'http://127.0.0.1:53317/design/');
  const query = new URL(result,'http://127.0.0.1:53317').searchParams;
  assert.equal(query.get('generation'),'3');assert.equal(query.get('version'),tag);assert.equal(query.get('preview'),'1');
  assert.throws(()=>api.pinnedUrl('https://example.invalid/file',tag,'http://127.0.0.1:53317/'));
  assert.throws(()=>api.pinnedUrl('/content','"bad"','http://127.0.0.1:53317/'));
});
