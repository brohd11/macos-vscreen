#!/bin/sh
set -eu

LAYOUT32=xreal-uw-dual-32
LAYOUT21=xreal-uw-dual-21

vs=${VSCREEN_BIN:-vscreen}
if ! xr=$("$vs" screens --find 'XREAL*' 2>/dev/null); then
	exec "$vs" close   # Not connected: remove the virtuals.
fi

case $("$vs" screens "$xr" --aspect) in
32:9) layout=$LAYOUT32 ;;
# 21:9 mode reports 2560x1080; --aspect prints it in lowest terms (64:27).
64:27) layout=$LAYOUT21 ;;
*) exec "$vs" close ;;   # 16:9 or another mode.
esac

# Switching between 21:9 and 32:9 drops XREAL to its lowest resolution. Restore the largest mode
# at this aspect; that change is itself a display change, so the hook reruns with the new size.
size=$("$vs" screens "$xr" --size)
best=$("$vs" screens "$xr" --set-mode max)
if [ "$best" != "$size" ]; then
	echo "XREAL set to $best; the hook will rerun."
	exit 0
fi
exec "$vs" layout "$layout"
