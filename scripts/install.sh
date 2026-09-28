#!/bin/sh
set -eu
source_app=${1:-build/VScreen.app}
target_app=/Applications/VScreen.app
launcher_dir="$HOME/.local/bin"
launcher="$launcher_dir/vscreen"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -x "$source_app/Contents/MacOS/vscreen" ]; then
    echo "Build VScreen with make first." >&2
    exit 1
fi
if [ -e "$target_app" ]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist" 2>/dev/null || true)
    if [ "$identifier" != local.vscreen ]; then
        echo "Refusing to replace an unrelated app at $target_app." >&2
        exit 1
    fi
fi
if [ -e "$launcher" ] && ! cmp -s "$launcher" "$script_dir/vscreen"; then
    echo "Refusing to overwrite a different command at $launcher." >&2
    exit 1
fi
mkdir -p "$launcher_dir"
/usr/bin/ditto "$source_app" "$target_app"
/usr/bin/codesign --verify --strict "$target_app"
/usr/bin/install -m 755 "$script_dir/vscreen" "$launcher"
echo "Installed $target_app and $launcher"
case ":$PATH:" in
    *":$launcher_dir:"*) ;;
    *) echo "$launcher_dir is not on this shell's PATH; use $launcher directly." ;;
esac
