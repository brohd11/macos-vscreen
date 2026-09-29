#!/bin/sh
set -eu
vs=${VSCREEN_BIN:-vscreen}
CAN_RUN=1
xr=$("$vs" screens --find 'XREAL*' 2>/dev/null) || CAN_RUN=0   # Not connected: nothing to do.
[ "$("$vs" screens "$xr" --aspect)" = 32:9 ] || CAN_RUN=0      # Not ultrawide yet.

if [ $CAN_RUN -eq 1 ]; then
	exec "$vs" layout xreal-uw-dual
else
	"$vs" close
fi