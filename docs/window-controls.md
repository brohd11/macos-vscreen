# Window controls

- **Option-drag:** move a preview.
- **Command–Option–T:** toggle all title bars.
- **Command–Option–H:** hide/show all previews; displays remain connected.
- **Command–Option–Q:** quit and remove owned displays.
- **Red traffic light:** close that desktop and remove its display.

If the screen a preview sits on disconnects (for example, unplugging a monitor), the preview hides instead of being moved onto another screen. It keeps its position; run `vscreen NAME --show` after reconnecting, or pass `--position` to place it elsewhere.

Previews do not capture, confine, warp, or forward mouse/keyboard input. Move the pointer onto a virtual display across its arranged screen edge as with any other display.

## App lifecycle

The app stays available for CLI commands after the last desktop closes; use `vscreen quit` to exit. It starts at login only if you run `vscreen login --enable`; see [Auto-connect](auto-connect.md). Desktop names/settings live only for that app session; save a layout script to recreate them, and list it in `~/.vscreen/config.yaml` to rerun it on display changes.

System Settings can show a stale arrangement after removal; quit and reopen Settings if `vscreen --screens` confirms the display is gone.
