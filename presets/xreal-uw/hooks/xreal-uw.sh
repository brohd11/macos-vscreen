#!/bin/sh
set -eu

LAYOUT32=xreal-uw-dual-32
LAYOUT21=xreal-uw-dual-21

vs=${VSCREEN_BIN:-vscreen}
RUN_MODE=1
xr=$("$vs" screens --find 'XREAL*' 2>/dev/null) || RUN_MODE=0   # Not connected: nothing to do.

if [ "$("$vs" screens "$xr" --aspect)" = 32:9 ]; then
   RUN_MODE=1
# 21:9 mode reports 2560x1080; --aspect prints it in lowest terms (64:27).
elif [ "$("$vs" screens "$xr" --aspect)" = 64:27 ]; then
  RUN_MODE=2
else
  RUN_MODE=0
fi

if [ $RUN_MODE -eq 0 ]; then
	"$vs" close
elif [ $RUN_MODE -eq 1 ]; then
	exec "$vs" layout "$LAYOUT32"
elif [ $RUN_MODE -eq 2 ]; then
	exec "$vs" layout "$LAYOUT21"
else
	echo "Unrecognized run mode: $RUN_MODE"
	exit 1
fi