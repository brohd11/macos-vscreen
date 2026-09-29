# Development

Use `build/vscreen` before installing. It is the same executable inside the app bundle. See [Building](building.md) for build targets.

## Architecture

The bundled executable is the CLI client. It starts one resident app through LaunchServices on demand and talks to it over a private per-user Unix socket, with serialized requests and replies. A short-lived helper owns each virtual display so parent exit also disconnects it. There's no third-party dependency or saved display state. The optional Login Item is the same app, registered with `SMAppService.mainAppService`. When launched with no arguments by launchd (at login or from Finder), it serves the default runtime directory and runs the [hooks](auto-connect.md) once. Hooks run as child processes, never inside a socket request, because they call `vscreen` themselves.

`VSCREEN_RUNTIME_DIR` selects a separate private runtime directory for tests. `VSCREEN_CONFIG` and `VSCREEN_LAYOUT_DIR` redirect hooks and layouts. In `--serve-test` mode, hooks run only when `VSCREEN_CONFIG` is set.

## Tests

```sh
make test          # Argument validation and client/socket response tests
make integration   # Temporary real displays/windows; no screen recording
vscreen --check    # Permission and API status from the resident app's context
```

`make test` needs local Unix socket access. The integration test requires a logged-in GUI session outside restricted sandboxes. It verifies idempotent creation, in-place resolution changes, signed coordinates, preview sizing, hiding, concurrent requests, shell bulk-close, parent-death cleanup, and preservation of pre-existing displays.

## Platform caveats

Virtual display creation uses Apple's private `CGVirtualDisplay` API, also used by [Chromium's display tests](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm). macOS updates can break it. Maximum window level applies within the normal desktop session, not protected login/lock screens. See Apple's [window-level documentation](https://developer.apple.com/documentation/coregraphics/cgwindowlevel).
