#!/usr/bin/env python3
"""Write local iOS signing settings; does not register, build, sign or upload."""
import argparse
import os
from pathlib import Path
import re
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--team', required=True, help='Your 10-character Apple Developer Team ID')
    parser.add_argument('--bundle-id', required=True, help='Your registered explicit host bundle ID')
    parser.add_argument('--app-group', help='Your registered App Group; defaults to group.<bundle-id>')
    parser.add_argument('--replace', action='store_true', help='Replace an existing local configuration')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team):
        parser.error('Team ID must contain exactly 10 uppercase letters/digits.')
    identifier = r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'
    if not re.fullmatch(identifier, args.bundle_id) or len(args.bundle_id) > 200:
        parser.error('Use an explicit reverse-DNS bundle ID, at most 200 characters.')
    group = args.app_group or f'group.{args.bundle_id}'
    if not group.startswith('group.') or not re.fullmatch(identifier, group) or len(group) > 255:
        parser.error('App Group must be an explicit group.* identifier, at most 255 characters.')
    if args.team == '3W7H4PYMCV' or args.bundle_id.startswith('org.localsend.') or group.startswith('group.org.localsend.'):
        parser.error('Configure your fork identity, not the upstream signing identity.')
    path = Path(__file__).resolve().parents[2] / 'app/ios/Flutter/LegnaSigning.local.xcconfig'
    content = ('// Local Apple account configuration. Ignored by Git.\n'
               f'LEGNASEND_TEAM = {args.team}\n'
               f'LEGNASEND_BUNDLE_ID = {args.bundle_id}\n'
               f'LEGNASEND_APP_GROUP = {group}\n')
    if path.is_symlink():
        parser.error('Local signing configuration must be a regular file, not a symlink.')
    if path.exists() and not args.replace:
        parser.error('Local configuration exists; use --replace to replace it explicitly.')
    fd, temp = tempfile.mkstemp(prefix='.legna-signing-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if args.replace:
            os.replace(temp, path)
        else:
            # Exclusive publication: do not overwrite a concurrently created file.
            os.link(temp, path)
        print(f'Wrote {path}. Register both app IDs and this group in your Apple team before archiving.')
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


if __name__ == '__main__':
    main()
