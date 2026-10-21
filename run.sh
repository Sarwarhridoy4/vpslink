#!/usr/bin/env bash
# run.sh - convenience entry point that runs the canonical setup script.
#
# The real implementation lives in vpslink.sh next to this file, so there is
# a single source of truth. All arguments are forwarded unchanged.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/vpslink.sh" "$@"
