#!/bin/bash
# Prepare a disposable real-app copy for local interoperability acceptance.
# Does not launch the app or read/write either app's preferences.
set -euo pipefail
SOURCE=${1:-/Applications/LocalSend.app}
DESTINATION=${2:?Pass a new isolated destination ending in .app}
BUNDLE_ID=${3:-org.legna.localsend.compatfixture}
[[ $# -le 3 && -d "$SOURCE" && ! -e "$DESTINATION" && ! -L "$DESTINATION" && "$DESTINATION" == *.app ]]

# Preflight ALL original main/extension identifiers before creating or rewriting
# anything. Repeat on the copied tree before any write; no partial plist rewrite
# can hide an invalid extension. Use the OS Python, not a legacy PATH interpreter.
validate_and_rewrite() {
/usr/bin/python3 - "$1" "$SOURCE" "$DESTINATION" "$BUNDLE_ID" <<'PY'
import hashlib, pathlib, plistlib, re, sys
mode, source_arg, destination_arg, new = sys.argv[1:]
base = 'org.legna.localsend.compatfixture'
if not re.fullmatch(re.escape(base) + r'(?:\.[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?)*', new) or len(new) > 180:
    raise SystemExit('Invalid isolated bundle identifier')
source = pathlib.Path(source_arg).resolve(strict=True)
destination = pathlib.Path(destination_arg).resolve()
if destination == source or source in destination.parents or destination in source.parents:
    raise SystemExit('The isolated copy must be outside the original app')
root = source if mode == 'validate' else destination
main = root / 'Contents/Info.plist'
extension_paths = sorted(root.glob('Contents/PlugIns/**/*.appex/Contents/Info.plist'))
helper_paths = sorted(root.glob('Contents/Library/LoginItems/**/*.app/Contents/Info.plist'))
paths = [main] + extension_paths + helper_paths
# Reject malformed bundles too: a missing extension Info.plist is not permission
# to leave an unisolated extension inside the resulting app.
extensions = sorted(root.glob('Contents/PlugIns/**/*.appex'))
helpers = sorted(root.glob('Contents/Library/LoginItems/**/*.app'))
if len(extension_paths) != len(extensions) or len(helper_paths) != len(helpers):
    raise SystemExit('Every extension must have a validated Info.plist')
values = []
for path in paths:
    if not path.is_file() or root not in path.resolve().parents:
        raise SystemExit('Bundle metadata escapes the app or is missing')
    with path.open('rb') as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise SystemExit('Invalid bundle metadata')
    values.append(value)
old = values[0].get('CFBundleIdentifier')
if old != 'org.localsend.localsendApp':
    raise SystemExit('Unexpected original LocalSend main identifier')
original_prefix = values[0].get('AppIdentifierPrefix')
if not isinstance(original_prefix, str) or not re.fullmatch(r'[A-Z0-9]{10}\.', original_prefix):
    raise SystemExit('Unexpected original application prefix')
seen = set()
for index, value in enumerate(values):
    current = value.get('CFBundleIdentifier')
    helper = index > len(extension_paths)
    valid_nested = current == old + '-LaunchAtLoginHelper' if helper else isinstance(current, str) and re.fullmatch(re.escape(old) + r'(?:\.[A-Za-z][A-Za-z0-9-]*)+', current)
    if not isinstance(current, str) or (index and not valid_nested):
        raise SystemExit('Unexpected extension identifier; copy not launched')
    prefix = value.get('AppIdentifierPrefix')
    if current in seen or (prefix != original_prefix and not (helper and prefix is None)):
        raise SystemExit('Duplicate bundle identifier or unexpected extension prefix')
    seen.add(current)
if mode == 'rewrite':
    prefix = 'LEGNATEST.' if new == base else 'LG' + hashlib.sha256(new.encode()).hexdigest()[:8].upper() + '.'
    if prefix == original_prefix:
        raise SystemExit('Fixture prefix must differ from the original')
    for path, value in zip(paths, values):
        value['CFBundleIdentifier'] = new + value['CFBundleIdentifier'][len(old):]
        value['AppIdentifierPrefix'] = prefix
    for path, value in zip(paths, values):
        with path.open('wb') as stream:
            plistlib.dump(value, stream)
    print('Isolated bundle: ' + new)
    print('Isolated prefix: ' + prefix)
PY
}
validate_and_rewrite validate
/bin/mkdir -p "$(dirname "$DESTINATION")"
# Reserve a NEW target exclusively. Existing directories and symlinks are never
# overwritten, even if one appeared after preflight. Failed copies are not used.
/bin/mkdir "$DESTINATION"
/usr/bin/ditto "$SOURCE" "$DESTINATION"
validate_and_rewrite rewrite
/usr/bin/xattr -cr "$DESTINATION"
/usr/bin/codesign --force --deep --sign - "$DESTINATION"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist"
printf 'Prepared only; not launched: %s\n' "$DESTINATION"
