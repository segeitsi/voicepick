"""Publication checks use an isolated repository with synthetic data only."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class PublicFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bb-dv-public-check-')
        self.repo = Path(self.temp.name)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        (self.repo / 'scripts').mkdir()
        shutil.copyfile(ROOT / 'scripts/check-public-files.py', self.repo / 'scripts/check-public-files.py')
        (self.repo / 'README.md').write_text('# Synthetic test project\n')
        self.git('add', 'README.md', 'scripts/check-public-files.py')

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True)

    def audit(self):
        return subprocess.run(['python3', str(self.repo / 'scripts/check-public-files.py')], capture_output=True, text=True)

    def test_source_only_passes(self):
        self.assertEqual(self.audit().returncode, 0)

    def test_reference_bank_is_rejected(self):
        (self.repo / 'Sources').mkdir()
        (self.repo / 'Sources/reference-bank-v1.json').write_text('{"synthetic": true}')
        self.git('add', 'Sources/reference-bank-v1.json')
        self.assertNotEqual(self.audit().returncode, 0)

    def test_staged_secret_is_rejected_after_working_file_is_cleaned(self):
        code = self.repo / 'Sources'
        code.mkdir()
        secret = 'ghp_' + 'A' * 36
        (code / 'Example.swift').write_text('let synthetic = "' + secret + '"\n')
        self.git('add', 'Sources/Example.swift')
        (code / 'Example.swift').write_text('// Working copy no longer contains the staged value\n')
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stderr)

    def test_personal_image_is_rejected(self):
        image = self.repo / 'Tests/portrait.jpg'
        image.parent.mkdir()
        image.write_bytes(b'synthetic fixture, not a real image')
        self.git('add', 'Tests/portrait.jpg')
        self.assertNotEqual(self.audit().returncode, 0)

    def test_symlink_is_rejected(self):
        (self.repo / 'Sources').mkdir()
        (self.repo / 'Sources/Example.swift').symlink_to('../README.md')
        self.git('add', 'Sources/Example.swift')
        (self.repo / 'Sources/Example.swift').unlink()
        (self.repo / 'Sources/Example.swift').write_text('// Working file is regular, staged entry is still a symlink\n')
        self.assertNotEqual(self.audit().returncode, 0)


if __name__ == '__main__':
    unittest.main()
