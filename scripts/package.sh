#!/bin/sh
# Build, ad-hoc sign, verify and archive a universal VScreen release.
# Used by the release workflow; run locally to reproduce a release build.
#
# Usage: scripts/package.sh <version> <build-number> [output-dir]
#
# Rebuilds build/ from clean as a universal binary.
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 <version> <build-number> [output-dir]" >&2
    exit 2
fi

version=$1
build_number=$2
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${3:-$repo_root/dist}
case "$output_dir" in /*) ;; *) output_dir="$PWD/$output_dir" ;; esac

if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo "version must be MAJOR.MINOR.PATCH without leading zeroes, got: $version" >&2
    exit 2
fi
case "$build_number" in
    ''|*[!0-9]*) echo "build number must be a nonnegative integer, got: $build_number" >&2; exit 2 ;;
esac

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vscreen-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
app="$work_dir/VScreen.app"
plist="$app/Contents/Info.plist"

echo "==> Building VScreen $version ($build_number)"
make -C "$repo_root" clean
make -C "$repo_root" ARCHS="arm64 x86_64"
ditto "$repo_root/build/VScreen.app" "$app"

echo "==> Stamping version and signing"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
codesign --force --sign - --timestamp=none --identifier local.vscreen "$app"

echo "==> Verifying package"
archs=$(lipo -archs "$app/Contents/MacOS/vscreen")
echo "vscreen: $archs"
case " $archs " in *" arm64 "*) ;; *) echo "missing arm64 slice" >&2; exit 1 ;; esac
case " $archs " in *" x86_64 "*) ;; *) echo "missing x86_64 slice" >&2; exit 1 ;; esac
codesign --verify --deep --strict --verbose=2 "$app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = local.vscreen ]

echo "==> Creating archive"
mkdir -p "$output_dir"
rm -f "$output_dir/VScreen.zip" "$output_dir/VScreen.zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/VScreen.zip"
(
    cd "$output_dir"
    shasum -a 256 VScreen.zip > VScreen.zip.sha256
    shasum -a 256 -c VScreen.zip.sha256
)

printf '\nVScreen %s (%s)\n  %s\n  %s\n' "$version" "$build_number" \
    "$output_dir/VScreen.zip" "$output_dir/VScreen.zip.sha256"
