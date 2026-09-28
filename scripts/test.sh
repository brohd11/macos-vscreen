#!/bin/sh
# Parser and client/socket tests. Used by the release workflow before packaging.
set -eu
exec make -C "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" test
