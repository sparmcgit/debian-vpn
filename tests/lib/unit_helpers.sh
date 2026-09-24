#!/usr/bin/env bash
# Shared helpers for tests/unit/*.sh. Sourced, not executed.

FAILURES=0

ok()   { echo "  ok - $1"; }
fail() { echo "  NOT ok - $1"; FAILURES=$((FAILURES + 1)); }

assert_eq() {
  local actual=$1 expected=$2 msg=$3
  if [[ "$actual" == "$expected" ]]; then
    ok "$msg"
  else
    fail "$msg (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$msg"
  else
    fail "$msg (did not find [$needle])"
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$msg"
  else
    fail "$msg (unexpectedly found [$needle])"
  fi
}

# Passes only if $2 appears in $1 strictly before $3.
assert_before() {
  local haystack=$1 first=$2 second=$3 msg=$4
  local pos1 pos2
  pos1=$(awk -v h="$haystack" -v n="$first" 'BEGIN{print index(h,n)}')
  pos2=$(awk -v h="$haystack" -v n="$second" 'BEGIN{print index(h,n)}')
  if [[ "$pos1" -gt 0 && "$pos2" -gt 0 && "$pos1" -lt "$pos2" ]]; then
    ok "$msg"
  else
    fail "$msg (positions: [$first]=$pos1 [$second]=$pos2)"
  fi
}

finish() {
  if [[ $FAILURES -eq 0 ]]; then
    echo "PASS: $0"
    exit 0
  else
    echo "FAIL: $0 ($FAILURES failure(s))"
    exit 1
  fi
}

# Sources every function/variable definition from wg-fulltunnel.sh into the
# CURRENT shell, without running its trailing `main "$@"` — so tests can call
# individual functions directly. Relies on that exact trailing line existing;
# if it's ever refactored, this needs to move with it.
source_wgft_functions() {
  local script=$1 cutline
  cutline=$(grep -n '^main "\$@"$' "$script" | head -1 | cut -d: -f1)
  if [[ -z "$cutline" ]]; then
    echo "source_wgft_functions: could not find 'main \"\$@\"' in $script" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source <(head -n "$((cutline - 1))" "$script")
}
