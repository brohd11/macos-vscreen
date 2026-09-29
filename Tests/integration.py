"""Opt-in GUI-session test: real displays and windows, no screen recording."""
import concurrent.futures
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time

BIN = pathlib.Path(__file__).resolve().parents[1] / "build/vscreen"


def run(*args, env=None, ok=True):
    result = subprocess.run([str(BIN), *args], env=env, capture_output=True, text=True, timeout=40)
    if ok:
        assert result.returncode == 0, (args, result.returncode, result.stderr)
    return result


def screens():
    return {item["id"]: item for item in json.loads(run("--screens").stdout)}


def wait_for(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for expected state")


def host_ready(directory, pid):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(1)
            peer.connect(directory + "/control.sock")
            peer.sendall(b'{"arguments":["--check"]}\n')
            reply = json.loads(peer.makefile("rb").readline())
            return json.loads(reply["output"])["pid"] == pid
    except (OSError, ValueError, KeyError):
        return False


before = screens()
assert before, "Requires a logged-in GUI session outside the sandbox"
with tempfile.TemporaryDirectory(prefix="vs-integration-", dir="/tmp") as directory:
    env = dict(os.environ, VSCREEN_RUNTIME_DIR=directory)
    log_path = pathlib.Path(directory) / "host.log"
    # Display-change hooks must ignore VScreen's own displays, or layout scripts would retrigger themselves.
    hook_dir, hook_marker = pathlib.Path(directory) / "layout", pathlib.Path(directory) / "hook-fired"
    hook_dir.mkdir()
    (hook_dir / "record.sh").write_text(f'#!/bin/sh\necho "$VSCREEN_EVENT" >> "{hook_marker}"\n')
    (hook_dir / "record.sh").chmod(0o755)
    (pathlib.Path(directory) / "config.json").write_text('{"onDisplayChange": ["record"]}')
    hook_env = dict(os.environ, VSCREEN_CONFIG=directory + "/config.json", VSCREEN_LAYOUT_DIR=str(hook_dir))
    with log_path.open("w+") as log:
        host = subprocess.Popen([str(BIN), "--serve-test", directory], stdout=log, stderr=log, env=hook_env)
        try:
            wait_for(lambda: (pathlib.Path(directory) / "control.sock").exists())
            assert run("--list", env=env).stdout == ""
            assert json.loads(run("--check", env=env).stdout)["testMode"] is True
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
                peer.connect(directory + "/control.sock")
                peer.sendall(b'{"arguments":[null]}\n')
                assert json.loads(peer.makefile("rb").readline())["ok"] is False
            right = max(item["origin"][0] + item["size"][0] for item in before.values())
            run("--new", "UWLeft", "--resolution", "800x600", "--size", "320x240", env=env)
            left = json.loads(run("UWLeft", env=env).stdout)
            assert left["resolution"] == [800, 600]
            assert left["borderless"] is True
            assert left["borderColor"] == "none" and left["shadow"] is False and left["hiPerf"] is False
            assert left["windowLevel"] > 1000
            run("--new", "UWLeft", env=env)
            assert json.loads(run("UWLeft", env=env).stdout) == left
            run("--new", "UWRight", "--resolution", "480x1080", "--size", "320x240",
                "--border-color", "#00Aa88", "--shadow", "--hi-perf", env=env)
            right_info = json.loads(run("UWRight", env=env).stdout)
            assert right_info["resolution"] == [480, 1080], right_info
            assert right_info["borderColor"] == "#00aa88" and right_info["shadow"] is True
            assert right_info["hiPerf"] is True
            run("UWRight", "--titled", env=env)
            assert json.loads(run("UWRight", env=env).stdout)["hiPerf"] is True, "Omitted hi-perf changed"
            run("UWRight", "--borderless", "--no-hi-perf", env=env)
            assert json.loads(run("UWRight", env=env).stdout) == dict(right_info, hiPerf=False)
            right_id = right_info["id"]
            assert run("--list", env=env).stdout == "UWLeft\nUWRight\n"
            configure_left = ("--new", "UWLeft", "--resolution", "480x1080", "--size", "400x300",
                              "--position", "-30x-20", "--origin", f"{right}x-100", "--titled",
                              "--border-color", "#123456", "--shadow")
            run(*configure_left, env=env)
            updated = json.loads(run("UWLeft", env=env).stdout)
            assert updated["id"] == left["id"], "Resolution update replaced the display"
            assert updated["resolution"] == [480, 1080], updated
            assert updated["size"] == [400, 300], updated
            assert updated["position"] == [-30, -20], updated
            assert updated["origin"] == [right, -100], updated
            assert updated["borderless"] is False
            assert updated["borderColor"] == "#123456" and updated["shadow"] is True
            run(*configure_left, env=env)
            assert json.loads(run("UWLeft", env=env).stdout) == updated
            assert right_id in screens()
            run("--new", "UWLeft", "--hide", env=env)
            hidden = json.loads(run("UWLeft", env=env).stdout)
            assert hidden == dict(updated, visible=False), "Unspecified settings changed"
            run("--new", "UWLeft", env=env)
            assert json.loads(run("UWLeft", env=env).stdout) == hidden
            assert left["id"] in screens()
            run("UWLeft", "--show", "--borderless", env=env)
            borderless = json.loads(run("UWLeft", env=env).stdout)
            assert borderless["position"] == [-30, -20] and borderless["shadow"] is True
            run(str(left["id"]), "--border-color", "none", "--no-shadow", env=env)
            unframed = json.loads(run(str(left["id"]), env=env).stdout)
            assert unframed == dict(borderless, borderColor="none", shadow=False)
            snapshot = run("UWLeft", env=env).stdout
            invalid = run("--new", "UWLeft", "--position", "5x5", "--size", "1x1", env=env, ok=False)
            assert invalid.returncode == 2 and run("UWLeft", env=env).stdout == snapshot
            for unowned_id in before:
                run(str(unowned_id), "--close", env=env)
            assert run("--list", env=env).stdout == "UWLeft\nUWRight\n"
            run("UWLeft", "--close", env=env)
            run("UWLeft", "--close", env=env)  # Missing target remains a safe no-op.
            assert left["id"] not in screens() and right_id in screens()
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                list(pool.map(lambda _: run("--new", "Race", "--resolution", "800x600", "--hide", env=env), range(3)))
            assert run("--list", env=env).stdout == "Race\nUWRight\n"
            old_syntax = subprocess.run('"$VSCREEN_BIN" --close $("$VSCREEN_BIN" --list)', shell=True,
                                    env=dict(env, VSCREEN_BIN=str(BIN)), capture_output=True, text=True, timeout=40)
            assert old_syntax.returncode == 2 and run("--list", env=env).stdout == "Race\nUWRight\n"
            race_id = json.loads(run("Race", env=env).stdout)["id"]
            run(str(race_id), "--close", env=env)
            assert race_id not in screens() and run("--list", env=env).stdout == "UWRight\n"
            # A preview whose screen disconnects hides in place instead of being moved by macOS.
            run("--new", "Host", "--resolution", "800x600", "--hide", env=env)
            host_origin = json.loads(run("Host", env=env).stdout)["origin"]
            guest_position = [host_origin[0] + 100, host_origin[1] + 100]
            run("--new", "Guest", "--resolution", "800x600", "--size", "240x135",
                "--position", f"{guest_position[0]}x{guest_position[1]}", env=env)
            guest = json.loads(run("Guest", env=env).stdout)
            assert guest["visible"] is True and guest["position"] == guest_position, guest
            run("Host", "--close", env=env)
            wait_for(lambda: not json.loads(run("Guest", env=env).stdout)["visible"])
            assert json.loads(run("Guest", env=env).stdout)["position"] == guest_position
            run("Guest", "--show", env=env)
            shown = json.loads(run("Guest", env=env).stdout)
            assert shown["visible"] is True and shown["position"] == guest_position, shown
            run("Guest", "--close", env=env)
            run("--new", "Race", "--resolution", "800x600", "--hide", env=env)
            run("close", env=env)
            assert run("--list", env=env).stdout == ""
            wait_for(lambda: screens() == before)
            assert json.loads(run("--check", env=env).stdout)["pid"] == host.pid
            run("--new", "AfterClose", "--resolution", "800x600", "--hide", env=env)
            run("--close", env=env)
            assert run("--list", env=env).stdout == "" and host.poll() is None
            time.sleep(2)  # Longer than the hook debounce.
            assert not hook_marker.exists(), "Owned display changes fired hooks: " + hook_marker.read_text()
            run("--new", "QuitTest", "--resolution", "800x600", "--hide", env=env)
            run("quit", env=env)
            assert host.wait(timeout=10) == 0
            wait_for(lambda: screens() == before)
            assert run("--close", env=env).returncode == 0
            # Abrupt parent death closes the helper's lifetime pipe. Restart can reclaim the stale socket.
            host = subprocess.Popen([str(BIN), "--serve-test", directory], stdout=log, stderr=log)
            wait_for(lambda: (pathlib.Path(directory) / "control.sock").exists())
            run("--new", "CrashTest", "--resolution", "800x600", "--hide", env=env)
            host.kill()
            host.wait(timeout=5)
            wait_for(lambda: screens() == before)
            host = subprocess.Popen([str(BIN), "--serve-test", directory], stdout=log, stderr=log)
            wait_for(lambda: host_ready(directory, host.pid))
            run("--quit", env=env)
            assert host.wait(timeout=10) == 0
            print("Integration passed: named/ID targeting, border/shadow settings, lifecycle, displaced-preview hiding, resolution, geometry, concurrency, close-all/quit aliases, hooks ignore owned displays, existing display preservation.")
        finally:
            if host.poll() is None:
                host.terminate()
                try:
                    host.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
            log.seek(0)
            print(log.read(), end="")
