import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('package_release',Path(__file__).with_name('package_release.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ArchitectureTests(unittest.TestCase):
    def test_windows_executable_rejects_stale_upstream_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError): m.windows_executable(root)
            (root / 'LegnaSend.exe').write_bytes(b'fixture')
            self.assertEqual(m.windows_executable(root), root / 'LegnaSend.exe')
            (root / 'localsend_app.exe').write_bytes(b'stale')
            with self.assertRaises(ValueError): m.windows_executable(root)

    def test_windows_branding_contract(self):
        root = Path(__file__).resolve().parents[3]
        self.assertIn('set(BINARY_NAME "LegnaSend")', (root / 'app/windows/CMakeLists.txt').read_text())
        rc = (root / 'app/windows/runner/Runner.rc').read_text()
        for field in ('InternalName', 'ProductName', 'FileDescription'):
            self.assertIn(f'"{field}", "LegnaSend"', rc)
        self.assertIn('"OriginalFilename", "LegnaSend.exe"', rc)
        self.assertIn('"CompanyName", "Legna"', rc)
        self.assertIn('Tien Do Nam', rc)  # Preserve legal attribution.
        self.assertTrue((root / 'app/windows/LegnaSend.exe.manifest').is_file())
        self.assertFalse((root / 'app/windows/localsend_app.exe.manifest').exists())
        self.assertIn('publisher="CN=LegnaSend"', (root / 'app/windows/LegnaSend.exe.manifest').read_text())
        inno = (root / 'support/scripts/compile_windows_exe-inno.iss').read_text()
        self.assertIn('#define MyAppExeName "LegnaSend.exe"', inno)
        self.assertIn('OutputBaseFilename=LegnaSend', inno)
        manifest = (root / 'support/build/msix/content/AppxManifest.xml').read_text()
        self.assertEqual(manifest.count('Executable="LegnaSend.exe"'), 2)
        self.assertNotIn('DisplayName="LocalSend"', manifest)
        self.assertIn('Identity Name="LocalSend.App"', manifest)  # Stable package identity.
        ci = (root / 'support/scripts/ci/build_windows.ps1').read_text()
        self.assertIn('$versionInfo = (Get-Item $executable).VersionInfo', ci)
        self.assertIn('$versionInfo.OriginalFilename', ci)

    def test_pe(self):
        for code in [0x8664,0xaa64]:
            b=bytearray(128);b[:2]=b'MZ';struct.pack_into('<I',b,0x3c,64);b[64:68]=b'PE\0\0';struct.pack_into('<H',b,68,code)
            self.assertEqual(m.machine(b),code)
    def test_elf(self):
        for code in [62,183]:
            b=bytearray(64);b[:6]=b'\x7fELF\x02\x01';struct.pack_into('<H',b,18,code)
            self.assertEqual(m.machine(b),code)
    def test_pe_import_names_and_bad_rva(self):
        b=bytearray(1024);b[:2]=b'MZ';struct.pack_into('<I',b,0x3c,64);b[64:68]=b'PE\0\0'
        struct.pack_into('<H',b,70,1);struct.pack_into('<H',b,84,240);struct.pack_into('<H',b,88,0x20b)
        struct.pack_into('<II',b,208,0x1000,40);struct.pack_into('<IIII',b,336,512,0x1000,512,512)
        struct.pack_into('<IIIII',b,512,1,0,0,0x1058,1);b[600:617]=b'VCRUNTIME140.dll\0'
        self.assertEqual(m.pe_imports(b),['vcruntime140.dll'])
        struct.pack_into('<I',b,524,0x9000)
        with self.assertRaises(ValueError):m.pe_imports(b)
    def test_invalid_and_32_bit(self):
        for data in [b'notbinary',b'\x7fELF\x01\x01'+bytes(58)]:
            with self.assertRaises(ValueError):m.machine(data)
if __name__=='__main__':unittest.main()
