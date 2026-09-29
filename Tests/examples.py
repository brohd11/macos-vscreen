"""Exercise layout scripts without touching the user's displays."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PRESET = ROOT / 'presets' / 'xreal-uw'


class LayoutTests(unittest.TestCase):
    def invoke(self, triple, width=3840, height=1080, scenario='normal'):
        with tempfile.TemporaryDirectory(prefix='vs-layout-', dir='/tmp') as directory:
            root = pathlib.Path(directory)
            fake = root / 'vscreen'
            fake.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ['LAYOUT_FIXTURE'])
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(json.dumps(args) + '\\n')
scenario = os.environ['LAYOUT_SCENARIO']
ready = (root / 'ready').exists()
if args == ['screens', '--find', 'XREAL*']:
    if scenario == 'missing': sys.exit(1)
    print('2')
elif args == ['screens', '--main']: print('1')
elif args == ['screens', '1', '--origin']: print('0x0')
elif args == ['screens', '1', '--size']: print('1408x881')
elif args == ['screens', '2', '--size']:
    if ready and scenario == 'disconnect': sys.exit(1)
    print('1920x1080' if ready and scenario == 'resize' else os.environ['LAYOUT_SIZE'])
elif args == ['screens', '2', '--origin']:
    print('-1216x-2160' if ready else '1408x-540')
elif args[:2] == ['--new', 'UWRight']:
    if scenario == 'failure': sys.exit(7)
    (root / 'ready').touch()
elif args and args[0] in ('--new', 'UWLeft', 'UWCenter', 'UWRight'): pass
else: sys.exit(9)
''')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=directory, LAYOUT_FIXTURE=directory,
                       LAYOUT_SCENARIO=scenario, LAYOUT_SIZE=f'{width}x{height}')
            env.pop('VSCREEN_BIN', None)
            filename = 'xreal-uw-triple.sh' if triple else 'xreal-uw-dual.sh'
            result = subprocess.run([str(PRESET / 'layout' / filename)], env=env,
                                    capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            return result, calls

    def test_resolutions_and_previews_cover_target(self):
        for triple in (False, True):
            for width, height in ((3840, 1080), (1920, 1080), (2560, 1440), (3841, 1081), (1920, 480)):
                with self.subTest(triple=triple, width=width, height=height):
                    result, calls = self.invoke(triple, width, height)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    if triple:
                        sizes = {'UWLeft': width // 4, 'UWCenter': width - 2 * (width // 4), 'UWRight': width // 4}
                    else:
                        sizes = {'UWLeft': width // 2, 'UWRight': width - width // 2}
                    created = {c[1]: c for c in calls if c[0] == '--new'}
                    shown = {c[0]: c for c in calls if '--show' in c}
                    self.assertEqual(set(created), set(sizes))
                    self.assertEqual(set(shown), set(sizes))
                    offset = 0
                    origin_x = int((1408 - width) / 2)  # POSIX shell truncates toward zero.
                    for name, w in sizes.items():
                        create, show = created[name], shown[name]
                        self.assertEqual(create[create.index('--resolution') + 1], f'{w}x{height}')
                        self.assertEqual(create[create.index('--size') + 1], f'{w}x{height}')
                        self.assertEqual(create[create.index('--origin') + 1], f'{origin_x + offset}x{-height}')
                        self.assertIn('--hide', create)
                        self.assertEqual(show[show.index('--size') + 1], f'{w}x{height}')
                        self.assertEqual(show[show.index('--position') + 1], f'{-1216 + offset}x-2160')
                        offset += w
                    self.assertEqual(offset, width)
                    self.assertFalse(any('--close' in c for c in calls))

    def test_invalid_geometry_does_not_mutate(self):
        for triple, width, height in ((False, 959, 1080), (True, 1919, 1080),
                                     (False, 3840, 479), (True, 3840, 4321),
                                     (False, 32768, 1080), (True, 32768, 1080)):
            with self.subTest(triple=triple, width=width, height=height):
                result, calls = self.invoke(triple, width, height)
                self.assertEqual(result.returncode, 1)
                self.assertIn('Nothing changed', result.stderr)
                self.assertTrue(all(c[0] == 'screens' for c in calls))

    def test_missing_target_does_not_mutate(self):
        for triple in (False, True):
            result, calls = self.invoke(triple, scenario='missing')
            self.assertEqual(result.returncode, 1)
            self.assertEqual(calls, [['screens', '--find', 'XREAL*']])

    def test_mid_setup_changes_leave_previews_hidden(self):
        for triple in (False, True):
            for scenario in ('disconnect', 'resize', 'failure'):
                with self.subTest(triple=triple, scenario=scenario):
                    result, calls = self.invoke(triple, scenario=scenario)
                    self.assertEqual(result.returncode, 7 if scenario == 'failure' else 1)
                    self.assertFalse(any('--show' in c for c in calls))
                    if scenario != 'failure':
                        self.assertIn('rerun', result.stderr.lower())


class GenerateTests(unittest.TestCase):
    def test_writes_bundled_preset_without_overwriting_edits(self):
        with tempfile.TemporaryDirectory(prefix='vs-gen-', dir='/tmp') as directory:
            root = pathlib.Path(directory)
            env = dict(os.environ, VSCREEN_LAYOUT_DIR=str(root / 'layout'), VSCREEN_CONFIG=str(root / 'config.yaml'))
            run = lambda *args: subprocess.run([str(ROOT / 'build' / 'vscreen'), 'generate', *args],
                                               env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(run().stdout, 'xreal-uw\n')
            self.assertEqual(run('--list').stdout, 'xreal-uw\n')
            failed = run('nope')
            self.assertEqual(failed.returncode, 1)
            self.assertIn('Available: xreal-uw', failed.stderr)

            files = {root / kind / source.name: source
                     for kind in ('hooks', 'layout') for source in (PRESET / kind).iterdir()}
            self.assertEqual({path.name for path in files},
                             {'xreal-uw.sh', 'xreal-uw-dual.sh', 'xreal-uw-triple.sh'})
            result = run('xreal-uw')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('vscreen hooks --enable xreal-uw', result.stdout)
            for target, source in files.items():
                self.assertEqual(target.read_bytes(), source.read_bytes())
                self.assertTrue(os.access(target, os.X_OK))
            self.assertTrue((root / 'config.yaml').read_text().startswith('# VScreen config.'))
            self.assertEqual(run('xreal-uw').returncode, 0)

            edited = root / 'layout' / 'xreal-uw-dual.sh'
            edited.write_text('#!/bin/sh\n# edited\n')
            (root / 'hooks' / 'xreal-uw.sh').unlink()
            result = run('xreal-uw')
            self.assertEqual(result.returncode, 1)
            self.assertIn(str(edited), result.stderr)
            self.assertEqual(edited.read_text(), '#!/bin/sh\n# edited\n')
            self.assertFalse((root / 'hooks' / 'xreal-uw.sh').exists())  # A conflict writes nothing.


if __name__ == '__main__':
    unittest.main()
