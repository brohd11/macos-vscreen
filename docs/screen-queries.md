# Screen queries

These read-only commands run without starting the resident app or requiring Screen Recording permission:

```sh
vscreen screens                    # All displays as JSON; equivalent to --screens
vscreen screens --list             # ID<TAB>name, one display per line
vscreen screens --find 'XREAL*'    # First matching ID, by ascending numeric ID
vscreen screens --main             # Main display ID
vscreen screens 2                  # One display as JSON
vscreen screens 2 --name           # Name only
vscreen screens 2 --origin         # XxY, including negative coordinates
vscreen screens 2 --size           # WxH in logical desktop points
vscreen screens 2 --aspect         # Reduced W:H of the logical size, e.g. 32:9
```

`--find` matches a case-sensitive shell glob against the display name; quote the pattern so your shell does not expand it. A missing match or disconnected ID returns 1, writes an error to stderr, and leaves stdout empty. IDs can change on reconnection, so look them up each time.

`--aspect` is the exact ratio of `--size` in lowest terms (also `aspect` in the JSON). macOS reports no aspect ratio of its own. Common names don't always match: 3840×1080 is `32:9` and 1920×1080 is `16:9`, but 2560×1600 is `8:5`, not 16:10, and 3440×1440 is `43:18`, not 21:9. Compare against the exact value your display reports.

Coordinates and sizes use the system described in [CLI reference → Coordinates](cli.md#coordinates).

## Scripting example

```sh
if ! XR=$(vscreen screens --find 'XREAL*'); then
    echo 'No XREAL display found.' >&2
    exit 1
fi
ORIG=$(vscreen screens "$XR" --origin)
SIZE=$(vscreen screens "$XR" --size)
```

See [XREAL layouts](xreal-layouts.md) for complete scripts built on these queries, and [Auto-connect](auto-connect.md) for running them when a display connects or changes mode.
