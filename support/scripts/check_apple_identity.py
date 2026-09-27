#!/usr/bin/env python3
"""Verify effective Apple target identities and configuration references (no build/sign)."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def check(platform, configuration):
    project = ROOT / 'app' / platform / 'Runner.xcodeproj'
    source = (project / 'project.pbxproj').read_text()
    ids = re.findall(r'^\s*([A-F0-9]{24}) /\*[^\n]*\*/ = \{', source, re.M)
    assert len(ids) == len(set(ids)), f'{platform}: duplicate project object identities'
    settings = {}
    for target in ('Runner', 'ShareExtension'):
        raw = subprocess.check_output([
            'xcodebuild', '-project', str(project), '-target', target,
            '-configuration', configuration, '-showBuildSettings', '-json',
        ], text=True)
        settings[target] = next(row['buildSettings'] for row in json.loads(raw) if row['target'] == target)
    app, share = settings['Runner'], settings['ShareExtension']
    bundle = app['PRODUCT_BUNDLE_IDENTIFIER']
    assert bundle.startswith('org.legna.') and bundle != 'org.legna.', bundle
    assert share['PRODUCT_BUNDLE_IDENTIFIER'] == bundle + '.ShareExtension', share['PRODUCT_BUNDLE_IDENTIFIER']
    assert app.get('DEVELOPMENT_TEAM', '') == share.get('DEVELOPMENT_TEAM', ''), 'Host/extension team mismatch'
    if platform == 'ios':
        assert app.get('LEGNASEND_APP_GROUP') == share.get('LEGNASEND_APP_GROUP') == 'group.' + bundle
        for target in settings.values():
            assert target.get('FLUTTER_BUILD_NAME') and target.get('FLUTTER_BUILD_NUMBER'), 'Missing extension version'
    groups = []
    for target, values in settings.items():
        path = ROOT / 'app' / platform / values['CODE_SIGN_ENTITLEMENTS']
        groups.append(plistlib.loads(path.read_bytes())['com.apple.security.application-groups'])
    assert len(groups[0]) == 1 and groups[0] == groups[1], 'Host/extension App Group mismatch'
    if platform == 'macos':
        assert groups[0] == ['$(AppIdentifierPrefix)org.legna.legnasend.shared']
        swift = (ROOT / 'app/macos/Runner/Shared.swift').read_text()
        assert 'org.legna.legnasend.shared' in swift and 'localsend.shared_group' not in swift
    print(f'{platform} {configuration}: {bundle}; {share["PRODUCT_BUNDLE_IDENTIFIER"]}; matching App Group and signing team')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['Debug', 'Profile', 'Release'], action='append')
    args = parser.parse_args()
    for platform in ('macos', 'ios'):
        for configuration in args.configuration or ['Debug', 'Profile', 'Release']:
            check(platform, configuration)
    print('Apple identity settings passed; registration, signed archives and store validation are separate.')


if __name__ == '__main__':
    main()
