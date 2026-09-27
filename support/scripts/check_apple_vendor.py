#!/usr/bin/env python3
"""Check pinned Apple plugin versions, license bytes and reviewed patched sources."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
base = root / 'support/vendor'
manifest = json.loads((base / 'flutter_plugins.lock.json').read_text())
for name, spec in manifest['packages'].items():
    package = base / name
    pubspec = (package / 'pubspec.yaml').read_text()
    assert f'version: {spec["version"]}' in pubspec, f'{name}: version changed'
    assert hashlib.sha256((package / 'LICENSE').read_bytes()).hexdigest() == spec['license_sha256'], f'{name}: license changed'
    assert set(spec['modified_files']) == set(spec['patched_file_sha256']), f'{name}: patch list differs'
    for path, expected in spec['patched_file_sha256'].items():
        assert hashlib.sha256((package / path).read_bytes()).hexdigest() == expected, f'{name}: review patch changes in {path}'
    assert (package / 'LEGNASEND.patch').is_file()
    print(f'{name} {spec["version"]}: license and {len(spec["modified_files"])} reviewed source hashes passed')
assert (root / 'LICENSE').read_bytes() == (root / 'packages/localsend_isolates/rust_builder/LICENSE').read_bytes()
print('Rust bridge license matches the repository license verbatim.')

defaults = json.loads((base / 'Defaults/reviewed-files.json').read_text())
assert hashlib.sha256((base / 'Defaults/license').read_bytes()).hexdigest() == defaults['license_sha256']
for path, expected in defaults['patched_file_sha256'].items():
    assert hashlib.sha256((base / 'Defaults' / path).read_bytes()).hexdigest() == expected, path
print('Defaults 4.2.2: license and both reviewed secure decoding sources passed.')
