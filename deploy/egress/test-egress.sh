#!/bin/sh
# Static entry point for CI. This does not start the staged containers and
# does not delete anything. The host runs deploy/egress/host-stage.sh instead.
# A previous revision removed containers on exit. That behavior is gone.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
exec "$root/test-static.sh"
