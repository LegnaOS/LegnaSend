const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../../assets/web/download.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function fixture() {
  const nodes = new Map();
  const document = { body: { style: { overflow: 'auto' } }, activeElement: null };
  function element(tag) {
    let inner = '';
    const node = { tag, style: {}, attributes: {}, children: [], className: '', textContent: '', paused: 0, loaded: 0,
      getAttribute(key) { return this.attributes[key] ?? null; },
      setAttribute(key, value) { this.attributes[key] = value; },
      removeAttribute(key) { delete this.attributes[key]; if (key === 'src') this.src = ''; },
      appendChild(child) { this.children.push(child); },
      focus() { document.activeElement = this; },
    };
    Object.defineProperty(node, 'innerHTML', { get() { return inner; }, set(value) { inner = value; this.children = []; } });
    if (tag === 'video' || tag === 'audio') Object.assign(node, { canPlayType: () => 'maybe', pause() { this.paused++; }, load() { this.loaded++; } });
    return node;
  }
  document.createElement = element;
  document.getElementById = id => { if (!nodes.has(id)) nodes.set(id, element('div')); return nodes.get(id); };
  const handlers = {};
  document.addEventListener = (name, fn) => handlers['document:' + name] = fn;
  const webUI = { backgroundInert: () => () => {}, mountFiles(options) { this.mounted = options; return { close() {} }; } };
  const sandbox = { document, window: { LegnaWebUI: webUI, addEventListener: (name, fn) => handlers[name] = fn }, sessionStorage: { getItem: () => null, setItem() {} }, location: { search: '', href: 'http://fixture/' }, URL, AbortController, setTimeout, clearTimeout, fetch: async url => ({ok:true,status:200,headers:{get:key=>key==='ETag'?'\"'+'a'.repeat(64)+'\"':String(url.includes('video')?100:40)}}), XMLHttpRequest: function() { this.open = this.send = () => {}; } };
  sandbox.window.LegnaImageSource = {inspect:async url=>({url})};
  vm.createContext(sandbox); vm.runInContext(script, sandbox);
  sandbox.sessionId = 'session token';
  sandbox.previewFiles = {
    video: { fileName: 'Video.mp4', fileType: 'video/mp4', size: 100 },
    image: { fileName: '<img src=x onerror=alert(1)>.png', fileType: 'image/png', size: 20 },
    audio: { fileName: 'Audio.wav', fileType: 'audio/wav', size: 40 },
    active: { fileName: 'active.svg', fileType: 'image/svg+xml', size: 50 },
  };
  return { api: sandbox, document, handlers, element };
}

test('file list receives stable source identities and the supported preview classifier', async () => {
  const { api } = fixture();
  api.handleFilesDisplay(api.previewFiles, api.sessionId);
  const mounted = api.window.LegnaWebUI.mounted;
  assert.equal(mounted.files, api.previewFiles);
  assert.equal(mounted.onPreview, api.showPreview);
  assert.equal(mounted.previewKind('text/html'), null);
  assert.equal(mounted.previewKind('image/svg+xml'), null);
  assert.equal(mounted.previewKind('application/octet-stream'), null);
});

test('media loads metadata only; switching and closing release the previous source', async () => {
  const { api, document, element } = fixture();
  const trigger = element('button');
  await api.showPreview('video', trigger);
  const video = api.activeMedia;
  assert.equal(video.preload, 'metadata'); assert.equal(video.controls, true); assert.equal(video.playsInline, true);
  assert.match(video.src, /sessionId=session(?:%20|\+)token&fileId=video&preview=1(?:&version=.+)?$/);
  const staleError = video.onerror;
  await api.showPreview('image', trigger);
  assert.equal(video.paused, 1); assert.equal(video.loaded, 1); assert.equal(video.src, '');
  const image = api.activeMedia;
  assert.equal(document.getElementById('preview-title').textContent, api.previewFiles.image.fileName);
  image.onload(); staleError();
  assert.equal(document.getElementById('preview-status').textContent, '');
  api.closePreview();
  assert.equal(image.src, ''); assert.equal(api.activeMedia, null);
  assert.equal(document.activeElement, trigger); assert.equal(document.body.style.overflow, 'auto');
});

test('errors, unsupported formats and page hide retain download fallback', async () => {
  const { api, document, handlers } = fixture();
  await api.showPreview('audio'); const failed = api.activeMedia; failed.onerror();
  assert.equal(api.activeMedia, null); assert.equal(failed.src, ''); assert.equal(failed.paused, 1);
  assert.equal(document.getElementById('preview-content').children.length, 0);
  assert.equal(document.getElementById('preview-status').textContent, api.previewLabels.previewError);
  assert.match(document.getElementById('preview-download').href, /fileId=audio$/);
  handlers.pagehide(); assert.equal(api.activeMedia, null);
  await api.showPreview('active');
  assert.equal(document.getElementById('preview-status').textContent, api.previewLabels.previewUnsupported);
  assert.equal(document.getElementById('preview-content').children.length, 0);
});

test('unsupported codecs do not start requests and localized labels retain fallback', async () => {
  const { api, document, element } = fixture();
  api.i18n = { preview: '预览', closePreview: '关闭预览' };
  document.createElement = tag => {
    const node = element(tag);
    if (tag === 'video') node.canPlayType = () => '';
    return node;
  };
  await api.showPreview('video');
  assert.equal(api.activeMedia.src, undefined);
  assert.equal(document.getElementById('preview-content').children.length, 0);
  assert.equal(document.getElementById('preview-status').textContent, api.previewLabels.previewUnsupported);
  assert.equal(document.getElementById('preview-close').textContent, '关闭预览');
  assert.equal(document.getElementById('preview-download').textContent, 'Download original');
  api.closePreview();
});

test('replacing the file list closes active previews and encodes file identities', async () => {
  const { api, document } = fixture();
  await api.showPreview('audio');
  const media = api.activeMedia;
  const id = 'a"&<b>';
  api.handleFilesDisplay({ [id]: { fileName: 'one.png', fileType: 'image/png', size: 1 } }, api.sessionId);
  const mounted = api.window.LegnaWebUI.mounted;
  assert.equal(media.src, '');
  assert.ok(mounted.files[id]);
  assert.match(mounted.downloadUrl(id), /fileId=a%22%26%3Cb%3E/);
});

test('keyboard dismissal restores focus and modal tabbing stays inside', async () => {
  const { api, document, element } = fixture();
  const trigger = element('button'); await api.showPreview('image', trigger);
  const overlay = document.getElementById('preview-overlay');
  const first = document.getElementById('preview-close');
  const last = document.getElementById('preview-download');
  let prevented = 0;
  first.focus(); overlay.onkeydown({ key: 'Tab', shiftKey: true, preventDefault() { prevented++; } });
  assert.equal(document.activeElement, last);
  overlay.onkeydown({ key: 'Tab', shiftKey: false, preventDefault() { prevented++; } });
  assert.equal(document.activeElement, first);
  overlay.onkeydown({ key: 'Escape', preventDefault() { prevented++; } });
  assert.equal(document.activeElement, trigger); assert.equal(prevented, 3);
});

test('text preview uses the approved URL and closes its reader when switching media', async () => {
  const { api } = fixture();
  let mounted, closed = 0;
  api.window.LegnaTextPreview = { mount(options) { mounted = options; return { close() { closed++; } }; } };
  api.previewFiles.text = { fileName: 'notes.txt', fileType: 'text/plain; charset=utf-8', size: 90000 };
  await api.showPreview('text');
  assert.equal(mounted.size, 90000);
  assert.match(mounted.url, /sessionId=session%20token&fileId=text&preview=1(?:&version=.+)?$/);
  assert.equal(api.activeMedia, null);
  await api.showPreview('image'); assert.equal(closed, 1); assert.equal(api.activeText, null);
  assert.equal(api.previewKind('application/octet-stream', 'RAW.TXT'), 'text');
  assert.equal(api.previewKind('text/html', 'active.txt'), null);
});

test('Markdown is previewable alongside TXT and explicitly enables Markdown mode', async () => {
  const { api } = fixture(); let options;
  api.window.LegnaTextPreview = { mount(value) { options = value; return { close() {} }; } };
  for (const mime of ['text/markdown', 'text/x-markdown', 'text/plain', 'application/octet-stream']) assert.equal(api.previewKind(mime, 'README.MD'), 'markdown');
  assert.equal(api.previewKind('text/html', 'unsafe.md'), null);
  api.previewFiles.markdown = { fileName: 'README.md', fileType: 'text/markdown', size: 1234 }; await api.showPreview('markdown');
  assert.equal(options.markdown, true); assert.equal(options.size, 1234); api.closePreview();
});


test('hidden pages release temporary preview content without ending the sharing session', async () => {
  const {api, document, handlers} = fixture();
  await api.showPreview('image'); const image = api.activeMedia, session = api.sessionId;
  document.hidden = true; handlers['document:visibilitychange']();
  assert.equal(api.activeMedia, null); assert.equal(image.src, ''); assert.equal(api.sessionId, session);
  assert.equal(document.getElementById('preview-overlay').className, '');
});

test('failed media offers a working retry that checks source metadata again',async()=>{
 const {api,document}=fixture();await api.showPreview('audio');const old=api.activeMedia;old.onerror();
 const retry=document.getElementById('preview-retry');assert.equal(retry.hidden,false);let heads=0;
 const previous=api.fetch;api.fetch=async(...args)=>{heads++;return previous(...args);};await retry.onclick();
 assert.equal(heads,1);assert.notEqual(api.activeMedia,old);assert.equal(retry.hidden,true);assert.equal(old.src,'');api.closePreview();
});
test('withdrawn media remains a source-change error without assigning a decoder URL',async()=>{
 const {api,document}=fixture();api.uiLabels.previewSourceChanged='Source changed';api.fetch=async()=>({ok:false,status:410});await api.showPreview('video');
 assert.equal(api.activeMedia,null);assert.equal(document.getElementById('preview-status').textContent,'Source changed');assert.equal(document.getElementById('preview-retry').hidden,false);
});
