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


LEFT, CENTER, RIGHT = 'Xreal-Virtual-Left', 'Xreal-Virtual-Center', 'Xreal-Virtual-Right'
# Expected widths per layout, left to right, for an XREAL of width x height.
LAYOUTS = {
    'xreal-uw-dual-32': lambda w, h: {LEFT: w // 2, RIGHT: w - w // 2},
    'xreal-uw-triple-32': lambda w, h: {LEFT: w // 4, CENTER: w - 2 * (w // 4), RIGHT: w // 4},
    'xreal-uw-dual-21': lambda w, h: {LEFT: h * 16 // 9, RIGHT: w - h * 16 // 9},
}
DUALS = ('xreal-uw-dual-32', 'xreal-uw-dual-21')


class LayoutTests(unittest.TestCase):
    def invoke(self, layout, width=None, height=1080, scenario='normal'):
        width = width or (2560 if layout == 'xreal-uw-dual-21' else 3840)
        with tempfile.TemporaryDirectory(prefix='vs-layout-', dir='/tmp') as directory:
            root = pathlib.Path(directory)
            fake = root / 'vscreen'
            fake.write_text('#!' + sys.executable + '\n' + f'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ['LAYOUT_FIXTURE'])
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(json.dumps(args) + '\\n')
scenario = os.environ['LAYOUT_SCENARIO']
MAIN = {{'solo': '2', 'solo-rerun': '5'}}  # XREAL alone: it is main, or a virtual already is.
ready = (root / 'ready').exists()
if args == ['screens', '--find', 'XREAL*']:
    if scenario == 'missing': sys.exit(1)
    print('2')
elif args == ['screens', '--main']: print(MAIN.get(scenario, '1'))
elif args == ['screens', '1', '--origin']: print('0x0')
elif args == ['screens', '1', '--size']: print('1408x881')
elif args[0] == 'screens' and args[2:] == ['--name']:
    print({{'1': 'Built-in Retina Display', '2': 'XREAL One', '5': '{LEFT}'}}[args[1]])
elif args == ['screens', '2', '--size']:
    if ready and scenario == 'disconnect': sys.exit(1)
    print('1920x1080' if ready and scenario == 'resize' else os.environ['LAYOUT_SIZE'])
elif args == ['screens', '2', '--origin']:
    # Alone, XREAL starts as main at 0x0 (or already below a main virtual on rerun) and ends below the row.
    if scenario in MAIN: print('0x1080' if scenario == 'solo-rerun' or (root / 'main').exists() else '0x0')
    else: print('-1216x-2160' if ready else '1408x-540')
elif len(args) == 2 and args[1] == '--main' and args[0] in ('{LEFT}', '{CENTER}', '{RIGHT}'):
    (root / 'main').touch()
elif args[:2] == ['--new', '{RIGHT}']:
    if scenario == 'failure': sys.exit(7)
    (root / 'ready').touch()
elif args and args[0] in ('--new', '{LEFT}', '{CENTER}', '{RIGHT}'): pass
else: sys.exit(9)
''')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=directory, LAYOUT_FIXTURE=directory,
                       LAYOUT_SCENARIO=scenario, LAYOUT_SIZE=f'{width}x{height}')
            env.pop('VSCREEN_BIN', None)
            result = subprocess.run([str(PRESET / 'layout' / f'{layout}.sh')], env=env,
                                    capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            return result, calls

    def test_resolutions_and_previews_cover_target(self):
        cases = {layout: ((3840, 1080), (1920, 1080), (2560, 1440), (3841, 1081), (1920, 480)) for layout in LAYOUTS}
        cases['xreal-uw-dual-21'] = ((2560, 1080), (2520, 1080), (3440, 1440), (2561, 1081), (3840, 1080))
        for layout, sizes_to_try in cases.items():
            for width, height in sizes_to_try:
                with self.subTest(layout=layout, width=width, height=height):
                    result, calls = self.invoke(layout, width, height)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    sizes = LAYOUTS[layout](width, height)
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
                    self.assertFalse([c for c in calls if '--main' in c and c[0] != 'screens'])
                    # Dual layouts close the triple layout's center before creating anything.
                    closes = [i for i, c in enumerate(calls) if '--close' in c]
                    if layout in DUALS:
                        self.assertEqual([calls[i] for i in closes], [[CENTER, '--close']])
                        self.assertLess(closes[0], min(i for i, c in enumerate(calls) if c[0] == '--new'))
                    else:
                        self.assertEqual(closes, [])

    def test_xreal_alone_promotes_a_virtual_to_main(self):
        primaries = {'xreal-uw-dual-32': LEFT, 'xreal-uw-dual-21': LEFT, 'xreal-uw-triple-32': CENTER}
        for layout, primary in primaries.items():
            # solo: XREAL is main at 0x0. solo-rerun: Left is already main and XREAL sits below it.
            for scenario, xreal_y in (('solo', 0), ('solo-rerun', 1080)):
                with self.subTest(layout=layout, scenario=scenario):
                    result, calls = self.invoke(layout, scenario=scenario)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    width = 2560 if layout == 'xreal-uw-dual-21' else 3840
                    news = [i for i, c in enumerate(calls) if c[0] == '--new']
                    shows = [i for i, c in enumerate(calls) if '--show' in c]
                    mains = [i for i, c in enumerate(calls) if '--main' in c and c[0] != 'screens']
                    self.assertEqual([calls[i] for i in mains], [[primary, '--main']])
                    self.assertLess(max(news), mains[0])
                    self.assertLess(mains[0], min(shows))
                    # After the switch, the rest of the row is put back beside the new main, left to right.
                    sizes = LAYOUTS[layout](width, 1080)
                    primary_x = sum(w for name, w in sizes.items() if name == LEFT and primary == CENTER)
                    x, expected = -primary_x, []
                    for name, w in sizes.items():
                        if name != primary: expected.append([name, '--origin', f'{x}x0'])
                        x += w
                    between = calls[mains[0] + 1:min(shows)]
                    self.assertEqual([c for c in between if c[0] != 'screens'], expected)
                    offset = 0
                    for name, w in LAYOUTS[layout](width, 1080).items():
                        create = next(c for c in calls if c[:2] == ['--new', name])
                        show = next(c for c in calls if c[0] == name and '--show' in c)
                        # The row sits directly above XREAL, not centered on some other main display.
                        self.assertEqual(create[create.index('--origin') + 1], f'{offset}x{xreal_y - 1080}')
                        self.assertEqual(show[show.index('--position') + 1], f'{offset}x1080')
                        offset += w
                    if layout in DUALS:  # Center closes before XREAL's origin is read, as closing it can move XREAL.
                        close = calls.index([CENTER, '--close'])
                        self.assertLess(close, calls.index(['screens', '2', '--origin']))

    def test_invalid_geometry_does_not_mutate(self):
        for layout, width, height in (('xreal-uw-dual-32', 959, 1080), ('xreal-uw-triple-32', 1919, 1080),
                                      ('xreal-uw-dual-32', 3840, 479), ('xreal-uw-triple-32', 3840, 4321),
                                      ('xreal-uw-dual-32', 32768, 1080), ('xreal-uw-triple-32', 32768, 1080),
                                      ('xreal-uw-dual-21', 1920, 1080), ('xreal-uw-dual-21', 2200, 1080),
                                      ('xreal-uw-dual-21', 1600, 1080), ('xreal-uw-dual-21', 32768, 1080)):
            with self.subTest(layout=layout, width=width, height=height):
                result, calls = self.invoke(layout, width, height)
                self.assertEqual(result.returncode, 1)
                self.assertIn('Nothing changed', result.stderr)
                self.assertTrue(all(c[0] == 'screens' for c in calls))

    def test_missing_target_does_not_mutate(self):
        for layout in LAYOUTS:
            result, calls = self.invoke(layout, scenario='missing')
            self.assertEqual(result.returncode, 1)
            self.assertEqual(calls, [['screens', '--find', 'XREAL*']])

    def test_mid_setup_changes_leave_previews_hidden(self):
        for layout in LAYOUTS:
            for scenario in ('disconnect', 'resize', 'failure'):
                with self.subTest(layout=layout, scenario=scenario):
                    result, calls = self.invoke(layout, scenario=scenario)
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
                             {'xreal-uw.sh', 'xreal-uw-dual-32.sh', 'xreal-uw-triple-32.sh', 'xreal-uw-dual-21.sh'})
            result = run('xreal-uw')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('vscreen hooks --enable xreal-uw', result.stdout)
            for target, source in files.items():
                self.assertEqual(target.read_bytes(), source.read_bytes())
                self.assertTrue(os.access(target, os.X_OK))
            self.assertTrue((root / 'config.yaml').read_text().startswith('# VScreen config.'))
            self.assertEqual(run('xreal-uw').returncode, 0)

            edited = root / 'layout' / 'xreal-uw-dual-32.sh'
            edited.write_text('#!/bin/sh\n# edited\n')
            (root / 'hooks' / 'xreal-uw.sh').unlink()
            result = run('xreal-uw')
            self.assertEqual(result.returncode, 1)
            self.assertIn(str(edited), result.stderr)
            self.assertEqual(edited.read_text(), '#!/bin/sh\n# edited\n')
            self.assertFalse((root / 'hooks' / 'xreal-uw.sh').exists())  # A conflict writes nothing.


if __name__ == '__main__':
    unittest.main()
