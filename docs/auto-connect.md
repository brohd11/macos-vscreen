# Auto-connect

VScreen can start at login and run your [layout scripts](cli.md#layouts) whenever a display is connected, disconnected, or changes mode. It doesn't track any display state itself. Each script checks the current displays and decides whether to act, so a hook runs often and usually does nothing.

## Setup

```sh
vscreen login --enable     # Start VScreen.app at login (a normal macOS Login Item)
vscreen login              # Status: enabled, disabled, or requires-approval
vscreen login --disable
```

If the status is `requires-approval`, VScreen opens **System Settings → General → Login Items** so you can allow it. Register the installed `/Applications/VScreen.app`, not a build copy: the Login Item points at the bundle that registered it.

Then list the hooks in `~/.vscreen/config.json` (override the path with `VSCREEN_CONFIG`):

```json
{ "onDisplayChange": ["xreal-auto", ["other-layout", "arg1"]] }
```

Each entry is a layout name, resolved like `vscreen layout NAME`, or an array of `[name, args...]`. Hooks run one at a time, in order. A failing hook doesn't stop the rest. The file is reread on every run, so edits apply without restarting.

## When hooks run

- **At login.** They run once when macOS starts VScreen as a Login Item (or you open the app from Finder), so displays that were already connected get set up. `VSCREEN_EVENT=launch`.
- **On display changes.** They run when a display that VScreen doesn't own is added, removed, enabled, disabled, or changes mode. Turning on XREAL's ultrawide mode is a mode change. `VSCREEN_EVENT=display-change`.

A connection arrives as a burst of changes, so hooks run 1.5 s after the last one. Changes that arrive while hooks are running trigger one more run after they finish. VScreen ignores its own virtual displays and displays that only moved, so a hook that creates or arranges displays doesn't retrigger itself.

When the app starts on demand (e.g. from `vscreen --new`), hooks don't run until the next display change. `vscreen quit` stops the app and its hooks until the next login.

Hooks start in your home directory, with `VSCREEN_BIN` set to the app's `vscreen` binary. Their stdout and stderr go to `hooks.log` next to the config (`~/.vscreen/hooks.log`), with a timestamped line for each start and exit status. The log is cleared once it passes 256 KB.

## Testing a hook

```sh
vscreen hooks          # Configured hooks, one per line; exits 1 if the config is invalid
vscreen hooks --run    # Run them now in this terminal (VSCREEN_EVENT=manual); exits 1 if any fail
```

`hooks --run` doesn't need the app and prints output directly, so you can test a script without reconnecting anything.

## XREAL example

XREAL glasses connect in 16:9 mode. This hook applies the [dual layout](xreal-layouts.md) only once they're switched to 32:9 ultrawide. Save it as `~/.vscreen/layout/xreal-auto.sh`, make it executable, run `vscreen --generate-example` for `xreal-uw-dual`, and add `"xreal-auto"` to `onDisplayChange`:

```sh
#!/bin/sh
set -eu
vs=${VSCREEN_BIN:-vscreen}
xr=$("$vs" screens --find 'XREAL*' 2>/dev/null) || exit 0   # Not connected: nothing to do.
[ "$("$vs" screens "$xr" --aspect)" = 32:9 ] || exit 0        # Not ultrawide yet.
exec "$vs" layout xreal-uw-dual
```

The layout is idempotent: it reuses `UWLeft`/`UWRight`, so repeated runs just reapply the same arrangement. When the glasses disconnect, the previews hide themselves and this hook exits without changes. When they're reconnected in ultrawide mode, the layout places the previews and shows them again.
