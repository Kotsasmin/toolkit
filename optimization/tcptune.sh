#!/usr/bin/env bash
# Network-only tuning. Kept for compatibility, it now runs supertune's network module.
exec "$(dirname "$(readlink -f "$0")")/supertune.sh" --only network "$@"
