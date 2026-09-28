# Building

Requires macOS 14+ and Xcode Command Line Tools to build. No third-party runtime dependencies.

```sh
make            # build/VScreen.app and the build/vscreen CLI symlink
make install    # install the app and the shell launcher
make clean      # remove build/
```

`make install` installs **`/Applications/VScreen.app`** and a small forwarding shell script at **`~/.local/bin/vscreen`**. If that directory is on PATH, no alias or shell-profile edits are needed. Otherwise invoke `~/.local/bin/vscreen` directly.

After installing, grant Screen Recording as described in [Permissions](permissions.md).

## Signing identity

The default signature is ad hoc, which means **rebuilding can invalidate the Screen Recording grant** (see [Permissions](permissions.md#after-rebuilding)).

If you have an installed Apple Development identity, build consistently with `make SIGNING_IDENTITY="Apple Development: …"` for a stable signature across builds. Rebuild with `make clean` when changing the signing identity.
