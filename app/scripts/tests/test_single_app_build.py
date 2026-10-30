"""Destructive filesystem and rollback regressions, entirely in disposable trees."""
import fcntl
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'single_app_build.py'
spec = importlib.util.spec_from_file_location('single_app_build', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SingleAppBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='single-app-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def lifecycle(self, product):
        life = module.Lifecycle(product, self.root / product / 'repo',
                                self.root / product / 'home', self.root / product / 'Applications')
        life.repo.mkdir(parents=True, exist_ok=True)
        life.register = lambda *a, **k: None
        life.processes = lambda: []
        life.copy = lambda src, dst: shutil.copytree(src, dst, symlinks=True)
        life.launch = lambda *a, **k: None
        life.verify = lambda app: life.info(app)
        # Never enumerate the real home, global caches or /private/tmp in tests.
        life.scopes = lambda: [life.repo / 'build', life.home / 'Applications', life.applications]
        return life

    def app(self, path, bid, payload='old', platform='MacOSX'):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bid, 'CFBundleExecutable': 'program',
            'CFBundleSupportedPlatforms': [platform]}))
        binary = path / 'Contents/MacOS/program'
        binary.write_text(payload)
        binary.chmod(0o755)
        return path

    def payload(self, app):
        return (app / 'Contents/MacOS/program').read_text()

    def data(self, life):
        paths = [life.home / x for x in (
            'Desktop/SpeakSend Records/record.md', 'Library/Application Support/product/ai.json',
            'Library/Preferences/product.plist', '.ollama/models/model.bin')]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'private bytes\x00')
        return {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in paths}

    def test_each_product_installs_one_and_preserves_all_personal_data(self):
        for product in ('SpeakSend', 'MacDefier'):
            with self.subTest(product=product):
                life = self.lifecycle(product)
                self.app(life.destination, life.bundle_id)
                source = self.app(life.repo / 'build/Release' / (product + '.app'), life.bundle_id, 'new')
                alternate_root = life.applications if product == 'SpeakSend' else life.home / 'Applications'
                duplicate = self.app(alternate_root / (product + '.app'), life.bundle_id)
                other = self.app(life.repo / 'build/Other.app', 'org.example.other')
                mobile = self.app(life.repo / 'build/phone/SpeakSend.app', 'com.speaksend.app.mobile', platform='iPhoneOS')
                private = self.data(life)
                life.install(source, ['--fixture'])
                life.cleanup()
                self.assertEqual(self.payload(life.destination), 'new')
                self.assertFalse(source.exists())
                self.assertFalse(duplicate.exists())
                self.assertTrue(other.exists() and mobile.exists())
                self.assertEqual(private, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in private})
                self.assertEqual(list(life.destination.parent.glob('.*-previous-*')), [])

    def test_launch_failure_restores_old_and_removes_new_staging(self):
        life = self.lifecycle('SpeakSend')
        self.app(life.destination, life.bundle_id)
        source = self.app(life.repo / 'build/SpeakSend.app', life.bundle_id, 'new')
        launches = []
        def launch(app, args=()):
            launches.append(self.payload(app))
            if len(launches) == 1:
                raise RuntimeError('launch failed')
        life.launch = launch
        with self.assertRaisesRegex(RuntimeError, 'launch failed'):
            life.install(source)
        self.assertEqual(launches, ['new', 'old'])
        self.assertEqual(self.payload(life.destination), 'old')
        self.assertEqual(sorted(p.name for p in life.destination.parent.iterdir()), ['SpeakSend.app'])

    def test_failed_second_rename_restores_old(self):
        life = self.lifecycle('SpeakSend')
        self.app(life.destination, life.bundle_id)
        source = self.app(life.repo / 'build/SpeakSend.app', life.bundle_id, 'new')
        rename = Path.rename
        def fail_incoming(path, target):
            if '-incoming-' in path.name and target == life.destination:
                raise OSError('replacement failed')
            return rename(path, target)
        with patch.object(Path, 'rename', fail_incoming):
            with self.assertRaisesRegex(OSError, 'replacement failed'):
                life.install(source)
        self.assertEqual(self.payload(life.destination), 'old')
        self.assertEqual(len(list(life.destination.parent.iterdir())), 1)

    def test_signature_failure_on_copied_app_never_touches_old(self):
        life = self.lifecycle('SpeakSend')
        self.app(life.destination, life.bundle_id)
        source = self.app(life.repo / 'build/SpeakSend.app', life.bundle_id)
        def verify(app):
            if '-incoming-' in Path(app).name:
                raise ValueError('invalid copied signature')
        life.verify = verify
        with self.assertRaisesRegex(ValueError, 'signature'):
            life.install(source)
        self.assertEqual(self.payload(life.destination), 'old')
        self.assertEqual(len(list(life.destination.parent.iterdir())), 1)

    def test_cancelled_quit_preserves_old_and_does_not_force_kill(self):
        life = self.lifecycle('MacDefier')
        self.app(life.destination, life.bundle_id)
        source = self.app(life.repo / 'build/MacDefier.app', life.bundle_id, 'new')
        life.quit = lambda app: (_ for _ in ()).throw(RuntimeError('quit cancelled'))
        with self.assertRaisesRegex(RuntimeError, 'quit cancelled'):
            life.install(source)
        self.assertEqual(self.payload(life.destination), 'old')
        self.assertEqual(len(list(life.destination.parent.iterdir())), 1)

    def test_running_duplicate_is_preserved_and_failure_reported(self):
        life = self.lifecycle('SpeakSend')
        duplicate = self.app(life.repo / 'build/SpeakSend.app', life.bundle_id)
        life.processes = lambda: [str(duplicate / 'Contents/MacOS/program')]
        with self.assertRaisesRegex(RuntimeError, 'Running duplicate'):
            life.cleanup()
        self.assertTrue(duplicate.exists())

    def test_symlink_app_cannot_redirect_cleanup_to_personal_data(self):
        life = self.lifecycle('SpeakSend')
        personal = self.app(life.home / 'Documents/SpeakSend.app', life.bundle_id)
        link = life.repo / 'build/SpeakSend.app'
        link.parent.mkdir()
        link.symlink_to(personal, target_is_directory=True)
        life.cleanup()
        self.assertTrue(personal.exists() and link.is_symlink())
        with self.assertRaises(ValueError):
            life.install(link)

    def test_production_install_rejects_separate_dev_identity(self):
        life = self.lifecycle('MacDefier')
        dev = self.app(life.repo / 'build/MacDefier-Dev.app', 'com.macdefier.app.dev')
        # Exercise the real identity gate; signature verification must not be reached.
        with self.assertRaisesRegex(ValueError, 'production bundle identity'):
            module.Lifecycle.verify(life, dev)

    def test_build_root_cannot_be_data_directory_or_symlink_escape(self):
        life = self.lifecycle('SpeakSend')
        for path in (life.home, life.repo, life.home / 'Library/Application Support/SpeakSend'):
            with self.assertRaises(ValueError):
                life.validate_build_root(path)
        link = life.repo / 'build'
        link.symlink_to(life.home, target_is_directory=True)
        with self.assertRaises(ValueError):
            life.validate_build_root(link)

    def test_failed_job_removes_its_build_app_and_owned_work(self):
        life = self.lifecycle('SpeakSend')
        self.app(life.destination, life.bundle_id)
        duplicate = self.app(life.repo / 'build/SpeakSend.app', life.bundle_id)
        work_file = self.root / 'observed-work'
        command = [sys.executable, '-c',
                   'import os,pathlib,sys; p=pathlib.Path(os.environ["SINGLE_APP_WORK"]); '
                   '(p/"partial.app").mkdir(); pathlib.Path(sys.argv[1]).write_text(str(p)); sys.exit(17)',
                   str(work_file)]
        self.assertEqual(life.run(command), 17)
        self.assertFalse(Path(work_file.read_text()).exists())
        self.assertFalse(duplicate.exists())
        self.assertEqual(self.payload(life.destination), 'old')

    def test_common_lock_rejects_a_second_job(self):
        life = self.lifecycle('SpeakSend')
        lock_dir = life.home / 'Library/Caches/SpeakSend-build-control'
        lock_dir.mkdir(parents=True)
        with (lock_dir / 'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, 'already running'):
                life.run(['/usr/bin/true'])

    def test_partial_xcode_mac_output_removed_but_ios_output_preserved(self):
        life = self.lifecycle('SpeakSend')
        partial = life.repo / 'build/Build/Products/Debug/SpeakSend.app'
        (partial / 'Contents').mkdir(parents=True)
        mobile = life.repo / 'build/Build/Products/Debug-iphoneos/SpeakSend.app'
        mobile.mkdir(parents=True)
        (mobile / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.speaksend.app.mobile'}))
        life.cleanup()
        self.assertFalse(partial.exists())
        self.assertTrue(mobile.exists())

    def test_system_aliases_normalized_without_following_user_links(self):
        self.assertEqual(module.system_path('/tmp/SpeakSend.app'), Path('/private/tmp/SpeakSend.app'))
        self.assertEqual(module.system_path('/var/folders/stage'), Path('/private/var/folders/stage'))
        life = self.lifecycle('SpeakSend')
        cache = life.home / 'Library/Caches/SpeakSend-build'
        cache.parent.mkdir(parents=True)
        data = life.home / 'Documents'
        data.mkdir()
        cache.symlink_to(data, target_is_directory=True)
        # Restore the cache scope to exercise malicious root aliases.
        life.scopes = lambda: [cache]
        with self.assertRaises(ValueError):
            life.validate_build_root(cache)

    def test_successful_install_consumes_only_explicit_external_app_source(self):
        life = self.lifecycle('SpeakSend')
        self.app(life.destination, life.bundle_id)
        source = self.app(life.home / 'Downloads/SpeakSend.app', life.bundle_id, 'new')
        sibling = source.parent / 'personal.md'
        sibling.write_text('keep')
        life.install(source)
        self.assertFalse(source.exists())
        self.assertEqual(sibling.read_text(), 'keep')
        self.assertEqual(self.payload(life.destination), 'new')


if __name__ == '__main__':
    unittest.main()
