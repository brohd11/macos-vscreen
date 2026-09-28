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
```

`--find` matches a case-sensitive shell glob against the display name; quote the pattern so your shell does not expand it. A missing match or disconnected ID returns 1, writes an error to stderr, and leaves stdout empty. IDs can change on reconnection, so look them up each time.

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

See [XREAL layouts](xreal-layouts.md) for complete scripts built on these queries.
