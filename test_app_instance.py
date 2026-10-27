"""Real concurrent helper processes, isolated locks/ports; no apps, collectors or user settings."""
import subprocess
import tempfile
import time
import unittest
import uuid
from pathlib import Path


class AppInstanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='inbox-access-')
        self.root = Path(self.temp.name)
        self.namespace = 'local.codex.inbox.tests.' + uuid.uuid4().hex
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None: child.kill()
            child.communicate(timeout=3)
        self.temp.cleanup()

    def command(self, mode='open', duration=1.3, delay=0, root=None, namespace=None):
        return ['build/app-instance-probe', str(root or self.root), namespace or self.namespace, mode, str(duration), str(delay)]

    def spawn(self, **kw):
        child = subprocess.Popen(self.command(**kw), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def lines(self, name):
        path = self.root / name
        return path.read_text().splitlines() if path.exists() else []

    def test_simultaneous_launches_one_service_owner(self):
        first, second = self.spawn(), self.spawn()
        results = [child.communicate(timeout=3) for child in (first, second)]
        self.assertEqual(sorted(r[0].strip() for r in results), ['EXISTING', 'OWNER'])
        self.assertTrue(all(child.returncode == 0 for child in (first, second)), results)
        self.assertEqual(self.lines('services.log'), ['services'])
        self.assertEqual(self.lines('requests.log'), ['open'])

    def test_initialization_retry_and_background_duplicate(self):
        owner = self.spawn(delay=0.35)
        self.assertEqual(owner.stdout.readline().strip(), 'OWNER')
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        silent = subprocess.run(self.command(mode='background'), capture_output=True, text=True, timeout=1)
        self.assertEqual(silent.stdout.strip(), 'EXISTING')
        self.assertEqual(self.lines('requests.log'), ['open'])
        self.assertEqual(self.lines('services.log'), ['services'])

    def test_unresponsive_legacy_owner_fails_closed(self):
        owner = self.spawn(mode='legacy', duration=2)
        self.assertEqual(owner.stdout.readline().strip(), 'LEGACY')
        start = time.monotonic()
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 2)
        self.assertIn('did not acknowledge', result.stderr)
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertEqual(self.lines('services.log'), [])
        silent = subprocess.run(self.command(mode='background'), capture_output=True, text=True, timeout=1)
        self.assertEqual(silent.returncode, 0)

    def test_crashed_owner_and_clean_exit_release_same_lock(self):
        owner = self.spawn(duration=5)
        self.assertEqual(owner.stdout.readline().strip(), 'OWNER')
        inode = (self.root / 'instance.lock').stat().st_ino
        owner.kill(); owner.communicate(timeout=2)
        for _ in range(2):
            result = subprocess.run(self.command(duration=0.05), capture_output=True, text=True, timeout=2)
            self.assertEqual(result.stdout.strip(), 'OWNER', result.stderr)
            self.assertEqual((self.root / 'instance.lock').stat().st_ino, inode)
        self.assertEqual(len(self.lines('services.log')), 3)

    def test_invalid_requests_and_separate_preview_namespaces(self):
        owner = self.spawn()
        self.assertEqual(owner.stdout.readline().strip(), 'OWNER')
        invalid = subprocess.run(self.command(mode='invalid'), capture_output=True, text=True, timeout=2)
        self.assertEqual(invalid.stdout.strip(), 'REJECTED', invalid.stderr)
        self.assertEqual(self.lines('requests.log'), [])
        preview = self.root / 'preview'; preview.mkdir()
        result = subprocess.run(self.command(duration=0.05, root=preview, namespace=self.namespace + '.preview'), capture_output=True, text=True, timeout=2)
        self.assertEqual(result.stdout.strip(), 'OWNER', result.stderr)
        self.assertEqual(self.lines('services.log'), ['services'])

    def test_symlink_lock_fails_without_modifying_target(self):
        target = self.root / 'preserved'; target.write_text('preserve this')
        (self.root / 'instance.lock').symlink_to(target)
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(target.read_text(), 'preserve this')
        self.assertEqual(self.lines('services.log'), [])


if __name__ == '__main__': unittest.main()
