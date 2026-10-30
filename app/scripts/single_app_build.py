#!/usr/bin/env python3
"""Serialize build entry points, install transactionally, remove only app builds.

Kept in each product repository so neither checkout depends on its sibling.
No preferences, Application Support, Keychain, records or model paths are used.
"""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

PRODUCT = "MacDefier"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def system_path(path):
    """Normalize macOS's system aliases without following user-created links."""
    path = Path(path).absolute()
    for alias in ('/tmp', '/var'):
        base = Path(alias)
        if path == base or base in path.parents:
            return Path('/private') / path.relative_to('/')
    return path


class Lifecycle:
    def __init__(self, product, repo, home=None, applications=Path('/Applications')):
        self.product = product
        self.repo = Path(repo).resolve()
        self.home = Path.home() if home is None else Path(home)
        self.applications = Path(applications)
        self.bundle_id = 'com.speaksend.app' if product == 'SpeakSend' else 'com.macdefier.app'
        self.ids = {self.bundle_id}
        if product == 'MacDefier':
            self.ids.add('com.macdefier.app.dev')  # cleanup only; never install this identity
        self.destination = ((self.home / 'Applications') if product == 'SpeakSend'
                            else self.applications) / (product + '.app')

    def info(self, app):
        app = system_path(app)
        # Do not traverse aliases into another application's bundle or data.
        if any(p.is_symlink() for p in (app, *app.parents)):
            raise ValueError(f'Symlinked app path: {app}')
        with (app / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        executable = info.get('CFBundleExecutable', '')
        if (info.get('CFBundleIdentifier') not in self.ids or
                not executable or Path(executable).name != executable or executable in ('.', '..') or
                not (app / 'Contents/MacOS' / executable).is_file() or
                not os.access(app / 'Contents/MacOS' / executable, os.X_OK) or
                any(p != 'MacOSX' for p in info.get('CFBundleSupportedPlatforms', []))):
            raise ValueError(f'Not a {self.product} Mac application: {app}')
        return info

    def verify(self, app):
        if self.info(app)['CFBundleIdentifier'] != self.bundle_id:
            raise ValueError('Install requires the existing production bundle identity; rebuild Release.')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)

    def register(self, app, remove=False):
        if Path(LSREGISTER).exists():
            subprocess.run([LSREGISTER, '-u' if remove else '-f', str(app)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def processes(self):
        result = subprocess.run(['/bin/ps', '-axo', 'comm='], capture_output=True, text=True, check=True)
        return result.stdout.splitlines()

    def running(self, app, processes=None):
        lines = self.processes() if processes is None else processes
        return any(line.strip().startswith(str(app) + '/Contents/') for line in lines)

    def quit(self, app):
        if not self.running(app):
            return
        # Normal application termination preserves pending writes; never SIGKILL.
        subprocess.run(['/usr/bin/osascript', '-e',
                        'on run argv\ntell application (item 1 of argv) to quit\nend run', str(app)],
                       check=True, timeout=20)
        deadline = time.monotonic() + 20
        while self.running(app):
            if time.monotonic() >= deadline:
                raise RuntimeError(f'Application is still saving or quit was cancelled: {app}')
            time.sleep(0.2)

    def copy(self, source, destination):
        subprocess.run(['/usr/bin/ditto', str(source), str(destination)], check=True)

    def launch(self, app, args=()):
        subprocess.run(['/usr/bin/open', str(app)] + (['--args', *args] if args else []), check=True)

    def consume(self, source):
        """Remove only the explicitly installed app source, never its parent."""
        source = system_path(source)
        if source == self.destination:
            return
        if not source.name.endswith('.app'):
            raise ValueError('Installation source must be an app bundle')
        self.info(source)
        if Path('/Volumes') in source.parents:
            return  # a mounted installer is read-only, not a second local installation
        if self.running(source):
            raise RuntimeError(f'Installed source is still running: {source}')
        self.register(source, remove=True)
        shutil.rmtree(source)

    def install(self, source, args=()):
        source = system_path(source)
        self.verify(source)
        target = self.destination
        if source == target:
            self.launch(target, args)
            return
        if target.exists() or target.is_symlink():
            self.info(target)  # refuse to replace an unexpected directory or alias
        target.parent.mkdir(parents=True, exist_ok=True)
        if any(p.is_symlink() for p in (target.parent, *target.parent.parents)):
            raise ValueError('Symlinked installation directory')
        token = uuid.uuid4().hex
        incoming = target.parent / ('.' + self.product + '-incoming-' + token)
        previous = target.parent / ('.' + self.product + '-previous-' + token)
        committed = False
        try:
            self.copy(source, incoming)
            self.verify(incoming)  # verify exact bytes before touching existing installation
            self.quit(target)
            if target.exists():
                self.register(target, remove=True)
                target.rename(previous)
            try:
                incoming.rename(target)
                self.verify(target)
                self.register(target)
                self.launch(target, args)
                committed = True
            except BaseException:
                if target.exists():
                    self.register(target, remove=True)
                    target.rename(incoming)
                if previous.exists():
                    previous.rename(target)
                    self.register(target)
                    self.launch(target)
                raise
        finally:
            if incoming.exists():
                shutil.rmtree(incoming)
            if committed and previous.exists():
                shutil.rmtree(previous)
            # An un-restored previous bundle is intentionally retained on an OS
            # rename error. Report failure instead of deleting the only old app.
            if previous.exists():
                raise RuntimeError(f'Restore required; old app retained at {previous}')
        self.consume(source)

    def scopes(self):
        roots = [self.repo / 'dist', self.repo / 'build', self.repo / '.build',
                 self.repo / 'app/build', self.home / 'Applications', self.applications]
        if self.product == 'SpeakSend':
            roots.append(self.home / 'ss-demo-work')
        # Only product-specific build caches, never application data or model caches.
        roots.extend((self.home / 'Library/Caches').glob(self.product + '-*'))
        roots.extend(Path('/private/tmp').glob(self.product.lower() + '-*'))
        roots.extend(Path('/private/tmp').glob(self.product + '-*'))
        return roots

    def validate_build_root(self, root):
        root = Path(root).resolve()
        allowed = [self.repo / x for x in ('dist', 'build', '.build', 'app/build')]
        allowed += [p.resolve() for p in self.scopes()
                    if p.parent in (self.home / 'Library/Caches', Path('/private/tmp'))
                    and not any(q.is_symlink() for q in (p, *p.parents))]
        if not any(root == p or p in root.parents for p in allowed):
            raise ValueError(f'Not a product build directory: {root}')
        return root

    def cleanup(self, extra_roots=()):
        processes = self.processes()  # fail closed if process enumeration is unavailable
        seen = set()
        failures = []
        for root in [*self.scopes(), *extra_roots]:
            root = Path(root)
            if root.is_symlink() or not root.is_dir():
                continue
            # Application folders are shallow: never inspect another app's embedded helpers.
            shallow = root in (self.home / 'Applications', self.applications)
            for base, dirs, _ in os.walk(root, followlinks=False):
                dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', 'SourcePackages')]
                for name in list(dirs):
                    app = Path(base) / name
                    if not name.endswith('.app'):
                        continue
                    dirs.remove(name)
                    if app in seen or app == self.destination:
                        continue
                    seen.add(app)
                    try:
                        self.info(app)
                    except (OSError, ValueError, plistlib.InvalidFileException):
                        # Xcode may fail before writing Info.plist. Only exact
                        # product leaves inside Build/Products are owned output;
                        # an unrelated or differently identified app stays intact.
                        if (any(p.is_symlink() for p in (app, *app.parents)) or
                                (app / 'Info.plist').exists() or  # iOS bundle layout
                                not (app / 'Contents').is_dir() or
                                name not in (self.product + '.app', self.product + '-Dev.app') or
                                'Build/Products/' not in str(app)):
                            continue
                        metadata = app / 'Contents/Info.plist'
                        if metadata.exists():
                            try:
                                info = plistlib.loads(metadata.read_bytes())
                                if (info.get('CFBundleIdentifier') not in self.ids or
                                        any(p != 'MacOSX' for p in info.get('CFBundleSupportedPlatforms', []))):
                                    continue
                            except (OSError, ValueError, plistlib.InvalidFileException):
                                continue
                    if self.running(app, processes):
                        failures.append(f'Running duplicate retained: {app}')
                        continue
                    self.register(app, remove=True)
                    try:
                        shutil.rmtree(app)
                        print(f'Removed app build: {app}', flush=True)
                    except OSError as error:
                        failures.append(str(error))
                if shallow:
                    break
        if failures:
            raise RuntimeError('\n'.join(failures))

    def run(self, command):
        # A common per-user/product lock covers builds, packaging and installation.
        lock_dir = self.home / 'Library/Caches' / (self.product + '-build-control')
        if any(p.is_symlink() for p in (lock_dir, *lock_dir.parents)) or (lock_dir / 'lock').is_symlink():
            raise ValueError('Symlinked build lock directory/file')
        lock_dir.mkdir(parents=True, exist_ok=True)
        with (lock_dir / 'lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError(f'{self.product}: another build/install is already running')
            with tempfile.TemporaryDirectory(prefix=self.product.lower() + '-job-', suffix='.noindex') as work:
                work = str(Path(work).resolve())
                env = dict(os.environ, SINGLE_APP_PRODUCT=self.product, SINGLE_APP_WORK=work)
                child = subprocess.Popen(command, env=env, start_new_session=True)
                def forward(signum, _frame):
                    if child.poll() is None:
                        os.killpg(child.pid, signum)
                old_handlers = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
                try:
                    result = child.wait()
                finally:
                    for signum, handler in old_handlers.items():
                        signal.signal(signum, handler)
                    tracked = Path(work) / 'build-roots.jsonl'
                    roots = [self.validate_build_root(json.loads(line))
                             for line in tracked.read_text().splitlines()] if tracked.exists() else []
                    try:
                        self.cleanup(roots)
                    finally:
                        # Only this job owns this tree. Also unregister partially
                        # assembled apps, which may not have Info.plist yet.
                        for base, dirs, _ in os.walk(work):
                            for name in list(dirs):
                                if name.endswith('.app'):
                                    dirs.remove(name)
                                    self.register(Path(base) / name, remove=True)
                return result


def main():
    script = Path(__file__).resolve()
    repo = script.parent.parent if PRODUCT == 'SpeakSend' else script.parent.parent.parent
    lifecycle = Lifecycle(PRODUCT, repo)
    action, *args = sys.argv[1:]
    if action == 'run':
        return lifecycle.run(args)
    if os.environ.get('SINGLE_APP_PRODUCT') != PRODUCT or not os.environ.get('SINGLE_APP_WORK'):
        raise RuntimeError('Invoke through a build/install entry point')
    if action == 'track':
        root = lifecycle.validate_build_root(args[0])
        with (Path(os.environ['SINGLE_APP_WORK']) / 'build-roots.jsonl').open('a') as stream:
            stream.write(json.dumps(str(root)) + '\n')
    elif action == 'install':
        lifecycle.install(args[0], args[1:])
    elif action == 'check-build-source':
        source = system_path(args[0])
        if lifecycle.info(source)['CFBundleIdentifier'] != lifecycle.bundle_id:
            raise ValueError('Not the production app identity')
        lifecycle.validate_build_root(source.parent)
    elif action == 'consume':
        lifecycle.consume(args[0])
    elif action == 'cleanup':
        tracked = Path(os.environ['SINGLE_APP_WORK']) / 'build-roots.jsonl'
        roots = [lifecycle.validate_build_root(json.loads(line))
                 for line in tracked.read_text().splitlines()] if tracked.exists() else []
        lifecycle.cleanup(roots)
    else:
        raise ValueError(f'Unknown action: {action}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
