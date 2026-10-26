#!/usr/bin/env bash
# Reverts supertune (and old tcptune/ramtune installs). Kept for compatibility.
exec "$(dirname "$(readlink -f "$0")")/supertune.sh" --undo "$@"
