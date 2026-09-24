#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/integration_helpers.sh"
setup_sandbox

rc=0
WGFT_MOCK_CURL_RESULT=1 wgft --role client --wg-address 10.0.1.10/24 --peer-pubkey PEERKEY123= \
  --endpoint 192.168.2.13:51820 --dns 192.168.2.1 \
  --mgmt-iface wgft-mgmt0 --mgmt-gateway 192.168.2.1 --mgmt-subnet 192.168.2.0/24 \
  --yes --revert-after 0 || rc=$?

assert_failure "$rc" "setup with a failing outbound-connectivity check exits nonzero"
grep -q "rolling back wg-debian-vpn" "$LOG_FILE" && ok "do_rollback() ran after validation failure" \
  || fail "log does not show a rollback"
assert_nft_table_absent wgft_client_wg_debian_vpn "rollback removed the client nft table"
grep -q "diagnosis: NO handshake" "$LOG_FILE" && ok "failure log diagnoses the missing handshake" \
  || fail "log does not diagnose the missing handshake"
[[ ! -f "$WGFT_MOCK_STATE_DIR/wg-debian-vpn.state" ]] && ok "rollback left the interface down" \
  || fail "interface still marked up after rollback"

# The other two diagnoses: handshake OK but nothing gets through (server
# not forwarding/NATing), and only DNS broken.
common=(--role client --wg-address 10.0.1.10/24 --peer-pubkey PEERKEY123=
        --endpoint 192.168.2.13:51820 --dns 192.168.2.1
        --mgmt-iface wgft-mgmt0 --mgmt-gateway 192.168.2.1 --mgmt-subnet 192.168.2.0/24
        --yes --revert-after 0)
WGFT_MOCK_HANDSHAKE=$(date +%s) WGFT_MOCK_CURL_RESULT=1 wgft "${common[@]}" >/dev/null 2>&1 || true
grep -q "diagnosis: handshake OK but raw IP" "$LOG_FILE" && ok "failure log diagnoses server-side forwarding/NAT" \
  || fail "log does not diagnose server-side forwarding/NAT"
WGFT_MOCK_HANDSHAKE=$(date +%s) WGFT_MOCK_CURL_RESULT=1 WGFT_MOCK_CURL_IP_RESULT=0 wgft "${common[@]}" >/dev/null 2>&1 || true
grep -q "diagnosis: raw IP (https://1.1.1.1) works" "$LOG_FILE" && ok "failure log diagnoses a DNS-only problem" \
  || fail "log does not diagnose a DNS-only problem"

finish
