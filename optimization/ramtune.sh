#!/usr/bin/env bash
# ZRAM and memory tuning. Kept for compatibility, it now runs supertune's memory module.
exec "$(dirname "$(readlink -f "$0")")/supertune.sh" --only memory "$@"
