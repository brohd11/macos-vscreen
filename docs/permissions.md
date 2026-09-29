# Permissions

VScreen needs **Screen Recording** to draw live previews. Accessibility is not required.

```sh
vscreen --request-permissions
```

This shows the macOS permission prompt; its button opens **System Settings → Privacy & Security → Screen & System Audio Recording**. Enable **VScreen** there, then run `vscreen quit` before creating a desktop. macOS shows the prompt only while the permission is undecided. If nothing appears, open that pane yourself, or reset VScreen as below and retry. If permission is already granted, the command just says so. The CLI automatically starts the app through LaunchServices, so permission belongs to VScreen rather than Terminal.

Read-only [screen queries](screen-queries.md) work without this permission.

## After rebuilding

The default signature is ad hoc. **Rebuilding can invalidate the grant**, even when its switch remains enabled. Finish building/installing, then reset only VScreen if necessary:

```sh
tccutil reset ScreenCapture local.vscreen
vscreen --request-permissions
# Enable VScreen, then restart the resident app:
vscreen quit
```

To avoid this, build with a stable signing identity; see [Building](building.md#signing-identity).

`vscreen --check` reports permission and API status from the resident app's context.
