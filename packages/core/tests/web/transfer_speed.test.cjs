const { test } = require('node:test');
const assert = require('node:assert/strict');
const { RateMeter, bytesLabel, uploadFile } = require('../../assets/web/web-upload.js');

test('recent rate includes small files, decays to zero on stalls and resets on counter regression', () => {
  const meter = new RateMeter(); assert.equal(meter.sample(0, 0), null);
  assert.equal(meter.sample(500, 500), 1000);
  for (let time = 1000; time <= 3500; time += 500) meter.sample(500, time);
  assert.equal(meter.sample(500, 4000), 0);
  assert.equal(meter.sample(0, 4500), null); assert.equal(meter.sample(2000, 5000), 4000);
  assert.equal(meter.sample(100, 1), null); assert.equal(meter.sample(100, 1), null);
  assert.equal(bytesLabel(1_500_000) + '/s', '1.5 MB/s'); assert.equal(bytesLabel(0), '0 B');
});

test('meter memory is bounded even with unexpectedly frequent samples', () => {
  const meter = new RateMeter(); for (let i = 0; i < 10000; i++) meter.sample(i, i);
  assert.ok(meter.samples.length <= 32);
});

function xhrFixture() {
  return { upload: {}, status: 200, aborted: false,
    open(...args) { this.opened = args; }, send(body) { this.body = body; }, abort() { this.aborted = true; this.onabort?.(); } };
}
test('upload keeps the original file and URL, clamps byte progress and waits for server acknowledgement', async () => {
  const xhr = xhrFixture(), file = { size: 100 }, progress = [], controller = new AbortController(); let settled = false;
  const task = uploadFile('/api/localsend/v2/upload?sessionId=s&fileId=f&token=t', file,
    { createXhr: () => xhr, signal: controller.signal, onProgress: n => progress.push(n) }).then(value => { settled = true; return value; });
  assert.deepEqual(xhr.opened, ['POST', '/api/localsend/v2/upload?sessionId=s&fileId=f&token=t', true]); assert.equal(xhr.body, file);
  xhr.upload.onprogress({ loaded: 50 }); xhr.upload.onprogress({ loaded: 999 }); await Promise.resolve();
  assert.deepEqual(progress, [50, 100]); assert.equal(settled, false);
  xhr.onload(); assert.equal((await task).status, 200); assert.equal(xhr.upload.onprogress, null);
  controller.abort(); assert.equal(xhr.aborted, false);
});
test('abort, network failure and non-200 responses settle once and remove stale progress handlers', async () => {
  const xhr = xhrFixture(), controller = new AbortController();
  const task = uploadFile('/upload', { size: 100 }, { createXhr: () => xhr, signal: controller.signal });
  controller.abort(); await assert.rejects(task, { name: 'AbortError' }); assert.equal(xhr.aborted, true); assert.equal(xhr.upload.onprogress, null);
  const failed = xhrFixture(), failure = uploadFile('/upload', {}, { createXhr: () => failed }); failed.onerror(); await assert.rejects(failure, /Upload failed/);
  const rejected = xhrFixture(), response = uploadFile('/upload', {}, { createXhr: () => rejected }); rejected.status = 403; rejected.onload(); assert.equal((await response).status, 403);
});
