#!/usr/bin/env bash
# Shared helpers for tests/integration/*.sh. Sourced, not executed.
#
# Each integration test file is run standalone inside its own
# `unshare --user --map-root-user --net` sandbox (see tests/run.sh) - that
# gives it real root (satisfies wg-fulltunnel.sh's require_root()) and a
# throwaway network stack (safe for real `nft`/`ip` mutations), which
# vanish automatically when the test process exits. No manual cleanup
# needed.

set -Eeuo pipefail

INTEGRATION_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$INTEGRATION_LIB_DIR/../.." && pwd)
WGFT="$REPO_ROOT/wg-fulltunnel.sh"

FAILURES=0
ok()   { echo "  ok - $1"; }
fail() { echo "  NOT ok - $1"; FAILURES=$((FAILURES + 1)); }

finish() {
  if [[ $FAILURES -eq 0 ]]; then
    echo "PASS: $0"
    exit 0
  else
    echo "FAIL: $0 ($FAILURES failure(s))"
    exit 1
  fi
}

assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || fail "$3 (expected [$2], got [$1])"; }
assert_success() { local rc=$1 msg=$2; [[ $rc -eq 0 ]] && ok "$msg" || fail "$msg (exit $rc)"; }
assert_failure() { local rc=$1 msg=$2; [[ $rc -ne 0 ]] && ok "$msg" || fail "$msg (unexpectedly exited 0)"; }
assert_contains() { [[ "$1" == *"$2"* ]] && ok "$3" || fail "$3 (did not find [$2] in: $1)"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && ok "$3" || fail "$3 (unexpectedly found [$2])"; }

assert_nft_table_exists() {
  local table=$1 msg=$2
  if nft list table inet "$table" >/dev/null 2>&1; then ok "$msg"; else fail "$msg (table $table not found)"; fi
}

assert_nft_table_absent() {
  local table=$1 msg=$2
  if nft list table inet "$table" >/dev/null 2>&1; then fail "$msg (table $table unexpectedly present)"; else ok "$msg"; fi
}

# Creates a fresh scratch dir, redirects wg-fulltunnel.sh's hardcoded system
# paths into it via the env overrides added for testability, installs the
# mocked external commands (wg, wg-quick, systemctl, systemd-run, sysctl,
# curl, resolvectl) ahead of the real ones on PATH, and creates a dummy
# interface for the "management" (original LAN) side of client tests.
setup_sandbox() {
  WGFT_TEST_DIR=$(mktemp -d)
  export WGFT_TEST_DIR

  export CONF_DIR="$WGFT_TEST_DIR/etc-wireguard"
  export LOG_FILE="$WGFT_TEST_DIR/wg-fulltunnel.log"
  export WATCHDOG_STATE_DIR="$WGFT_TEST_DIR/run-wg-fulltunnel"
  export LOCK_FILE="$WGFT_TEST_DIR/wg-fulltunnel.lock"
  export SYSCTL_DIR="$WGFT_TEST_DIR/etc-sysctl.d"
  mkdir -p "$CONF_DIR" "$WATCHDOG_STATE_DIR" "$SYSCTL_DIR"

  export WGFT_MOCK_STATE_DIR="$WGFT_TEST_DIR/mock-state"
  mkdir -p "$WGFT_MOCK_STATE_DIR"

  local mockbin="$WGFT_TEST_DIR/bin"
  mkdir -p "$mockbin"
  cp "$INTEGRATION_LIB_DIR/mockbin/"* "$mockbin/"
  chmod +x "$mockbin"/*
  # A curated PATH (not prepended to the inherited one) so real system
  # copies of wg/wg-quick/curl/etc. elsewhere on this machine can never
  # leak in ahead of - or instead of - the mocks. nft/ip/coreutils still
  # resolve normally; they're real on purpose (see module docstring).
  export PATH="$mockbin:/usr/sbin:/usr/bin:/sbin:/bin"

  ip link add wgft-mgmt0 type dummy
  ip link set wgft-mgmt0 up
  ip addr add 192.168.2.50/24 dev wgft-mgmt0
}

wgft() { bash "$WGFT" "$@"; }
