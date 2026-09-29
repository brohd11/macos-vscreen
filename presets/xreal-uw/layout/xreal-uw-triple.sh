#!/bin/sh
# Split XREAL into three virtual displays with matching resolutions and previews.
# Uses only shell built-ins and vscreen. Override its path with VSCREEN_BIN.
set -eu
vscreen_bin=${VSCREEN_BIN:-vscreen}
vsrun() { "$vscreen_bin" "$@"; }
fail() { printf 'xreal-uw-triple: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || fail 'usage: xreal-uw-triple.sh (no arguments)'
command -v "$vscreen_bin" >/dev/null 2>&1 || fail "cannot find $vscreen_bin; install VScreen or set VSCREEN_BIN."

# Validate the complete layout before creating or changing any displays.
if ! xr=$(vsrun screens --find 'XREAL*'); then
    fail 'no XREAL display found; nothing changed.'
fi
dimensions=$(vsrun screens "$xr" --size)
width=${dimensions%x*}
height=${dimensions#*x}
left_width=$((width / 4))
right_width=$left_width
center_width=$((width - left_width - right_width))
validate_width() {
    [ "$1" -ge 480 ] && [ "$1" -le 7680 ] ||
        fail "each virtual must be 480–7680 pixels wide; this layout needs $1. Nothing changed."
}
validate_width "$left_width"
validate_width "$right_width"
validate_width "$center_width"
[ "$height" -ge 480 ] && [ "$height" -le 4320 ] ||
    fail "virtual height must be 480–4320 pixels; XREAL reports $height. Nothing changed."
main=$(vsrun screens --main)
main_origin=$(vsrun screens "$main" --origin)
main_size=$(vsrun screens "$main" --size)

# Center the entire contiguous row directly above the main display.
origin_x=$((${main_origin%x*} + (${main_size%x*} - width) / 2))
origin_y=$((${main_origin#*x} - height))
vsrun --new UWCenter --resolution "${center_width}x${height}" --size "${center_width}x${height}" --origin "$((origin_x + left_width))x${origin_y}" --borderless --hide
vsrun --new UWLeft --resolution "${left_width}x${height}" --size "${left_width}x${height}" --origin "${origin_x}x${origin_y}" --borderless --hide
vsrun --new UWRight --resolution "${right_width}x${height}" --size "${right_width}x${height}" --origin "$((origin_x + left_width + center_width))x${origin_y}" --borderless --hide

# Connecting displays can move XREAL. Position previews using its new origin,
# but never stretch the captured image if its logical size changed mid-setup.
if ! current_size=$(vsrun screens "$xr" --size) || ! origin=$(vsrun screens "$xr" --origin); then
    fail 'XREAL disconnected during setup; previews remain hidden. Reconnect and rerun.'
fi
[ "$current_size" = "$dimensions" ] ||
    fail 'XREAL changed size during setup; previews remain hidden. Rerun to use its new size.'
x=${origin%x*}
y=${origin#*x}
vsrun UWLeft --size "${left_width}x${height}" --position "${x}x${y}" --show
vsrun UWCenter --size "${center_width}x${height}" --position "$((x + left_width))x${y}" --show
vsrun UWRight --size "${right_width}x${height}" --position "$((x + left_width + center_width))x${y}" --show
printf 'Three virtual displays now fill XREAL (display %s, %s).\n' "$xr" "$dimensions"
