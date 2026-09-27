#!/usr/bin/env python3
"""Package real Release outputs and reject incorrect native architectures."""
import hashlib,json,os,re,shutil,struct,subprocess,sys,tarfile,zipfile
from pathlib import Path

def machine(data):
    if data[:2]==b'MZ':
        off=struct.unpack_from('<I',data,0x3c)[0]
        if data[off:off+4]!=b'PE\0\0': raise ValueError('Invalid PE signature')
        return struct.unpack_from('<H',data,off+4)[0]
    if data[:4]==b'\x7fELF':
        if data[4]!=2: raise ValueError('Expected 64-bit ELF')
        return struct.unpack_from('<H' if data[5]==1 else '>H',data,18)[0]
    raise ValueError('Not a PE/ELF binary')

def pe_imports(data):
    off=struct.unpack_from('<I',data,0x3c)[0]; optional=off+24
    if struct.unpack_from('<H',data,optional)[0]!=0x20b:raise ValueError('Expected PE32+')
    count=struct.unpack_from('<H',data,off+6)[0]
    section_start=optional+struct.unpack_from('<H',data,off+20)[0]
    def file_offset(rva):
        for index in range(count):
            pos=section_start+40*index
            virtual_size,va,raw_size,raw=struct.unpack_from('<IIII',data,pos+8)
            if va<=rva<va+min(virtual_size,raw_size):return raw+rva-va
        raise ValueError('Unmapped import RVA')
    rva,size=struct.unpack_from('<II',data,optional+120)
    if not rva:return []
    start=file_offset(rva); names=[]
    for pos in range(start,min(start+size,len(data)-19),20):
        fields=struct.unpack_from('<IIIII',data,pos)
        if not any(fields):return names
        n=file_offset(fields[3]);end=data.find(b'\0',n,n+512)
        if end<0:raise ValueError('Invalid import name')
        names.append(data[n:end].decode('ascii').lower())
    raise ValueError('Unterminated import table')

def main():
    platform,arch,source=sys.argv[1:];source=Path(source)
    version=re.search(r'^version: (\S+)',Path('app/pubspec.yaml').read_text(),re.M).group(1).split('+')[0]
    revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    out=Path('dist');out.mkdir(exist_ok=True);files=[];native=[]
    signing='unsigned'
    if platform in ('windows','linux'):
        if not (source/'data/flutter_assets').is_dir():raise ValueError('Flutter asset bundle missing')
        bins=list(source.rglob('*.dll'))+[source/'localsend_app.exe'] if platform=='windows' else list(source.rglob('*.so'))+[source/'localsend_app']
        expected=({'x64':0x8664,'arm64':0xaa64}[arch] if platform=='windows' else 62)
        proofs=json.loads((source/'ci-runtime-provenance.json').read_text(encoding='utf-8-sig')) if platform=='windows' else {}
        for p in bins:
            if not p.is_file(): raise ValueError(f'Missing binary: {p}')
            actual=machine(p.read_bytes())
            if actual!=expected:
                proof=proofs.get(p.name,{})
                allowed=(platform=='windows' and arch=='arm64' and re.fullmatch(r'(?:vcruntime|msvcp|concrt)140[^/]*\.dll',p.name,re.I)
                         and proof.get('arm64x') is True and proof.get('microsoftSignatureVerified') is True
                         and proof.get('sha256')==hashlib.sha256(p.read_bytes()).hexdigest())
                if not allowed:raise ValueError(f'Wrong architecture: {p.name}, {actual:#x}, expected {expected:#x}')
            if platform=='windows':
                for dependency in pe_imports(p.read_bytes()):
                    if re.match(r'(?:vcruntime|msvcp|concrt)140',dependency) and not (source/dependency).is_file():
                        raise ValueError(f'Missing CRT dependency: {p.name} -> {dependency}')
            native.append(str(p.relative_to(source)))
        shutil.copyfile('LICENSE',source/'LICENSE.txt')
        name=f'LegnaSend-{version}-{platform}-{arch}-release'
        if platform=='windows':
            target=out/(name+'-unsigned.zip')
            with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as z:
                for p in sorted(source.rglob('*')):
                    if p.is_file():z.write(p,str(p.relative_to(source)))
        else:
            target=out/(name+'.tar.gz')
            with tarfile.open(target,'w:gz') as t:t.add(source,arcname='LegnaSend')
        files.append(target)
    elif platform=='android':
        signing=os.environ.get('LEGNASEND_ANDROID_SIGNING','unsigned')
        sdk=Path(os.environ['ANDROID_HOME'])
        candidates=sorted((sdk/'build-tools').glob('*/apksigner'))
        if not candidates:raise ValueError('apksigner missing')
        for abi,expected in [('arm64-v8a',183),('x86_64',62)]:
            candidates_apk=list(source.glob(f'app-{abi}-release*.apk'))
            if len(candidates_apk)!=1:raise ValueError(f'Expected exactly one release APK for {abi}')
            p=candidates_apk[0]
            with zipfile.ZipFile(p) as z:
                libs=[n for n in z.namelist() if n.startswith('lib/') and n.endswith('.so')]
                for required in ['libflutter.so','libapp.so','librust_lib_localsend_app.so']:
                    if f'lib/{abi}/{required}' not in libs:raise ValueError(f'Missing {abi}/{required}')
                for n in libs:
                    if n.split('/')[1]!=abi or machine(z.read(n))!=expected:raise ValueError(f'Wrong ABI: {n}')
                native.extend(libs)
            if signing!='unsigned':subprocess.run([str(candidates[-1]),'verify','--verbose',str(p)],check=True)
            target=out/f'LegnaSend-{version}-android-{abi}-release-{signing}.apk'
            shutil.copyfile(p,target);files.append(target)
    else:raise ValueError('Unsupported platform')
    records=[{'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]
    (out/'SHA256SUMS.txt').write_text(''.join(f'{r["sha256"]}  {r["file"]}\n' for r in records))
    manifest={'version':version,'commit':revision,'platform':platform,'architecture':arch,'configuration':'Release','signing':signing,'native_files_checked':native,'artifacts':records,'device_acceptance':False}
    (out/'BUILD.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest,indent=2))
if __name__=='__main__':main()
