#!/bin/sh
# Fill XREAL's 21:9 mode with a 16:9 virtual display plus a vertical strip on its right.
# Uses only shell built-ins and vscreen. Override its path with VSCREEN_BIN.
set -eu
vscreen_bin=${VSCREEN_BIN:-vscreen}
vsrun() { "$vscreen_bin" "$@"; }
fail() { printf 'xreal-uw-dual-21: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || fail 'usage: xreal-uw-dual-21.sh (no arguments)'
command -v "$vscreen_bin" >/dev/null 2>&1 || fail "cannot find $vscreen_bin; install VScreen or set VSCREEN_BIN."
left=Xreal-Virtual-Left
center=Xreal-Virtual-Center
right=Xreal-Virtual-Right

# Validate the complete layout before creating or changing any displays.
if ! xr=$(vsrun screens --find 'XREAL*'); then
    fail 'no XREAL display found; nothing changed.'
fi
dimensions=$(vsrun screens "$xr" --size)
width=${dimensions%x*}
height=${dimensions#*x}
left_width=$((height * 16 / 9))   # 16:9 at full height; the strip gets the rest.
right_width=$((width - left_width))
validate_width() {
    [ "$1" -ge 480 ] && [ "$1" -le 7680 ] ||
        fail "each virtual must be 480–7680 pixels wide; this layout needs $1. Nothing changed."
}
validate_width "$left_width"
validate_width "$right_width"
[ "$height" -ge 480 ] && [ "$height" -le 4320 ] ||
    fail "virtual height must be 480–4320 pixels; XREAL reports $height. Nothing changed."
main=$(vsrun screens --main)
main_origin=$(vsrun screens "$main" --origin)
main_size=$(vsrun screens "$main" --size)

# Center the entire contiguous row directly above the main display.
origin_x=$((${main_origin%x*} + (${main_size%x*} - width) / 2))
origin_y=$((${main_origin#*x} - height))
# The triple layout's center display would overlap this row; closing a missing display is a no-op.
vsrun "$center" --close
vsrun --new "$left" --resolution "${left_width}x${height}" --size "${left_width}x${height}" --origin "${origin_x}x${origin_y}" --borderless --hide
vsrun --new "$right" --resolution "${right_width}x${height}" --size "${right_width}x${height}" --origin "$((origin_x + left_width))x${origin_y}" --borderless --hide

# Connecting displays can move XREAL. Position previews using its new origin,
# but never stretch the captured image if its logical size changed mid-setup.
if ! current_size=$(vsrun screens "$xr" --size) || ! origin=$(vsrun screens "$xr" --origin); then
    fail 'XREAL disconnected during setup; previews remain hidden. Reconnect and rerun.'
fi
[ "$current_size" = "$dimensions" ] ||
    fail 'XREAL changed size during setup; previews remain hidden. Rerun to use its new size.'
x=${origin%x*}
y=${origin#*x}
vsrun "$left" --size "${left_width}x${height}" --position "${x}x${y}" --show
vsrun "$right" --size "${right_width}x${height}" --position "$((x + left_width))x${y}" --show
printf 'A 16:9 and a vertical display now fill XREAL (display %s, %s).\n' "$xr" "$dimensions"
