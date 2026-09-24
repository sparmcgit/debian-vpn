#!/usr/bin/env bash
# Shared by the mock wg-quick/systemctl: extracts and runs the single
# PostUp/PostDown line from a wg-quick-style conf, the same way the real
# wg-quick would - so the actual generated nft/ip commands really execute.
set -euo pipefail
conf=$1
direction=$2  # up|down
key="PostUp"
[[ "$direction" == "down" ]] && key="PostDown"
line=$(sed -n "s/^${key} = //p" "$conf")
[[ -n "$line" ]] || exit 0
bash -c "$line"
