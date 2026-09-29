import json
import math
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import unittest

BIN = pathlib.Path(__file__).resolve().parents[1] / "build/vscreen"


class CLITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="vs-cli-", dir="/tmp")
        self.env = dict(os.environ, VSCREEN_RUNTIME_DIR=self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def run_cli(self, *args):
        return subprocess.run([str(BIN), *args], env=self.env, capture_output=True, text=True, timeout=10)

    def test_help(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--origin", result.stdout)
        self.assertNotIn("Accessibility", result.stdout)

    def test_invalid_arguments_fail_before_launch(self):
        cases = [("--new",), ("--new", "has spaces"), ("--new", "--quit"),
                 ("--new", "9starts-with-digit"), ("--new", "../escape"),
                 ("UWLeft", "--resolution", "1920x1080junk"), ("UWLeft", "--resolution", "640x0"),
                 ("UWLeft", "--resolution", "479x1080"), ("UWLeft", "--resolution", "480x479"),
                 ("UWLeft", "--size", "10x10"), ("UWLeft", "--position", "0xnan"),
                 ("UWLeft", "--origin", "999999999999999999999x0"),
                 ("UWLeft", "--size"), ("UWLeft", "--titled", "--borderless"),
                 ("UWLeft", "--position", "0x0", "--position", "1x1"),
                 ("--close", "Good", "bad name"), ("--list", "--close"), ("--unknown",),
                 ("screens", "--find"), ("screens", "--find", ""), ("screens", "--main", "extra"),
                 ("screens", "--list", "--json"), ("screens", "0", "--origin"),
                 ("screens", "-1"), ("screens", "4294967296"), ("screens", "1junk"),
                 ("screens", "1", "--size", "1920x1080"), ("screens", "1", "--unknown"),
                 ("--new", "screens"), ("--new", "close"), ("--new", "quit"),
                 ("--close", "UWLeft"), ("close", "UWLeft"), ("quit", "UWLeft"),
                 ("UWLeft", "--close", "--hide"), ("--new", "UWLeft", "--close"),
                 ("0", "--close"), ("4294967296", "--close"),
                 ("UWLeft", "--border-color"), ("UWLeft", "--border-color", "red"),
                 ("UWLeft", "--border-color", "#123"), ("UWLeft", "--border-color", "#gg0000"),
                 ("UWLeft", "--border-color", "none", "--border-color", "#123456"),
                 ("UWLeft", "--shadow", "--no-shadow"), ("UWLeft", "--hi-perf", "--no-hi-perf"),
                 ("layout", "../escape"), ("layout", ""), ("--layout", "a/b"),
                 ("layout", "--list", "extra"), ("--new", "layout"),
                 ("screens", "1", "--aspect", "extra"), ("login", "--bogus"), ("login", "--enable", "extra"),
                 ("hooks", "--bogus"), ("hooks", "--run", "extra"), ("--new", "login"), ("--new", "hooks")]
        for args in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_no_server_read_and_close_are_safe(self):
        for args in [("--list",), ("close",), ("--close",), ("UWLeft", "--close"),
                     ("123", "--close"), ("quit",), ("--quit",)]:
            result = self.run_cli(*args)
            self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)
        self.assertEqual(json.loads(self.run_cli("--list", "--json").stdout), [])
        self.assertEqual(self.run_cli("UWLeft", "--size", "800x600").returncode, 1)

    def exchange(self, args, response):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.directory.name + "/control.sock")
        server.listen(1)
        received = []

        def handle():
            connection, _ = server.accept()
            with connection, connection.makefile("rb") as stream:
                received.append(json.loads(stream.readline()))
                connection.sendall(json.dumps(response).encode() + b"\n")

        thread = threading.Thread(target=handle, daemon=True)
        thread.start()
        result = self.run_cli(*args)
        thread.join(timeout=5)
        server.close()
        (pathlib.Path(self.directory.name) / "control.sock").unlink()
        self.assertFalse(thread.is_alive())
        self.assertEqual(received, [{"arguments": list(args)}])
        return result

    def test_signed_coordinates_and_combined_settings(self):
        args = ("--new", "UWLeft", "--resolution", "1920x1080", "--size", "960x540",
                "--position", "-1216x-2160", "--origin", "-1216x-1080", "--borderless")
        result = self.exchange(args, {"ok": True, "output": ""})
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_errors_reach_shell(self):
        result = self.exchange(("UWLeft", "--size", "800x600"), {"ok": False, "error": "No such display"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("No such display", result.stderr)

    def test_narrow_resolution_is_forwarded(self):
        result = self.exchange(("--new", "Narrow", "--resolution", "480x1080"), {"ok": True, "output": ""})
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_close_forms_reach_running_app(self):
        for args in [("close",), ("--close",), ("UWLeft", "--close"), ("123", "--close")]:
            with self.subTest(args=args):
                result = self.exchange(args, {"ok": True, "output": ""})
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_appearance_options_and_numeric_target(self):
        for args in [("--new", "UWLeft", "--border-color", "#aAbBcC", "--shadow", "--hi-perf"),
                     ("123", "--border-color", "none", "--no-shadow", "--no-hi-perf"), ("123",)]:
            with self.subTest(args=args):
                result = self.exchange(args, {"ok": True, "output": ""})
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_system_screen_queries_without_resident_app(self):
        result = self.run_cli("screens")
        self.assertEqual(result.returncode, 0, result.stderr)
        displays = json.loads(result.stdout)
        self.assertEqual(json.loads(self.run_cli("--screens").stdout), displays)
        ordered = sorted(displays, key=lambda display: display["id"])
        self.assertEqual(self.run_cli("screens", "--list").stdout,
                         "".join(f"{d['id']}\t{d['name']}\n" for d in ordered))
        for display in displays:
            display_id = str(display["id"])
            self.assertEqual(json.loads(self.run_cli("screens", display_id).stdout), display)
            width, height = map(round, display["size"])
            divisor = math.gcd(width, height)
            self.assertEqual(display["aspect"], f"{width // divisor}:{height // divisor}")
            for key in ("name", "origin", "size", "aspect"):
                query = self.run_cli("screens", display_id, "--" + key)
                expected = display[key] if key in ("name", "aspect") else "x".join(map(str, display[key]))
                self.assertEqual((query.returncode, query.stdout), (0, expected + "\n"), query.stderr)
        if displays:
            self.assertEqual(self.run_cli("screens", "--find", "*").stdout, f"{ordered[0]['id']}\n")
            main = next(d for d in displays if d["main"])
            self.assertEqual(self.run_cli("screens", "--main").stdout, f"{main['id']}\n")
        missing = self.run_cli("screens", "--find", "VScreenMissingTest-*")
        self.assertEqual((missing.returncode, missing.stdout), (1, ""))
        self.assertTrue(missing.stderr)
        absent_id = next(n for n in range(1, len(displays) + 2) if n not in {d["id"] for d in displays})
        absent = self.run_cli("screens", str(absent_id), "--origin")
        self.assertEqual((absent.returncode, absent.stdout), (1, ""))
        self.assertFalse((pathlib.Path(self.directory.name) / "control.sock").exists())

    def test_layout_scripts_run_without_resident_app(self):
        layouts = pathlib.Path(self.directory.name) / "layouts"
        self.env["VSCREEN_LAYOUT_DIR"] = str(layouts)
        self.env.pop("VSCREEN_BIN", None)
        self.assertEqual((self.run_cli("layout").returncode, self.run_cli("layout").stdout), (0, ""))

        layouts.mkdir()
        log = layouts / "log"
        (layouts / "plain").write_text(f'#!/bin/sh\nprintf "%s\\n" "$VSCREEN_BIN" "$@" > "{log}"\nexit 7\n')
        (layouts / "dual.sh").write_text("#!/bin/sh\necho dual\n")
        (layouts / "notexec.sh").write_text("#!/bin/sh\n")
        (layouts / ".hidden").write_text("#!/bin/sh\n")
        (layouts / "folder").mkdir()
        for name in ("plain", "dual.sh", ".hidden"):
            (layouts / name).chmod(0o755)

        for args in [("layout",), ("layout", "--list"), ("--layout", "--list")]:
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).stdout, "dual\nplain\n")

        result = self.run_cli("layout", "plain", "--flag", "two words")
        self.assertEqual(result.returncode, 7, result.stderr)
        bin_path, *forwarded = log.read_text().splitlines()
        self.assertEqual(os.path.realpath(bin_path), os.path.realpath(BIN))
        self.assertEqual(forwarded, ["--flag", "two words"])

        self.env["VSCREEN_BIN"] = "/custom/vscreen"
        self.run_cli("--layout", "plain")
        self.assertEqual(log.read_text().splitlines(), ["/custom/vscreen"])

        self.assertEqual(self.run_cli("layout", "dual").stdout, "dual\n")
        for name, message in [("missing", "No layout"), ("notexec", "chmod +x"), ("folder", "No layout")]:
            with self.subTest(name=name):
                failed = self.run_cli("layout", name)
                self.assertEqual((failed.returncode, failed.stdout), (1, ""))
                self.assertIn(message, failed.stderr)
        self.assertFalse((pathlib.Path(self.directory.name) / "control.sock").exists())

    def test_login_reaches_running_app(self):
        for args in [("login",), ("login", "--enable"), ("login", "--disable")]:
            with self.subTest(args=args):
                result = self.exchange(args, {"ok": True, "output": "disabled"})
                self.assertEqual((result.returncode, result.stdout), (0, "disabled\n"), result.stderr)

    def test_hooks_run_in_client_without_resident_app(self):
        root = pathlib.Path(self.directory.name)
        hooks, config, log = root / "hooks", root / "config.yaml", root / "hook-log"
        self.env.update(VSCREEN_LAYOUT_DIR=str(root / "layouts"), VSCREEN_CONFIG=str(config))
        self.env.pop("VSCREEN_BIN", None)
        self.assertEqual(self.run_cli("hooks").returncode, 0)  # A missing config means no hooks.
        self.assertEqual((self.run_cli("hooks", "--run").returncode, self.run_cli("hooks", "--run").stdout), (0, ""))

        hooks.mkdir()
        (hooks / "record.sh").write_text(
            f'#!/bin/sh\nprintf "%s|%s|%s\\n" "$VSCREEN_EVENT" "$VSCREEN_BIN" "$*" >> "{log}"\n')
        (hooks / "broken").write_text("#!/bin/sh\nexit 4\n")
        for name in ("record.sh", "broken"):
            (hooks / name).chmod(0o755)
        config.write_text('onDisplayChange:  # comment\n  - [record, "two words"]\n  - broken\n  - - missing\n  - record\n')
        self.assertEqual(self.run_cli("hooks").stdout, "record two words\nbroken\nmissing\nrecord\n")

        result = self.run_cli("hooks", "--run")
        self.assertEqual(result.returncode, 1)
        self.assertIn("broken exited with status 4", result.stderr)
        self.assertIn("No hook missing", result.stderr)
        lines = [line.split("|") for line in log.read_text().splitlines()]
        self.assertEqual([(event, args) for event, _, args in lines], [("manual", "two words"), ("manual", "")])
        self.assertEqual(os.path.realpath(lines[0][1]), os.path.realpath(BIN))

        for text in ("[unclosed", "- record", "onDisplayChange: record", "onDisplayChange: [{a: b}]",
                     "onDisplayChange: [[]]", "onDisplayChange: [../escape]"):
            with self.subTest(config=text):
                config.write_text(text)
                for args in (("hooks",), ("hooks", "--run")):
                    failed = self.run_cli(*args)
                    self.assertEqual((failed.returncode, failed.stdout), (1, ""))
                    self.assertIn("Invalid", failed.stderr)
        for text in ("", "# nothing\n", "onDisplayChange:\n#  - record\n"):
            with self.subTest(config=text):
                config.write_text(text)
                self.assertEqual((self.run_cli("hooks").returncode, self.run_cli("hooks").stdout), (0, ""))
        self.assertFalse((root / "control.sock").exists())

    def test_hooks_enable_and_disable_edit_config(self):
        root = pathlib.Path(self.directory.name)
        hooks, config = root / "vs" / "hooks", root / "vs" / "config.yaml"
        self.env.update(VSCREEN_LAYOUT_DIR=str(root / "vs" / "layout"), VSCREEN_CONFIG=str(config))
        failed = self.run_cli("hooks", "--enable", "record")
        self.assertEqual(failed.returncode, 1)
        self.assertIn("No hook record", failed.stderr)
        self.assertFalse(config.exists())

        hooks.mkdir(parents=True)
        for name in ("record.sh", "other"):
            (hooks / name).write_text("#!/bin/sh\n")
            (hooks / name).chmod(0o755)
        self.assertEqual(self.run_cli("hooks", "--enable", "record").returncode, 0)  # Creates the starter config.
        self.assertTrue(config.read_text().startswith("# VScreen config."))
        self.assertTrue((root / "vs" / "layout").is_dir())
        self.assertEqual(self.run_cli("hooks").stdout, "record\n")

        config.write_text("# keep\nonDisplayChange:  # hooks\n  - [other, arg]  # note\n  # - old\nlater: 1\n")
        self.assertEqual(self.run_cli("hooks", "--list").stdout, "other\tenabled\nrecord\tdisabled\n")
        for _ in range(2):  # Enabling twice is a no-op.
            self.assertEqual(self.run_cli("hooks", "--enable", "record").returncode, 0)
        self.assertEqual(config.read_text(),
                         "# keep\nonDisplayChange:  # hooks\n  - [other, arg]  # note\n  - record\n  # - old\nlater: 1\n")
        self.assertEqual(self.run_cli("hooks").stdout, "other arg\nrecord\n")
        for _ in range(2):
            self.assertEqual(self.run_cli("hooks", "--disable", "other").returncode, 0)
        self.assertEqual(config.read_text(), "# keep\nonDisplayChange:  # hooks\n  - record\n  # - old\nlater: 1\n")
        (hooks / "record.sh").unlink()
        self.assertEqual(self.run_cli("hooks", "--list").stdout, "other\tdisabled\nrecord\tmissing\n")

        config.write_text("onDisplayChange: []\n")
        self.assertEqual(self.run_cli("hooks", "--enable", "other").returncode, 0)
        self.assertEqual(config.read_text(), "onDisplayChange:\n  - other\n")
        for text, args in (("onDisplayChange: [other]\n", ("--disable", "other")),
                           ("onDisplayChange:\n  - - other\n", ("--disable", "other")),
                           ("onDisplayChange: [record]\n", ("--enable", "other"))):
            with self.subTest(config=text, args=args):
                config.write_text(text)
                failed = self.run_cli("hooks", *args)
                self.assertEqual(failed.returncode, 1)
                self.assertIn("by hand", failed.stderr)
                self.assertEqual(config.read_text(), text)
        for args in (("--enable",), ("--enable", "../x"), ("--disable", "a", "b")):
            self.assertEqual(self.run_cli("hooks", *args).returncode, 2)


if __name__ == "__main__":
    unittest.main()
