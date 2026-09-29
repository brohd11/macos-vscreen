# Auto-connect

VScreen can start at login and run hook scripts, which usually apply a [layout](cli.md#layouts), whenever a display is connected, disconnected, or changes mode. It doesn't track any display state itself. Each script checks the current displays and decides whether to act, so a hook runs often and usually does nothing.

## Setup

```sh
vscreen login --enable     # Start VScreen.app at login (a normal macOS Login Item)
vscreen login              # Status: enabled, disabled, or requires-approval
vscreen login --disable
```

If the status is `requires-approval`, VScreen opens **System Settings → General → Login Items** so you can allow it. Register the installed `/Applications/VScreen.app`, not a build copy: the Login Item points at the bundle that registered it.

## Hooks and the config

A hook is an executable script in `~/.vscreen/hooks` (`NAME` or `NAME.sh`). Hooks are kept separate from layouts, so they don't show up in `vscreen layout --list`. Only the hooks listed under `onDisplayChange` in `~/.vscreen/config.yaml` run (override the config path with `VSCREEN_CONFIG`; `hooks/` always sits next to it). The app creates the config, `hooks/`, and `layout/` on startup if they're missing, and never overwrites an existing config.

```sh
vscreen hooks --list            # Every hook script: enabled, disabled, or missing (listed but no script)
vscreen hooks --enable NAME     # Add NAME to onDisplayChange; the script must exist
vscreen hooks --disable NAME    # Remove it; the script stays in hooks/
```

`--enable` and `--disable` edit the config in place and keep your comments. If the list is in a form they can't safely edit, such as a non-empty `[a, b]` flow list, they change nothing and ask you to edit the file by hand. You can always edit it directly:

```yaml
onDisplayChange:
  - xreal-uw
  - [other-hook, arg1]
```

Each entry is a hook name or a list of `[name, args...]`. Values are always read as strings, so `- 1` is a hook named `1`. An empty `onDisplayChange:` means no hooks. Hooks run one at a time, in order. A failing hook doesn't stop the rest. The file is reread on every run, so edits apply without restarting.

## When hooks run

- **At login.** They run once when macOS starts VScreen as a Login Item (or you open the app from Finder), so displays that were already connected get set up. `VSCREEN_EVENT=launch`.
- **On display changes.** They run when a display that VScreen doesn't own is added, removed, enabled, disabled, or changes mode. Turning on XREAL's ultrawide mode is a mode change. `VSCREEN_EVENT=display-change`.

A connection arrives as a burst of changes, so hooks run 1.5 s after the last one. Changes that arrive while hooks are running trigger one more run after they finish. VScreen ignores its own virtual displays and displays that only moved, so a hook that creates or arranges displays doesn't retrigger itself.

When the app starts on demand (e.g. from `vscreen --new`), hooks don't run until the next display change. `vscreen quit` stops the app and its hooks until the next login.

Hooks start in your home directory, with `VSCREEN_BIN` set to the app's `vscreen` binary. Their stdout and stderr go to `hooks.log` next to the config (`~/.vscreen/hooks.log`), with a timestamped line for each start and exit status. The log is cleared once it passes 256 KB.

## Testing a hook

```sh
vscreen hooks          # Enabled hooks, one per line; exits 1 if the config is invalid
vscreen hooks --run    # Run them now in this terminal (VSCREEN_EVENT=manual); exits 1 if any fail
```

`hooks --run` doesn't need the app and prints output directly, so you can test a script without reconnecting anything.

## XREAL example

XREAL glasses connect in 16:9 mode. The `xreal-uw` preset installs a hook that applies [`xreal-uw-dual-32`](xreal-layouts.md) in 32:9 mode and `xreal-uw-dual-21` in 21:9 mode (which `--aspect` reports as `64:27`), and closes VScreen's desktops otherwise:

```sh
vscreen generate xreal-uw         # hooks/xreal-uw.sh + layout/xreal-uw-{dual-32,triple-32,dual-21}.sh
vscreen hooks --enable xreal-uw
```

`generate` never overwrites a file you've edited. If any target differs from the preset, it lists those files and writes nothing; remove them to regenerate. Edit the hook in `~/.vscreen/hooks/xreal-uw.sh`, e.g. to apply `xreal-uw-triple-32` in 32:9 mode instead.

The layout is idempotent: it reuses `Xreal-Virtual-Left`/`Xreal-Virtual-Right`, so repeated runs just reapply the same arrangement. When the glasses are reconnected in ultrawide mode, the layout places the previews and shows them again.
