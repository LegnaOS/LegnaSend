#!/usr/bin/env python3
"""Bundle API guides/contracts offline. --check verifies source/asset parity."""
import argparse
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
dest = root / 'app/assets/api_docs'
sources = [root / 'docs' / name for name in (
    'INTEGRATION_API.md', 'INTEGRATION_API_ZH.md', 'DIRECTORY_API.md', 'DIRECTORY_API_ZH.md',
    'API_RECEIVE_RETENTION.md', 'API_RECEIVE_RETENTION_ZH.md',
    'NATIVE_DURABLE_RESUME.md', 'NATIVE_DURABLE_RESUME_ZH.md',
    'NATIVE_RESUME_PROTOCOL.md', 'NATIVE_RESUME_PROTOCOL_ZH.md',
    'SOURCE_END_CLEANUP_RECEIPTS.md', 'SOURCE_END_CLEANUP_RECEIPTS_ZH.md',
)]
sources += sorted((root / 'docs/api').glob('integration-openapi-*.json'))
allowed = {p.resolve(): p.name for p in sources}
check = argparse.ArgumentParser()
check.add_argument('--check', action='store_true')
verify = check.parse_args().check
for source in sources:
    content = source.read_text()
    if source.suffix == '.md':
        # Development evidence references stay readable but are not dead offline links.
        def offline_link(match):
            label, target = match[1], match[2]
            if target.startswith(('https://', 'http://', '#')):
                return match[0]
            relative, separator, fragment = target.partition('#')
            filename = allowed.get((source.parent / relative).resolve())
            if filename is None:
                return label
            return f'[{label}]({filename}{separator}{fragment})'
        content = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', offline_link, content)
    target = dest / source.name
    if verify:
        if not target.exists() or target.read_text() != content:
            raise SystemExit(f'Stale API asset: {target.name}')
    else:
        dest.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
print(f'{len(sources)} API documentation assets verified' if verify else f'{len(sources)} API documentation assets written')
