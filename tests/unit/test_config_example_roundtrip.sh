#!/usr/bin/env bash
# Regression guard for the other CLAUDE.md invariant: print_config_example()
# "must stay parseable by parse_config_file()". Runs the round-trip for
# real instead of "eyeballing it".
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/unit_helpers.sh"

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Run in a subshell function so parse_config_file()'s err_exit (a real
# `exit`, not `return`) can't take down this whole test file if the
# round-trip is ever broken - we want a reported failure, not a crash.
run_roundtrip() (
  source_wgft_functions "$HERE/../../wg-fulltunnel.sh"
  print_config_example > "$tmpfile"
  parse_config_file "$tmpfile"
  printf '%s\n' "${CONFIG_ARGS[@]}"
)

if output=$(run_roundtrip 2>&1); then
  ok "print_config_example()'s own output parses cleanly via parse_config_file()"
else
  fail "parse_config_file() rejected print_config_example()'s own output: $output"
fi

assert_contains "$output" "--role" "parsed config includes --role"
assert_contains "$output" "--wg-address" "parsed config includes --wg-address"
assert_contains "$output" "--peer-pubkey" "parsed config includes --peer-pubkey"
assert_contains "$output" "--endpoint" "parsed config includes --endpoint"

finish
