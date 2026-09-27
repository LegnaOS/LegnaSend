const { test } = require('node:test');
const assert = require('node:assert/strict');
const { collectDrop, namedFile, manifest } = require('../../assets/web/web-upload.js');
function file(name, content = name) { return { name, size: Buffer.byteLength(content), type: 'text/plain' }; }
function entry(name) { return { name, isFile: true, file: resolve => resolve(file(name)) }; }
function folder(name, groups) { return { name, isDirectory: true, createReader() { let i = 0; return { readEntries: resolve => resolve(groups[i++] || []) }; } }; }

test('dropped nested folders read all directory batches and preserve protocol-relative names', async () => {
  const root = folder('Folder', [[entry('a.txt')], [folder('nested', [[entry('b.txt')]])]]);
  const selected = await collectDrop({ items: [{ kind: 'file', webkitGetAsEntry: () => root }] });
  assert.deepEqual(selected.map(x => x.name).sort(), ['Folder/a.txt', 'Folder/nested/b.txt']);
  const built = await manifest(selected, 'test-fingerprint', 'http'); const dto = JSON.parse(built.body);
  assert.deepEqual(Object.keys(dto).sort(), ['files', 'info']);
  assert.deepEqual(dto.info, { alias: 'Web Browser', version: '2.1', deviceType: 'web', fingerprint: 'test-fingerprint', port: 0, protocol: 'http', download: false });
  assert.deepEqual(Object.keys(dto.files['0']).sort(), ['fileName', 'fileType', 'id', 'size']);
  assert.equal(dto.files['0'].fileName, selected[0].name); assert.equal(built.selected['0'], selected[0].file);
});

test('5,000 dropped files remain distinct without reading contents into memory', async () => {
  let reports = 0;
  const root = folder('small', Array.from({ length: 50 }, (_, group) => Array.from({ length: 100 }, (_, i) => entry(`${group * 100 + i}.txt`))));
  const selected = await collectDrop({ items: [{ webkitGetAsEntry: () => root }] }, () => reports++);
  assert.equal(selected.length, 5000); assert.equal(new Set(selected.map(x => x.name)).size, 5000); assert.ok(reports >= 50);
  const built = await manifest(selected, 'fixture', 'https'); assert.equal(Object.keys(built.selected).length, 5000);
});

test('selection and drag fallback support files; unsafe paths and duplicate paths are explicit errors', async () => {
  const value = file('one.txt'); assert.deepEqual((await collectDrop({ files: [value] }))[0], { file: value, name: 'one.txt' });
  for (const path of ['/x', '../x', 'a/../x', 'a\\x', 'C:/x', 'a\0b', 'a//b']) assert.throws(() => namedFile(value, path), { code: 'invalidPath' });
  await assert.rejects(manifest([{ file: value, name: 'one.txt' }, { file: value, name: 'one.txt' }], 'fixture', 'http'), { code: 'duplicatePath' });
});

test('unreadable directories reject the entire enumeration rather than silently omitting content', async () => {
  const root = { name: 'denied', isDirectory: true, createReader: () => ({ readEntries: (_, reject) => reject(new Error('denied')) }) };
  await assert.rejects(collectDrop({ items: [{ webkitGetAsEntry: () => root }] }), /denied/);
  assert.deepEqual(await collectDrop({ items: [{ webkitGetAsEntry: () => folder('empty', []) }] }), []);
});
