#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/integration_helpers.sh"
setup_sandbox

rc=0
wgft --role server --wg-address 10.0.0.1/24 --peer-pubkey PEERKEY123= \
  --peer-allowed-ips 10.0.0.2/32 --ext-iface eth0 || rc=$?
assert_success "$rc" "server setup exits 0"
assert_nft_table_exists wgft_server_wg_debian_vpn "server nft table exists after setup (applied via the mocked systemctl restart)"

nft_out=$(nft list table inet wgft_server_wg_debian_vpn)
assert_contains "$nft_out" 'oifname "eth0" masquerade' "MASQUERADE rule targets the configured --ext-iface"
assert_contains "$nft_out" 'iifname "wg-debian-vpn" accept' "forward accept rule for inbound tunnel traffic"

[[ -f "$SYSCTL_DIR/99-wg-fulltunnel.conf" ]] && ok "ip_forward sysctl file was written" \
  || fail "expected ${SYSCTL_DIR}/99-wg-fulltunnel.conf to exist"
grep -q "net.ipv4.ip_forward=1" "$SYSCTL_DIR/99-wg-fulltunnel.conf" && ok "sysctl file enables ip_forward" \
  || fail "sysctl file missing net.ipv4.ip_forward=1"

# Regression test: simulate a reboot. nft state lives only in the kernel, so
# after a restart the table is gone and the boot-time wg-quick@ unit runs
# PostUp on its own, without ensure_nft_server_base(). PostUp used to only
# "nft add rule" into the pre-existing table, so this failed and the server
# came up with no tunnel at all.
wgft --disable --iface wg-debian-vpn >/dev/null 2>&1 || true
nft delete table inet wgft_server_wg_debian_vpn
rc=0
wgft --enable --iface wg-debian-vpn || rc=$?
assert_success "$rc" "tunnel comes back up after a simulated reboot wiped the nft table"
nft_out=$(nft list table inet wgft_server_wg_debian_vpn 2>&1)
assert_contains "$nft_out" 'oifname "eth0" masquerade' "PostUp recreated the table and MASQUERADE rule on its own after reboot"

# --ext-iface fallback list: the real nft table gets a masquerade per entry.
rc=0
wgft --role server --wg-address 10.0.0.1/24 --peer-pubkey PEERKEY123= \
  --peer-allowed-ips 10.0.0.2/32 --ext-iface wg0,eth0 >/dev/null 2>&1 || rc=$?
assert_success "$rc" "server setup with an --ext-iface list exits 0"
nft_out=$(nft list table inet wgft_server_wg_debian_vpn)
assert_contains "$nft_out" 'oifname "wg0" masquerade' "masquerade on the first listed interface"
assert_contains "$nft_out" 'oifname "eth0" masquerade' "masquerade on the fallback interface"
rc=0
wgft --role server --wg-address 10.0.0.1/24 --peer-pubkey PEERKEY123= \
  --peer-allowed-ips 10.0.0.2/32 --ext-iface 'wg0,,eth0' >/dev/null 2>&1 || rc=$?
assert_failure "$rc" "a malformed --ext-iface list is rejected"

# A foreign table with a forward-hook "policy drop" (e.g. a VPN client's
# kill switch) silently eats every forwarded client packet - setup must warn.
nft add table inet otherkill
nft add chain inet otherkill forward '{ type filter hook forward priority filter; policy drop; }'
wgft --role server --wg-address 10.0.0.1/24 --peer-pubkey PEERKEY123= \
  --peer-allowed-ips 10.0.0.2/32 --ext-iface eth0 >/dev/null 2>&1 || true
grep -q "WARNING: nft table 'inet otherkill' has a forward chain with 'policy drop'" "$LOG_FILE" \
  && ok "server setup warns about a foreign forward chain with policy drop" \
  || fail "no warning about the foreign policy-drop forward chain"
nft delete table inet otherkill

rc=0
wgft --disable --iface wg-debian-vpn || rc=$?
assert_success "$rc" "--disable exits 0 on the server role"
[[ ! -f "$WGFT_MOCK_STATE_DIR/wg-debian-vpn.state" ]] && ok "--disable tore down the server's tunnel" \
  || fail "server interface still marked up after --disable"

rc=0
wgft --rollback --iface wg-debian-vpn || rc=$?
assert_success "$rc" "--rollback exits 0"
assert_nft_table_absent wgft_server_wg_debian_vpn "rollback removed the server nft table"
[[ ! -f "$SYSCTL_DIR/99-wg-fulltunnel.conf" ]] && ok "rollback removed the ip_forward sysctl file" \
  || fail "sysctl file still present after rollback"

finish
