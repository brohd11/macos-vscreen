# CLI reference

## Named display commands

```sh
vscreen --new UWLeft                   # Existing name: successful no-op
vscreen UWLeft --resolution 1920x1080   # Actual virtual display pixels
vscreen UWLeft --size 1920x1080         # Preview content size in desktop points
vscreen UWLeft --position -1216x-2160   # Preview content top-left
vscreen UWLeft --origin -1216x-1080     # Virtual display top-left in Arrange

vscreen --new UWRight --resolution 1920x1080 --size 1920x1080
vscreen UWRight --position 704x-2160 --origin 704x-1080

vscreen --list                        # Only owned names, one per line
vscreen UWLeft                        # JSON details for this desktop
vscreen --list --json                 # Detailed JSON for all owned desktops
vscreen --screens                     # Read-only JSON list of every macOS display
vscreen UWLeft --close                # Close one tracked desktop
vscreen 35 --close                    # Or use its current macOS display ID
vscreen close                         # Close all tracked desktops; keep app running
vscreen quit                          # Close desktops and stop the resident app
```

Settings may be combined on `--new NAME` or `NAME|ID`. Existing desktops can be targeted by their name or current macOS display ID; only VScreen-owned displays can be updated or closed. **`--new NAME [settings]` creates the desktop if missing, or applies the supplied settings to the existing desktop without replacing its display ID.** Unspecified settings are preserved on existing desktops; a bare `--new NAME` is a no-op when it already exists. You can repeat the same create-and-configure commands to restore a layout.

Names start with a letter or underscore, followed by letters, digits, `_`, `.`, or `-`, up to 64 characters. Whitespace is excluded so plain `--list` output works with shell substitution. `screens`, `close`, and `quit` are reserved subcommands and cannot be used as names.

## Settings

| Setting | Meaning |
| --- | --- |
| `--resolution WxH` | Virtual display resolution; 480–7680 wide, 480–4320 high |
| `--size WxH` | Preview content size; 240–7680 wide, 135–4320 high |
| `--position XxY` | Preview content position in the global desktop coordinate system |
| `--origin XxY` | Virtual display position in macOS's display arrangement |
| `--borderless` / `--titled` | Hide/show title bar and traffic lights |
| `--hide` / `--show` | Hide/show the preview while keeping its display connected. A preview whose screen disconnects hides itself in place; `--show` restores it |
| `--border-color '#RRGGBB'` / `--border-color none` | Optional one-pixel preview edge; default none |
| `--shadow` / `--no-shadow` | Native window shadow; default off |

Defaults: **1920×1080 at 60 Hz**, **960×540 preview**, borderless, no border or shadow, maximum window priority (above the menu bar and Dock). New displays start to the right of existing displays unless `--origin` is supplied. Resolution updates keep the same macOS display ID. Window resizing does not change display resolution.

## Coordinates

Both coordinate options use the **main display's top-left as `0x0`**, with X increasing right and Y increasing down. Negative values put a window or display left of/above the main display. `--position` refers to the preview's content, so adding a title bar does not move its image. `--screens` reports the current display origins and logical sizes in these coordinates.

macOS can adjust the arrangement when displays overlap or have gaps, including moving neighboring physical displays. Use touching, non-overlapping rectangles and check `--screens` after changing origins or resolutions.

## Exit codes and timing

Successful mutations are silent and return 0. Invalid syntax returns 2; runtime errors return 1 with a message on stderr. `NAME|ID --close` tolerates missing/untracked targets and must be used without other settings. `--list`, `close`, and `quit` do not start an absent app. Commands wait for their operation to finish, including display disconnection on close. If communication times out, inspect `--list --json` before retrying because the outcome may be unknown.

## Close and quit

`close` and `--close` are equivalent: both close **all tracked desktops** without quitting the resident app. `quit` and `--quit` are equivalent: both close the desktops and stop the app. The old `--close NAME...` syntax is rejected; replace bulk shell expansion with `vscreen close`, and individual closes with `vscreen NAME --close`.

## Appearance

Appearance settings can be changed without restarting capture:

```sh
vscreen UWLeft --border-color '#3388ff'  # Quote the hex color
vscreen UWLeft --border-color none
vscreen UWLeft --shadow
vscreen UWLeft --no-shadow
```

The colored edge is drawn inside the preview without changing its content size or position. Enabling the native shadow can also restore macOS's thin outline; its color is controlled by macOS. Border color and shadow settings are independent and survive resizing or title-bar toggles. JSON desktop details report `borderColor` and `shadow`.
