#!/usr/bin/env bash
# Compatibility entry point for the full SUSFS integration.
set -euo pipefail
exec "$(dirname "$0")/scripts/susfs/integrate.sh" "$@"
