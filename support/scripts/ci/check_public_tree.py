#!/usr/bin/env python3
"""Keep source distributions free of private delivery and signing material."""
from pathlib import Path
import re,subprocess
blocked=('docs/evidence/','docs/app-store/','docs/upstream/','support/download-portal/','fastlane/','app/test/marketing/','.playwright-mcp/')
root_private={'TODO.md','AGENTS.md','CLAUDE.md','CODE_SIGNING.md'}
files=subprocess.check_output(['git','ls-files','-z'],text=True).split('\0')
errors=[]
for name in filter(None,files):
    p=Path(name)
    if name.startswith(blocked) or name in root_private or p.suffix.lower() in {'.jks','.keystore','.p12','.pfx','.mobileprovision','.provisionprofile','.log'} or name.endswith('.local.xcconfig') or p.name=='key.properties':
        errors.append(name)
    if name.startswith('docs/') and re.search(r'(BATCH|EVIDENCE|STAGE|IMPLEMENTATION_LOG|TASK_STATUS|PLAN)',p.name):errors.append(name)
    if name.endswith(('.pbxproj','.xcconfig')) :
        staged=subprocess.check_output(['git','show',':'+name],text=True)
        if re.search(r'DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}',staged):errors.append(name+': account-specific team')
if errors:raise SystemExit('Private material is not publishable:\n'+'\n'.join(sorted(set(errors))))
print('Public source tree policy passed')
