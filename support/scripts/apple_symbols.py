#!/usr/bin/env python3
"""Collect real, UUID-matched Apple symbols; rebuild only the small legacy login helper."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

UUID = re.compile(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', re.M)


def run(*args):
    p = subprocess.run([str(x) for x in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} failed: {p.stderr.strip()}')
    return p.stdout


def uuids(path):
    return {arch: value.upper() for value, arch in UUID.findall(run('xcrun', 'dwarfdump', '--uuid', path))}


def dwarf_file(bundle):
    files = list((Path(bundle) / 'Contents/Resources/DWARF').glob('*'))
    if len(files) != 1 or not files[0].is_file() or files[0].is_symlink():
        raise RuntimeError('A dSYM must contain exactly one regular DWARF file')
    return files[0]


def validate(bundle, expected):
    dwarf = dwarf_file(bundle)
    if uuids(dwarf) != expected:
        raise RuntimeError('dSYM architecture/UUID mismatch')
    for arch in expected:
        info = run('xcrun', 'dwarfdump', '--arch=' + arch, '--debug-info', dwarf)
        if 'DW_TAG_compile_unit' not in info or 'DW_AT_stmt_list' not in info:
            raise RuntimeError(f'dSYM has no genuine compilation unit/line table for {arch}')
    return dwarf


def install_bundle(source, output, expected, replace=False):
    output = Path(output)
    validate(source, expected)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() or output.is_symlink():
        if output.is_symlink():
            raise RuntimeError('Refusing a symlink dSYM destination')
        try:
            validate(output, expected)
            return 'already-present'
        except RuntimeError:
            if not replace: raise
    with tempfile.TemporaryDirectory(prefix='.apple-symbols-', dir=str(output.parent)) as temp:
        staged = Path(temp) / output.name
        shutil.copytree(source, staged)
        validate(staged, expected)
        # Only explicit build-product replacement is allowed; recovery defaults
        # never overwrite existing bundles. Stage and validate before switching.
        previous = Path(temp) / 'previous'
        if output.exists():
            if not replace: raise RuntimeError('Symbol output appeared during collection')
            output.rename(previous)
        try:
            staged.rename(output)
        except OSError:
            if previous.exists(): previous.rename(output)
            raise
    return 'installed'


def find_binary(app, name):
    suffix = 'Contents/MacOS/LaunchAtLoginHelper' if name == 'LaunchAtLoginHelper' else 'Versions/A/objective_c'
    files = [p for p in Path(app).rglob(name) if p.is_file() and not p.is_symlink() and str(p).endswith(suffix)]
    if len(files) != 1:
        raise RuntimeError(f'Expected exactly one {name} binary, found {len(files)}')
    return files[0]


def collect(app, output, roots, replace=False):
    binary = find_binary(app, 'objective_c')
    expected = uuids(binary)
    if not expected or any(a not in ('arm64', 'x86_64') for a in expected):
        raise RuntimeError('Unsupported native-asset architectures')
    destination = Path(output) / 'objective_c.framework.dSYM'
    if destination.is_symlink(): raise RuntimeError('Refusing a symlink dSYM destination')
    if destination.exists():
        try:
            validate(destination, expected)
            return {'binary': str(binary), 'uuid': expected, 'result': 'already-present'}
        except RuntimeError:
            if not replace: raise
    candidates = {}
    for root in roots:
        root = Path(root)
        if not root.is_dir():
            continue
        paths = list(root.rglob('objective_c.dylib'))
        if len(paths) > 128:
            raise RuntimeError('Native-asset search budget exceeded')
        for path in paths:
            if path.is_symlink():
                continue
            for arch, value in uuids(path).items():
                if expected.get(arch) == value:
                    candidates.setdefault(arch, []).append(path)
    missing = sorted(set(expected) - set(candidates))
    if missing:
        raise RuntimeError('No original UUID-matched native asset for: ' + ', '.join(missing))
    with tempfile.TemporaryDirectory(prefix='legnasend-apple-symbols-') as temp:
        temp = Path(temp); pieces = []
        for arch, value in expected.items():
            bundle = temp / (arch + '.dSYM')
            errors = []
            for candidate in candidates[arch]:
                try:
                    run('xcrun', 'dsymutil', '--arch=' + arch, candidate, '-o', bundle)
                    pieces.append(validate(bundle, {arch: value})); break
                except RuntimeError as error:
                    errors.append(str(error))
                    if bundle.exists(): shutil.rmtree(bundle)
            else:
                raise RuntimeError('Original native objects are missing or empty for ' + arch + ': ' + '; '.join(errors))
        combined = temp / 'objective_c.framework.dSYM'
        shutil.copytree(pieces[0].parents[3], combined)
        old_dwarf = dwarf_file(combined)
        old_dwarf.unlink()
        target = combined / 'Contents/Resources/DWARF/objective_c'
        if len(pieces) == 1: shutil.copy2(pieces[0], target)
        else: run('xcrun', 'lipo', '-create', *pieces, '-output', target)
        validate(combined, expected)
        status = install_bundle(combined, destination, expected, replace=replace)
    return {'binary': str(binary), 'uuid': expected, 'result': status, 'dSYM': str(destination)}


def build_helper(source, output, arches, minimum):
    source, output = Path(source), Path(output)
    if not source.is_file() or source.name != 'main.swift':
        raise RuntimeError('Resolved LaunchAtLogin main.swift is required')
    if not arches or len(set(arches)) != len(arches) or any(a not in ('arm64', 'x86_64') for a in arches):
        raise RuntimeError('Expected distinct supported macOS architectures')
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', minimum):
        raise RuntimeError('Invalid deployment target')
    output.mkdir(parents=True, exist_ok=True)
    binary = output / 'LaunchAtLoginHelper'
    symbols = output / 'LaunchAtLoginHelper.app.dSYM'
    if binary.exists() or symbols.exists():
        raise RuntimeError('Helper output must be a fresh directory')
    sdk = run('xcrun', '--sdk', 'macosx', '--show-sdk-path').strip()
    with tempfile.TemporaryDirectory(prefix='helper-build-', dir=str(output)) as temp:
        temp = Path(temp); bins, dwarfs, expected = [], [], {}
        for arch in arches:
            folder = temp / arch; folder.mkdir()
            obj, thin, dsym = folder / 'main.o', folder / 'LaunchAtLoginHelper', folder / 'LaunchAtLoginHelper.app.dSYM'
            flags = ['-sdk', sdk, '-target', arch + '-apple-macosx' + minimum, '-module-name', 'LaunchAtLoginHelper', '-module-cache-path', str(temp / 'modules'), '-g', '-O']
            run('xcrun', 'swiftc', *flags, '-c', source, '-o', obj)
            run('xcrun', 'swiftc', *flags, obj, '-o', thin)
            run('xcrun', 'dsymutil', thin, '-o', dsym)
            ids = uuids(thin)
            if set(ids) != {arch}: raise RuntimeError('Helper slice architecture differs')
            dwarfs.append(validate(dsym, ids)); bins.append(thin); expected.update(ids)
        if len(bins) == 1: shutil.copy2(bins[0], binary)
        else: run('xcrun', 'lipo', '-create', *bins, '-output', binary)
        shutil.copytree(dwarfs[0].parents[3], symbols)
        dwarf_file(symbols).unlink()
        target = symbols / 'Contents/Resources/DWARF/LaunchAtLoginHelper'
        if len(dwarfs) == 1: shutil.copy2(dwarfs[0], target)
        else: run('xcrun', 'lipo', '-create', *dwarfs, '-output', target)
        validate(symbols, expected)
        if uuids(binary) != expected: raise RuntimeError('Universal helper UUID mismatch')
    return binary, symbols, expected


def xcode_helper():
    if os.environ.get('ACTION') != 'install':
        return {'result': 'skipped-non-archive'}
    env = os.environ
    roots = []
    override = env.get('LEGNASEND_LAUNCH_AT_LOGIN_SOURCE')
    if override: roots.append(Path(override))
    for key in ('BUILD_DIR', 'PROJECT_TEMP_DIR', 'SRCROOT'):
        if env.get(key):
            for parent in [Path(env[key]), *Path(env[key]).parents]:
                roots.append(parent / 'SourcePackages/checkouts/LaunchAtLogin-Legacy/Sources/LaunchAtLoginHelper/main.swift')
    source = next((p for p in roots if p.is_file()), None)
    if source is None: raise RuntimeError('Resolved LaunchAtLogin source was not found; specify LEGNASEND_LAUNCH_AT_LOGIN_SOURCE')
    app = Path(env['BUILT_PRODUCTS_DIR']) / env['CONTENTS_FOLDER_PATH'] / 'Library/LoginItems/LaunchAtLoginHelper.app'
    executable = app / 'Contents/MacOS/LaunchAtLoginHelper'
    if not executable.is_file(): raise RuntimeError('Run after the existing Copy Launch at Login Helper phase')
    entitlements = source.parent.parent / 'LaunchAtLogin/LaunchAtLogin.entitlements'
    signing = env.get('CODE_SIGNING_ALLOWED', 'YES') != 'NO'
    identity = env.get('EXPANDED_CODE_SIGN_IDENTITY') or env.get('EXPANDED_CODE_SIGN_IDENTITY_NAME')
    if signing and (not identity or not entitlements.is_file()):
        raise RuntimeError('Use Xcode existing signing identity and resolved helper entitlements')
    arches = env.get('ARCHS', '').split()
    minimum = env.get('MACOSX_DEPLOYMENT_TARGET', '10.15')
    with tempfile.TemporaryDirectory(prefix='legnasend-helper-symbols-') as temp:
        binary, dsym, expected = build_helper(source, Path(temp) / 'product', arches, minimum)
        staged = executable.with_name('.LaunchAtLoginHelper.symbols-new')
        if staged.exists(): raise RuntimeError('Unexpected staged helper executable')
        try:
            shutil.copy2(binary, staged); staged.chmod(0o755); staged.replace(executable)
        finally:
            if staged.exists(): staged.unlink()
        if signing:
            args = ['codesign', '--force', '--options', 'runtime', '--sign', identity]
            if env.get('CODE_SIGN_ENTITLEMENTS'): args += ['--entitlements', entitlements]
            run(*args, app)
            run('codesign', '--verify', '--strict', app)
        install_bundle(dsym, Path(env['DWARF_DSYM_FOLDER_PATH']) / 'LaunchAtLoginHelper.app.dSYM', expected, replace=True)
        return {'result': 'rebuilt-helper', 'uuid': expected, 'signing': 'existing-xcode-identity' if signing else 'disabled-by-xcode'}


def audit(app, symbols):
    result = []
    for name, bundle in [('objective_c', 'objective_c.framework.dSYM'), ('LaunchAtLoginHelper', 'LaunchAtLoginHelper.app.dSYM')]:
        binary = find_binary(app, name); expected = uuids(binary)
        item = {'binary': str(binary), 'uuid': expected, 'dSYM': str(Path(symbols) / bundle)}
        try: validate(Path(symbols) / bundle, expected); item['status'] = 'valid'
        except RuntimeError as error: item.update(status='missing-or-invalid', reason=str(error))
        result.append(item)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__); sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('collect'); p.add_argument('--app', required=True); p.add_argument('--output', required=True); p.add_argument('--source-root', action='append', required=True); p.add_argument('--replace-build-product', action='store_true')
    p = sub.add_parser('audit'); p.add_argument('--app', required=True); p.add_argument('--symbols', required=True)
    p = sub.add_parser('build-helper'); p.add_argument('--source', required=True); p.add_argument('--output', required=True); p.add_argument('--arch', action='append', required=True); p.add_argument('--min-macos', default='10.15')
    sub.add_parser('helper')
    args = parser.parse_args()
    if args.command == 'collect': result = collect(args.app, args.output, args.source_root, replace=args.replace_build_product)
    elif args.command == 'audit': result = audit(args.app, args.symbols)
    elif args.command == 'helper': result = xcode_helper()
    else:
        binary, symbols, ids = build_helper(args.source, args.output, args.arch, args.min_macos); result = {'binary': str(binary), 'dSYM': str(symbols), 'uuid': ids}
    print(json.dumps(result, indent=2))
    if args.command == 'audit' and any(r['status'] != 'valid' for r in result): raise SystemExit(2)


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError) as error: raise SystemExit('apple_symbols: ' + str(error))
