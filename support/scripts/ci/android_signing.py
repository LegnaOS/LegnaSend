#!/usr/bin/env python3
"""Use explicit repository secrets, or build clearly labeled unsigned Release APKs."""
import base64, os
from pathlib import Path
store=os.environ.get('ANDROID_KEY_STORE','')
props=os.environ.get('ANDROID_KEY_PROPERTIES','')
if bool(store)!=bool(props):
    raise SystemExit('Both ANDROID_KEY_STORE and ANDROID_KEY_PROPERTIES must be configured together')
if store:
    key=Path('app/android/ci-release.jks')
    key.write_bytes(base64.b64decode(store,validate=True));key.chmod(0o600)
    text=base64.b64decode(props,validate=True).decode('utf-8')
    values={line.split('=',1)[0].strip():line.split('=',1)[1] for line in text.splitlines() if '=' in line and not line.lstrip().startswith('#')}
    if not all(values.get(k) for k in ['keyAlias','keyPassword','storePassword']):
        raise SystemExit('Android signing properties are incomplete')
    config=Path('app/android/key.properties')
    config.write_text('\n'.join(f'{k}={values[k]}' for k in ['keyAlias','keyPassword','storePassword'])+'\nstoreFile=../ci-release.jks\n')
    config.chmod(0o600)
    mode='debug-signed' if os.environ.get('ANDROID_SIGNING_KIND')=='debug' else 'signed'
else:
    mode='unsigned'
with open(os.environ['GITHUB_ENV'],'a') as env:
    env.write(f'LEGNASEND_CI_UNSIGNED={"true" if mode=="unsigned" else "false"}\nLEGNASEND_ANDROID_SIGNING={mode}\n')
print(f'Android Release signing mode: {mode}; no debug signing fallback')
