import unittest
from publish_release import release_version

class ReleaseTagTests(unittest.TestCase):
    def test_original(self):
        self.assertEqual(release_version('v1.0.0'), '1.0.0')
    def test_package_revisions_keep_binary_version(self):
        for revision in ('2', '9', '10', '21'):
            self.assertEqual(release_version('v1.0.0-r' + revision), '1.0.0')
    def test_invalid(self):
        for tag in ('v1.0.0-r0', 'v1.0.0-r1', 'v1.0.0-r02', 'v1.0.0-rc1', 'v1.0.0/../x', '1.0.0', 'v1.0.0-r2\n'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version(tag)
if __name__ == '__main__':
    unittest.main()
