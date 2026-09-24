#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/integration_helpers.sh"
setup_sandbox

common_args=(--role client --wg-address 10.0.1.10/24 --peer-pubkey PEERKEY123=
             --endpoint 192.168.2.13:51820 --dns 192.168.2.1
             --mgmt-iface wgft-mgmt0 --mgmt-gateway 192.168.2.1 --mgmt-subnet 192.168.2.0/24
             --yes --revert-after 0)

rc=0
WGFT_MOCK_CURL_RESULT=0 wgft "${common_args[@]}" || rc=$?
assert_success "$rc" "first-time client setup with passing validation exits 0"
assert_nft_table_exists wgft_client_wg_debian_vpn "client nft table exists after setup"

nft_out=$(nft list table inet wgft_client_wg_debian_vpn)
assert_contains "$nft_out" 'iifname "wgft-mgmt0" ct mark set 0x00000064' "mangle_pre rule marks packets arriving on the mgmt interface"
assert_contains "$nft_out" 'ip daddr 192.168.2.1 udp dport 53 accept' "DNS-server exception is present"

rule_out=$(ip rule show)
assert_contains "$rule_out" "fwmark 0x64 lookup 100" "policy-routing ip rule is installed"

route_out=$(ip route get 1.1.1.1 mark 100)
assert_contains "$route_out" "dev wgft-mgmt0" "marked traffic actually resolves via the mgmt interface, not the tunnel"

# The bug this whole project exists to prevent: without the connected-
# subnet route in table 100, a SAME-SUBNET destination (as opposed to a
# genuinely remote one like 1.1.1.1 above) would match table 100's
# default-via-gateway entry and get sent INDIRECTLY via the gateway
# instead of directly on the LAN - table 100's lookup already produced *a*
# route, so main's more specific connected route is never reached.
samesubnet_route_out=$(ip route get 192.168.2.99 mark 100)
assert_contains "$samesubnet_route_out" "dev wgft-mgmt0" "same-subnet destination still resolves via the mgmt interface"
assert_not_contains "$samesubnet_route_out" "via 192.168.2.1" "same-subnet destination is routed DIRECTLY, not indirectly via the gateway (the connected-subnet route in table 100 is doing its job)"

# Regression test: rerunning setup while the interface is already "up" must
# not crash wg-quick with "already exists" - setup_client() should bring
# it down first (see the fix for exactly this bug).
rc=0
WGFT_MOCK_CURL_RESULT=0 wgft "${common_args[@]}" || rc=$?
assert_success "$rc" "rerunning setup on an already-up interface does not fail"

seq_log=$(cat "$WGFT_MOCK_STATE_DIR/sequence.log")
down_count=$(grep -c "^down wg-debian-vpn$" <<< "$seq_log")
up_count=$(grep -c "^up wg-debian-vpn$" <<< "$seq_log")
[[ "$down_count" -eq 1 && "$up_count" -eq 2 ]] && ok "rerun did exactly one down-then-up cycle (not a crash, not a duplicate)" \
  || fail "expected 1 down + 2 up in sequence log, got down=$down_count up=$up_count: $seq_log"

nft_out2=$(nft list table inet wgft_client_wg_debian_vpn)
dup_count=$(grep -c 'iifname "wgft-mgmt0" ct mark set' <<< "$nft_out2")
[[ "$dup_count" -eq 1 ]] && ok "mangle_pre has exactly one rule after rerun (ensure_nft_client_base's flush prevented duplication)" \
  || fail "expected exactly 1 mangle_pre rule after rerun, found $dup_count"

# Plain disable/enable toggle.
rc=0
wgft --disable --iface wg-debian-vpn || rc=$?
assert_success "$rc" "--disable exits 0"
[[ ! -f "$WGFT_MOCK_STATE_DIR/wg-debian-vpn.state" ]] && ok "--disable actually tore down the interface" \
  || fail "--disable left the interface marked up"

rc=0
wgft --enable --iface wg-debian-vpn || rc=$?
assert_success "$rc" "--enable exits 0"
[[ -f "$WGFT_MOCK_STATE_DIR/wg-debian-vpn.state" ]] && ok "--enable actually brought the interface back up" \
  || fail "--enable did not bring the interface back up"

# Regression test: simulate a reboot (nft table wiped, boot-time wg-quick@
# unit runs PostUp without ensure_nft_client_base() having run) - see the
# same test in test_server_lifecycle.sh.
wgft --disable --iface wg-debian-vpn >/dev/null 2>&1 || true
nft delete table inet wgft_client_wg_debian_vpn
rc=0
wgft --enable --iface wg-debian-vpn || rc=$?
assert_success "$rc" "tunnel comes back up after a simulated reboot wiped the nft table"
nft_out3=$(nft list table inet wgft_client_wg_debian_vpn 2>&1)
assert_contains "$nft_out3" 'iifname "wgft-mgmt0" ct mark set 0x00000064' "PostUp recreated mangle_pre and its rule on its own after reboot"
assert_contains "$nft_out3" 'ip daddr 192.168.2.1 udp dport 53 accept' "PostUp recreated dns_out and its rules on its own after reboot"

rc=0
status_out=$(wgft --status --iface wg-debian-vpn 2>&1) || rc=$?
assert_success "$rc" "--status exits 0"
assert_contains "$status_out" "wgft_client_wg_debian_vpn" "--status output includes the client nft table"

finish
