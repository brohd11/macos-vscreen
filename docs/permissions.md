# Permissions

VScreen needs **Screen Recording** to draw live previews. Accessibility is not required.

```sh
vscreen --request-permissions
```

Enable **VScreen** under **System Settings → Privacy & Security → Screen & System Audio Recording**, then run `vscreen quit` before creating a desktop. The CLI automatically starts the app through LaunchServices, so permission belongs to VScreen rather than Terminal.

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
