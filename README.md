# VScreen

Create virtual displays in macOS with live previews in windows. They are seen as actual displays, so you can arrange them in System Settings > Displays > Arrange. You can move the previews with mouse or via CLI. The preview windows themselves don't forward mouse movement currently.

The CLI has commands to read current screen sizes and size previews dynamically in simple shell scripts. There is a hook on display changed that can be used to re-organize or close displays as needed.

This app was made because I needed to split my Xreal glasses ultrawide desktop into multiple monitors. The glasses are a bit quirky with ultrawide mode and switching between them. see the XREAL Layouts and Auto-connect sections of documentation for examples of using a hook script and layouts to swap between display layouts automatically.

## Install

Requires macOS 14+.

```sh
curl -fsSL https://raw.githubusercontent.com/brohd11/macos-vscreen/main/install.sh | sh
```

Installs the latest release to **`/Applications/VScreen.app`** plus a forwarding shell script at **`~/.local/bin/vscreen`** for CLI use. If that directory is on PATH, no alias or shell-profile edits are needed. Rerun the same command to update. To build from source instead (`make && make install`), see [Building](docs/building.md).

The app needs Screen Recording permission to function:

```sh
vscreen --request-permissions
```

Enable **VScreen** under **System Settings → Privacy & Security → Screen & System Audio Recording**.

## Quick start

```sh
vscreen --new Desktop1 --resolution 1920x1080 --size 960x540   # Create a display and its preview
vscreen --list                                                 # Names of owned displays
vscreen Desktop1 --close                                       # Remove it
```

### XREAL Glasses

[Install+Setup Video Walkthrough](https://youtu.be/Gno6D7LTkmU)

XREAL use can be set up with these commands after setting up permissions. See the documentation for more info.
```sh
vscreen generate xreal-uw
vscreen hooks --enable xreal-uw
vscreen login --enable
vscreen quit
open /Application/VScreen.app
```

## Known Issues
- macOS screen capture causes spotlight search and the apps menu to have an opaque black background. This is on the macOS screen capture level, not this app.

## Documentation

- [Building](docs/building.md) — build targets and signing identity
- [Permissions](docs/permissions.md) — Screen Recording and rebuild recovery
- [CLI reference](docs/cli.md) — all commands, settings, coordinates, exit codes
- [Screen queries](docs/screen-queries.md) — display lookups for scripts, and switching a display's mode
- [Auto-connect](docs/auto-connect.md) — start at login and run layouts on display changes
- [XREAL layouts](docs/xreal-layouts.md) — 32:9 and 21:9 layouts and the `xreal-uw` preset
- [Window controls](docs/window-controls.md) — shortcuts and app lifecycle
- [Development](docs/development.md) — architecture and tests
