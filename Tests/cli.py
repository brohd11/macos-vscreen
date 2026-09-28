import json
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
                 ("UWLeft", "--shadow", "--no-shadow")]
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
        for args in [("--new", "UWLeft", "--border-color", "#aAbBcC", "--shadow"),
                     ("123", "--border-color", "none", "--no-shadow"), ("123",)]:
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
            for key in ("name", "origin", "size"):
                query = self.run_cli("screens", display_id, "--" + key)
                expected = display[key] if key == "name" else "x".join(map(str, display[key]))
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


if __name__ == "__main__":
    unittest.main()
