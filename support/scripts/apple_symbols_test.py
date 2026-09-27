#!/usr/bin/env python3
"""Small real Mach-O/dSYM tests; no app archive, signing identity or account operations."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('symbols', Path(__file__).with_name('apple_symbols.py'))
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)


class SymbolsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='apple-symbols-test-'); cls.root = Path(cls.temp.name)
        cls.sources = cls.root / 'sources'; cls.sources.mkdir()
        cls.app = cls.root / 'Test.app'; cls.binary = cls.app / 'Contents/Frameworks/objective_c.framework/Versions/A/objective_c'
        cls.binary.parent.mkdir(parents=True)
        bins = []
        for arch in ('arm64', 'x86_64'):
            folder = cls.sources / arch; folder.mkdir()
            source = folder / 'fixture.c'; source.write_text('int capture_symbol(int value) { return value + 3; }\n')
            obj = folder / 'fixture.o'; binary = folder / 'objective_c.dylib'
            s.run('xcrun','clang','-arch',arch,'-g','-c',source,'-o',obj)
            s.run('xcrun','clang','-arch',arch,'-dynamiclib',obj,'-o',binary); bins.append(binary)
        s.run('xcrun','lipo','-create',*bins,'-output',cls.binary)
        cls.expected = s.uuids(cls.binary)
        cls.output = cls.root / 'output'

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def test_01_collect_exact_universal_symbols(self):
        result = s.collect(self.app, self.output, [self.sources])
        self.assertEqual(result['uuid'], self.expected)
        self.assertEqual(result['result'], 'installed')
        s.validate(self.output / 'objective_c.framework.dSYM', self.expected)

    def test_02_replay_is_noop(self):
        self.assertEqual(s.collect(self.app,self.output,[self.sources])['result'],'already-present')

    def test_03_no_matching_source_fails(self):
        with self.assertRaisesRegex(RuntimeError,'No original UUID-matched'):
            s.collect(self.app,self.root/'absent-output',[self.root/'absent'])

    def test_04_wrong_uuid_rejected(self):
        with self.assertRaisesRegex(RuntimeError,'UUID mismatch'):
            s.validate(self.output/'objective_c.framework.dSYM',{'arm64':'00000000-0000-0000-0000-000000000000'})

    def test_05_empty_symbols_rejected(self):
        source=self.root/'stripped.c';source.write_text('int no_debug(void) { return 1; }\n')
        binary=self.root/'stripped.dylib';bundle=self.root/'empty.dSYM'
        s.run('xcrun','clang','-dynamiclib',source,'-o',binary)
        s.run('xcrun','dsymutil',binary,'-o',bundle)
        with self.assertRaisesRegex(RuntimeError,'no genuine compilation unit'):
            s.validate(bundle,s.uuids(binary))

    def test_06_missing_original_objects_rejected(self):
        root=self.root/'lost';root.mkdir();source=root/'x.c';source.write_text('int lost_debug(void) { return 2; }\n')
        obj=root/'x.o';binary=root/'objective_c.dylib'
        s.run('xcrun','clang','-g','-c',source,'-o',obj);s.run('xcrun','clang','-dynamiclib',obj,'-o',binary);obj.unlink()
        app=root/'App.app';target=app/'Contents/Frameworks/objective_c.framework/Versions/A/objective_c';target.parent.mkdir(parents=True)
        import shutil
        shutil.copy2(binary,target)
        with self.assertRaisesRegex(RuntimeError,'objects are missing or empty'):
            s.collect(app,root/'output',[root])

    def test_07_symlink_destination_is_rejected(self):
        link=self.root/'symlink.dSYM';link.symlink_to(self.output/'objective_c.framework.dSYM',target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError,'symlink'):
            s.install_bundle(self.output/'objective_c.framework.dSYM',link,self.expected)

    def test_08_nonarchive_helper_is_noop(self):
        with patch.dict(os.environ,{'ACTION':'build'},clear=True):
            self.assertEqual(s.xcode_helper(),{'result':'skipped-non-archive'})

    def test_09_invalid_architecture_prevents_build(self):
        source=self.root/'main.swift';source.write_text('print("Test")\n')
        with self.assertRaisesRegex(RuntimeError,'supported macOS architectures'):
            s.build_helper(source,self.root/'invalid-helper',['arm64e'],'10.15')

    def test_10_replacement_requires_opt_in_and_stages_before_switch(self):
        from shutil import copytree
        source=self.output/'objective_c.framework.dSYM';other=self.root/'existing.dSYM';copytree(source,other)
        expected={'arm64':self.expected['arm64']};thin=self.root/'thin.dSYM';copytree(source,thin)
        original=s.dwarf_file(thin);fat=self.root/'fat';original.rename(fat)
        s.run('xcrun','lipo',fat,'-thin','arm64','-output',original)
        before=s.dwarf_file(other).read_bytes()
        with self.assertRaisesRegex(RuntimeError,'UUID mismatch'):s.install_bundle(thin,other,expected)
        self.assertEqual(s.dwarf_file(other).read_bytes(),before)
        self.assertEqual(s.install_bundle(thin,other,expected,replace=True),'installed')
        s.validate(other,expected)


if __name__=='__main__': unittest.main(verbosity=2)
