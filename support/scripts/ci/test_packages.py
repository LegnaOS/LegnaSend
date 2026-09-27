import importlib.util
import struct
import unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('package_release',Path(__file__).with_name('package_release.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ArchitectureTests(unittest.TestCase):
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
