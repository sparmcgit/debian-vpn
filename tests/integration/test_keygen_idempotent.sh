#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/integration_helpers.sh"
setup_sandbox

rc=0
first=$(wgft --keygen --iface wg-debian-vpn | tail -1 | tr -d '[:space:]') || rc=$?
assert_success "$rc" "first --keygen run exits 0"
[[ -n "$first" ]] && ok "first --keygen printed a public key" || fail "no public key printed"

rc=0
second=$(wgft --keygen --iface wg-debian-vpn | tail -1 | tr -d '[:space:]') || rc=$?
assert_success "$rc" "second --keygen run exits 0"
assert_eq "$second" "$first" "--keygen reuses the existing keypair instead of regenerating it"

# Setting up a role afterward must NOT regenerate the key either.
rc=0
wgft --role server --wg-address 10.0.0.1/24 --peer-pubkey PEERKEY123= \
  --peer-allowed-ips 10.0.0.2/32 --ext-iface eth0 >/dev/null || rc=$?
assert_success "$rc" "the --role server run itself exits 0"
third=$(wgft --keygen --iface wg-debian-vpn | tail -1 | tr -d '[:space:]')
assert_eq "$third" "$first" "the keypair is still unchanged after a full --role server run"

finish
