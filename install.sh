#!/bin/sh
# Install VScreen into /Applications and a vscreen launcher into ~/.local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/brohd11/macos-vscreen/main/install.sh | sh
#
# Env overrides:
#   INSTALL_DIR=/Applications   app destination
#   BIN_DIR=~/.local/bin        launcher destination
#   VERSION=v1.2.3              pin a release   (default: latest)
#
# Body below "end config" comes from sh-templates/mac-apps/templates/install.template.sh.
# Update the template, then run the workspace's render-mac.sh.

set -eu

# ---- config ----
REPO="brohd11/macos-vscreen"
APP_NAME="VScreen.app"
APP_EXECUTABLE="vscreen"
ARCHIVE="VScreen"
BUNDLE_ID="local.vscreen"
MIN_MACOS=14
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
LAUNCHER_NAME="vscreen"
REQUIRED_COMMANDS=""

pre_replace() {
  # A running resident app keeps executing the old binary; stop it so the next
  # command starts the new one. quit does not start an absent app.
  if [ -x "$TARGET_APP/Contents/MacOS/$APP_EXECUTABLE" ]; then
    "$TARGET_APP/Contents/MacOS/$APP_EXECUTABLE" quit >/dev/null 2>&1 || true
  fi
}
post_replace() { :; }
on_failure() { :; }

post_install_note() {
  say "Next steps:"
  say "  1. Run: vscreen --request-permissions"
  say "  2. Enable VScreen under System Settings > Privacy & Security > Screen & System Audio Recording."
  say "  3. Run: vscreen quit"
  say ""
  say "Each update is a new ad-hoc signature and can invalidate the Screen Recording grant. If previews"
  say "stay blank, run: tccutil reset ScreenCapture local.vscreen, then repeat the steps above."
}
# ---- end config ----

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
VERSION="${VERSION:-latest}"
TARGET_APP="$INSTALL_DIR/$APP_NAME"
app_label="${APP_NAME%.app}"
installer_label="$(printf '%s' "$ARCHIVE" | tr '[:upper:]' '[:lower:]') installer"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      # Not derived from $0: under `curl | sh` there is no script path to read.
      cat <<EOF
install $app_label into \$INSTALL_DIR (default: /Applications)

  INSTALL_DIR=<dir>        app destination (absolute path)
  BIN_DIR=<dir>            command launcher destination (default: \$HOME/.local/bin)
  VERSION=<tag>            pin a release (default: latest)
  RELEASE_BASE_URL=<url>   download assets from a mirror instead of GitHub
EOF
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf '%s: %s\n' "$installer_label" "$*" >&2; exit 1; }
path_exists() { [ -e "$1" ] || [ -L "$1" ]; }

# --- rollback ----------------------------------------------------------------

download_dir=""
stage_dir=""
backup_app=""
replacement_started=0
hooks_started=0

# A replacement that did not reach its end is a failure: put the previous app back,
# then let the config's on_failure hook undo whatever pre_replace changed.
cleanup() {
  status=$?
  trap - EXIT

  if [ "$replacement_started" -eq 1 ] && path_exists "$backup_app"; then
    if path_exists "$TARGET_APP" && ! mv "$TARGET_APP" "$stage_dir/Failed $APP_NAME"; then
      printf '%s: could not move the failed replacement out of %s\n' "$installer_label" "$TARGET_APP" >&2
      stage_dir=""
    fi
    if ! path_exists "$TARGET_APP" && ! mv "$backup_app" "$TARGET_APP"; then
      printf '%s: could not restore the previous app from %s\n' "$installer_label" "$backup_app" >&2
      stage_dir=""
    fi
  fi

  if [ "$status" -ne 0 ] && [ "$hooks_started" -eq 1 ]; then
    on_failure || true
  fi

  [ -z "$stage_dir" ] || rm -rf -- "$stage_dir"
  [ -z "$download_dir" ] || rm -rf -- "$download_dir"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# --- preflight ---------------------------------------------------------------

[ "$(uname -s)" = Darwin ] || fail "$app_label requires macOS."

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
case "$macos_major" in
  ''|*[!0-9]*) fail "could not determine the macOS version." ;;
esac
[ "$macos_major" -ge "$MIN_MACOS" ] || fail "$app_label requires macOS $MIN_MACOS or newer (found $macos_version)."

for required_command in curl ditto shasum codesign mktemp $REQUIRED_COMMANDS; do
  command -v "$required_command" >/dev/null 2>&1 || fail "required command not found: $required_command"
done
[ -x /usr/libexec/PlistBuddy ] || fail "required command not found: /usr/libexec/PlistBuddy"

case "$INSTALL_DIR" in
  /*) ;;
  *) fail "INSTALL_DIR must be an absolute path." ;;
esac
mkdir -p "$INSTALL_DIR" || fail "could not create $INSTALL_DIR."
[ -w "$INSTALL_DIR" ] || fail "cannot write to $INSTALL_DIR. Set INSTALL_DIR to a writable absolute path."

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Only replace a launcher this installer (or the repo's local install) wrote.
launcher="$BIN_DIR/$LAUNCHER_NAME"
launcher_marker="# $app_label launcher"
if [ -n "$LAUNCHER_NAME" ] && path_exists "$launcher" &&
  [ "$(sed -n 2p "$launcher" 2>/dev/null)" != "$launcher_marker" ]; then
  fail "refusing to overwrite a different command at $launcher."
fi

if path_exists "$TARGET_APP"; then
  existing_id="$(bundle_id_of "$TARGET_APP")"
  [ "$existing_id" = "$BUNDLE_ID" ] ||
    fail "refusing to replace $TARGET_APP: its bundle identifier is ${existing_id:-missing}, expected $BUNDLE_ID."
fi

# --- download and verify -----------------------------------------------------

# Asset names are version-less so the /latest/download redirect works without the
# GitHub API. A mirror override may also be a file:// URL, for testing a local build.
curl_protocols='=https'
if [ -n "${RELEASE_BASE_URL:-}" ]; then
  base_url="$RELEASE_BASE_URL"
  curl_protocols='=https,file'
elif [ "$VERSION" = latest ]; then
  base_url="https://github.com/$REPO/releases/latest/download"
else
  base_url="https://github.com/$REPO/releases/download/$VERSION"
fi

download_dir="$(mktemp -d "${TMPDIR:-/tmp}/$ARCHIVE-download.XXXXXX")" || fail "could not create a temporary download directory."
archive_file="$ARCHIVE.zip"
checksum_file="$ARCHIVE.zip.sha256"

say "Downloading $app_label ($VERSION)..."
for asset in "$archive_file" "$checksum_file"; do
  curl --fail --location --silent --show-error --retry 3 --proto "$curl_protocols" --tlsv1.2 \
    --output "$download_dir/$asset" "$base_url/$asset" ||
    fail "download failed: $base_url/$asset (check https://github.com/$REPO/releases)"
done

say "Verifying SHA-256 checksum..."
(cd "$download_dir" && shasum -a 256 -c "$checksum_file") ||
  fail "the downloaded archive did not match its published checksum."

extract_dir="$download_dir/extracted"
mkdir "$extract_dir"
ditto -x -k "$download_dir/$archive_file" "$extract_dir" || fail "could not extract $archive_file."
source_app="$extract_dir/$APP_NAME"

[ -d "$source_app" ] || fail "the release archive does not contain $APP_NAME."
[ -x "$source_app/Contents/MacOS/$APP_EXECUTABLE" ] || fail "the release contains an invalid app bundle."
source_id="$(bundle_id_of "$source_app")"
[ "$source_id" = "$BUNDLE_ID" ] || fail "the release contains an unexpected bundle identifier: ${source_id:-missing}."
codesign --verify --deep --strict "$source_app" || fail "the release app failed code-signature verification."

# --- install -----------------------------------------------------------------

# Stage inside INSTALL_DIR so the final swap is a same-volume rename.
stage_dir="$(mktemp -d "$INSTALL_DIR/.$ARCHIVE-install.XXXXXX")" || fail "could not create a staging directory in $INSTALL_DIR."
staged_app="$stage_dir/$APP_NAME"
ditto "$source_app" "$staged_app"
codesign --verify --deep --strict "$staged_app" || fail "the staged app failed code-signature verification."

hooks_started=1
pre_replace

if path_exists "$TARGET_APP"; then
  say "Replacing the existing app..."
  backup_app="$stage_dir/Previous $APP_NAME"
  replacement_started=1
  mv "$TARGET_APP" "$backup_app" || fail "could not move the existing app out of the way."
else
  say "Installing $app_label..."
fi

mv "$staged_app" "$TARGET_APP" || fail "could not move $app_label into $INSTALL_DIR."
post_replace

replacement_started=0
hooks_started=0
say "Installed $app_label at $TARGET_APP"

# --- launcher ----------------------------------------------------------------

if [ -n "$LAUNCHER_NAME" ]; then
  mkdir -p "$BIN_DIR" || fail "could not create $BIN_DIR."
  printf '#!/bin/sh\n%s\nexec "%s/Contents/MacOS/%s" "$@"\n' \
    "$launcher_marker" "$TARGET_APP" "$APP_EXECUTABLE" > "$download_dir/launcher"
  install -m 755 "$download_dir/launcher" "$launcher" || fail "could not write $launcher."
  say "Installed launcher at $launcher"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "$BIN_DIR is not on your PATH; run $launcher directly or add the directory to PATH." ;;
  esac
fi

say ""
post_install_note
