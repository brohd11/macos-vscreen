"""Exercise layout scripts without touching the user's displays."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


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
            result = subprocess.run([str(ROOT / 'examples' / filename)], env=env,
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


class GenerateExampleTests(unittest.TestCase):
    def test_writes_embedded_copy_without_overwriting_edits(self):
        with tempfile.TemporaryDirectory(prefix='vs-gen-', dir='/tmp') as directory:
            layouts = pathlib.Path(directory) / 'layout'
            env = dict(os.environ, VSCREEN_LAYOUT_DIR=str(layouts))
            run = lambda: subprocess.run([str(ROOT / 'build' / 'vscreen'), '--generate-example'],
                                         env=env, capture_output=True, text=True, timeout=10)
            target = layouts / 'xreal-uw-dual.sh'
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_bytes(), (ROOT / 'examples' / 'xreal-uw-dual.sh').read_bytes())
            self.assertTrue(os.access(target, os.X_OK))
            self.assertEqual(run().returncode, 0)
            target.write_text('#!/bin/sh\n# edited\n')
            result = run()
            self.assertEqual(result.returncode, 1)
            self.assertIn('differs', result.stderr)
            self.assertEqual(target.read_text(), '#!/bin/sh\n# edited\n')


if __name__ == '__main__':
    unittest.main()
