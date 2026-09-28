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

## Releasing

Releases are cut by pushing a `vMAJOR.MINOR.PATCH` tag on `main`. The release workflow runs `scripts/test.sh` (`make test`), then `scripts/package.sh`, which rebuilds `build/` from clean as a universal (arm64 + x86_64) binary, stamps the version into `Info.plist`, re-signs ad hoc, and writes `dist/VScreen.zip` plus its `.sha256`. Release notes come from conventional commits via git-cliff.

```sh
scripts/package.sh 0.3.0 1          # reproduce a release build locally into dist/
```

`install.sh`, `.github/workflows/release.yml`, and `cliff.toml` are rendered from the shared templates in `sh-templates/mac-apps` by the monorepo's `render-mac.sh`; edit only the config block above `# ---- end config ----` in `install.sh`.
