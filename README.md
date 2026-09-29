# VScreen

Named macOS virtual displays with floating live previews. Arrange the displays and move across their shared screen edges normally. Previews do not capture, confine, warp, or forward mouse/keyboard input. Their default window level is above the menu bar and Dock.

## Install

Requires macOS 14+. No third-party runtime dependencies.

```sh
curl -fsSL https://raw.githubusercontent.com/brohd11/macos-vscreen/main/install.sh | sh
```

Installs the latest release as **`/Applications/VScreen.app`** plus a small forwarding shell script at **`~/.local/bin/vscreen`**. If that directory is on PATH, no alias or shell-profile edits are needed. Rerun the same command to update. To build from source instead (`make && make install`), see [Building](docs/building.md).

Grant Screen Recording:

```sh
vscreen --request-permissions
```

Enable **VScreen** under **System Settings → Privacy & Security → Screen & System Audio Recording**, then run `vscreen quit` before creating a desktop. Rebuilding can invalidate the grant; see [Permissions](docs/permissions.md).

## Quick start

```sh
vscreen --new Desktop1 --resolution 1920x1080 --size 960x540   # Create a display and its preview
vscreen --list                                                 # Names of owned displays
vscreen Desktop1 --close                                       # Remove it
```

## Documentation

- [Building](docs/building.md) — build targets and signing identity
- [Permissions](docs/permissions.md) — Screen Recording and rebuild recovery
- [CLI reference](docs/cli.md) — all commands, settings, coordinates, exit codes
- [Screen queries](docs/screen-queries.md) — read-only display lookups for scripts
- [Auto-connect](docs/auto-connect.md) — start at login and run layouts on display changes
- [XREAL layouts](docs/xreal-layouts.md) — 32:9 and 21:9 layouts and the `xreal-uw` preset
- [Window controls](docs/window-controls.md) — shortcuts and app lifecycle
- [Development](docs/development.md) — architecture and tests
