#!/usr/bin/env python3
"""Publish only verified existing CI outputs; never rebuild, replace a release, or expose secrets."""
import hashlib,json,os,re,shutil,subprocess,time
from pathlib import Path

def run(*args):
    return subprocess.check_output(args,text=True).strip()
def api(path):return json.loads(run('gh','api',path))
def main():
    repo=os.environ['GITHUB_REPOSITORY'];tag=os.environ['RELEASE_TAG']
    ids=[os.environ['PRIMARY_RUN'],os.environ['ARM64_RUN']]
    if not re.fullmatch(r'v\d+\.\d+\.\d+',tag) or not all(re.fullmatch(r'\d+',x) for x in ids):
        raise ValueError('Invalid release tag or run ID')
    version=tag[1:]
    actual=re.search(r'^version: (\S+)',Path('app/pubspec.yaml').read_text(),re.M).group(1).split('+')[0]
    if actual!=version:raise ValueError('Tag does not match the app version')
    expected=[['windows (x64,','linux','android'],['windows (arm64,']]
    runs=[]
    for ident,prefixes in zip(ids,expected):
        for attempt in range(61):
            result=api(f'repos/{repo}/actions/runs/{ident}')
            if result['head_repository']['full_name']!=repo or result['path']!='.github/workflows/legnasend_packages.yml':
                raise ValueError('Artifact source is not the expected repository package workflow')
            jobs=api(f'repos/{repo}/actions/runs/{ident}/jobs?per_page=100')['jobs']
            selected=[]
            for prefix in prefixes:
                matches=[j for j in jobs if j['name'].startswith(prefix)]
                if len(matches)!=1:raise ValueError('Missing or ambiguous required job: '+prefix)
                selected.append(matches[0])
            if all(j['status']=='completed' for j in selected):
                if any(j['conclusion']!='success' for j in selected):raise ValueError('A required source build did not succeed')
                runs.append(result);break
            if attempt==60:raise ValueError('Required builds have not completed within 30 minutes')
            print('Waiting for required source jobs',ident,flush=True);time.sleep(30)
    # Mixing retry-run artifacts is allowed only when runtime source trees are identical.
    subprocess.run(['git','diff','--exit-code',runs[0]['head_sha'],runs[1]['head_sha'],'--','app','packages','Cargo.toml','Cargo.lock','pubspec.yaml','pubspec.lock','vendor','support/vendor'],check=True)
    specs=[(ids[0],runs[0],'LegnaSend-windows-x64-release-unsigned','windows','x64',1),
           (ids[0],runs[0],'LegnaSend-linux-x64-release','linux','x64',1),
           (ids[0],runs[0],'LegnaSend-android-release','android','all',2),
           (ids[1],runs[1],'LegnaSend-windows-arm64-release-unsigned','windows','arm64',1)]
    out=Path('release-assets');out.mkdir();records=[]
    for ident,source,name,platform,arch,count in specs:
        dest=Path('downloaded-artifacts')/name
        subprocess.run(['gh','run','download',ident,'--repo',repo,'--name',name,'--dir',str(dest)],check=True)
        manifest=json.loads((dest/'BUILD.json').read_text())
        if (manifest['version'],manifest['commit'],manifest['platform'],manifest['architecture'],manifest['configuration'])!=(version,source['head_sha'],platform,arch,'Release'):
            raise ValueError('Artifact manifest does not match its source run')
        if len(manifest['artifacts'])!=count:raise ValueError('Incomplete artifact group')
        if manifest['signing']!=('debug-signed' if platform=='android' else 'unsigned'):
            raise ValueError('Signing mode differs from this release approval')
        for item in manifest['artifacts']:
            name=item['file']
            if Path(name).name!=name or not name.startswith('LegnaSend-'+version+'-'):raise ValueError('Invalid artifact filename')
            p=dest/name
            if p.is_symlink() or p.stat().st_size!=item['bytes'] or hashlib.sha256(p.read_bytes()).hexdigest()!=item['sha256']:
                raise ValueError('Artifact content mismatch')
            target=out/name
            if target.exists():raise ValueError('Duplicate release asset')
            shutil.copyfile(p,target)
            records.append({**item,'source_run':int(ident),'source_commit':source['head_sha'],'signing':manifest['signing'],
                            'url':f'https://github.com/{repo}/releases/download/{tag}/{name}'})
    if len(records)!=5:raise ValueError('Expected five downloadable packages')
    (out/'SHA256SUMS.txt').write_text(''.join(f'{r["sha256"]}  {r["file"]}\n' for r in records))
    (out/'BUILD-MANIFEST.json').write_text(json.dumps({'version':version,'tag_target':runs[1]['head_sha'],'artifacts':records},indent=2)+'\n')
    shutil.copyfile('docs/releases/1.0.0_EN.md',out/'RELEASE-NOTES-EN.md')
    # The owner pre-creates the tag so the workflow needs no permission to create
    # a ref to a commit containing workflow changes.
    ref=api(f'repos/{repo}/git/ref/tags/{tag}')
    if ref['object']['type']!='commit' or ref['object']['sha']!=runs[1]['head_sha']:
        raise ValueError('Release tag must point to the verified ARM build commit')
    # A non-404 API failure must not be interpreted as permission to overwrite.
    existing=subprocess.run(['gh','api',f'repos/{repo}/releases/tags/{tag}'],capture_output=True,text=True)
    if existing.returncode==0:raise ValueError('Release already exists; no assets were overwritten')
    if '404' not in existing.stderr:raise RuntimeError('Release existence check failed')
    subprocess.run(['gh','release','create',tag,'--repo',repo,'--verify-tag','--draft','--title','LegnaSend '+version,'--notes-file','docs/releases/1.0.0_ZH.md',*[str(p) for p in sorted(out.iterdir())]],check=True)
    subprocess.run(['gh','release','edit',tag,'--repo',repo,'--draft=false','--latest'],check=True)
    print(json.dumps(records,indent=2))
    with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as f:
        f.write('## Published LegnaSend '+version+'\n\n')
        for r in records:f.write(f'- [{r["file"]}]({r["url"]})\n')
if __name__=='__main__':main()
