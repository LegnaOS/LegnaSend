'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const marked = require('../../assets/web/vendor/marked.umd.js');
const {HeaderScan,inputLimit,columnLimit} = require('../../assets/web/markdown-table-header.js');
function scan(source, step=65536, replay=false) {
  let scanner=new HeaderScan(), offset=0, result;
  while(offset<source.length) {
    const part=source.slice(offset,offset+step);
    result=scanner.feed(part,offset+part.length===source.length); offset+=result.consumed;
    assert.ok(JSON.stringify(scanner.snapshot()).length<16*1024);
    if(result.done) break;
    if(replay) scanner=new HeaderScan(scanner.snapshot());
  }
  return {...result,offset};
}
test('oversized inline header remains source-only; compact scaffold preserves subsequent row alignment',()=>{
 const header='| **'+('中文🙂 &amp; \\| text '.repeat(20000))+'** | _Value_ |\n';
 const delimiter='|:'+ '-'.repeat(80000)+'|'+ '-'.repeat(80000)+':|\n';
 for(const step of [1,39173,65536]) {
  const r=scan(header+delimiter+'| **later** | `cell` |\n\n# end\n',step,step!==1);
  assert.equal(r.valid,true);assert.equal(r.offset,header.length+delimiter.length);
  assert.ok(r.compactHeader.length<16384);assert.deepEqual(new marked.Lexer({gfm:true}).blockTokens(r.compactHeader)[0].align,['left','right']);
  const tokens=marked.lexer(r.compactHeader+'| **later** | `cell` |\n\n# end\n');
  assert.equal(tokens[0].rows[0][0].tokens[0].type,'strong');assert.equal(tokens[0].rows[0][1].tokens[0].type,'codespan');
  assert.ok(tokens[0].header.every(c=>c.text===''));assert.equal(tokens.at(-1).type,'heading');
 }
});
test('pipe escaping with odd/even backslash runs matches Marked, including split input',()=>{
 for(let count=0;count<12;count++) {
  const header='| a'+'\\'.repeat(count)+'|b | c |\n';
  const cols=count%2?2:3, delimiter='|'+'---|'.repeat(cols)+'\n';
  for(const step of [1,2,7,65536]) {
   const r=scan(header+delimiter,step,true), expected=marked.lexer(header+delimiter)[0];
   assert.equal(expected.type,'table');assert.equal(r.valid,true);assert.equal(r.columns,expected.header.length);
  }
 }
});
test('bounded snapshots replay every alignment state; CRLF and EOF delimiters',()=>{
 for(const source of [' a | b | c \n:---|:---:|---:\n','|a|b|\r\n|--|:--:|\r\n','a\n:-:', '|a|b|\n|-|-|']) {
  const r=scan(source,1,true);assert.equal(r.valid,true,source);
  const expected=marked.lexer(source.replace(/\r\n/g,'\n'))[0];
  assert.deepEqual(marked.lexer(r.compactHeader)[0].align,expected.align);
 }
});
test('invalid or over-budget structure reports explicit boundary, never a truncated valid table',()=>{
 for(const source of ['|a|b|\n|---|\n', '|a|b|\n|-- x|---|\n','a\n---\n','a\n: --|\n','|a|\n|---||\n','|a|\n|---\rX|\n','|a|\n|---|\r','    a|b\n|-|-|\n','# a|b\n|-|-|\n','<custom '+('x'.repeat(400))+'>|b\n|-|-|\n']) {
  const r=scan(source,7,true);assert.equal(r.valid,false,source);assert.ok(r.reason);assert.equal(r.compactHeader,null);
 }
 const source='|'+'x|'.repeat(columnLimit+1)+'\n|'+'---|'.repeat(columnLimit+1)+'\n';
 const r=scan(source);assert.equal(r.valid,false);assert.equal(r.reason,'column_limit');
});
test('maximum supported columns have bounded scaffold and no dropped columns',()=>{
 const r=scan('|'+' x |'.repeat(columnLimit)+'\n|'+' :-: |'.repeat(columnLimit)+'\n',3,true);
 assert.equal(r.valid,true);assert.equal(r.columns,columnLimit);assert.ok(Buffer.byteLength(r.compactHeader)<16384);
 assert.equal(marked.lexer(r.compactHeader)[0].header.length,columnLimit);
});
test('read boundary consumes exactly two lines and snapshots do not retain giant source',()=>{
 const source='|'+('x'.repeat(300000))+'|\n|---|\nfollowing\n';
 const r=scan(source,16384,true);assert.equal(r.offset,source.indexOf('following'));assert.equal(r.valid,true);
 const scanner=new HeaderScan();scanner.feed('|'+('x'.repeat(65535)),false);
 assert.ok(JSON.stringify(scanner.snapshot()).length<1024);assert.throws(()=>scanner.feed('x'.repeat(inputLimit+1),false),/input/);
 assert.throws(()=>new HeaderScan({version:1,prefix:'x'.repeat(300)}),/snapshot/);
});
