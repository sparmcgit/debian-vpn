#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/integration_helpers.sh"
setup_sandbox

# No --yes and a real (mocked) watchdog this time, to exercise the
# --confirm-revert path specifically rather than the --yes auto-confirm.
# No --yes flag (that also auto-confirms past the watchdog on successful
# validation, which is exactly the path this test wants to avoid), but
# confirm_or_abort()'s interactive prompt still needs an answer since the
# test harness has no real tty attached.
rc=0
WGFT_MOCK_CURL_RESULT=0 wgft --role client --wg-address 10.0.1.10/24 --peer-pubkey PEERKEY123= \
  --endpoint 192.168.2.13:51820 --dns 192.168.2.1 \
  --mgmt-iface wgft-mgmt0 --mgmt-gateway 192.168.2.1 --mgmt-subnet 192.168.2.0/24 \
  <<< "yes" || rc=$?
assert_success "$rc" "setup without --yes still exits 0 once validation passes"

[[ -f "$WATCHDOG_STATE_DIR/wg-debian-vpn.method" ]] && ok "watchdog is armed pending confirmation" \
  || fail "expected a pending watchdog method file"
[[ "$(cat "$WATCHDOG_STATE_DIR/wg-debian-vpn.method")" == "systemd" ]] && ok "watchdog method is systemd" \
  || fail "unexpected watchdog method: $(cat "$WATCHDOG_STATE_DIR/wg-debian-vpn.method" 2>/dev/null)"

# Regression test: rerunning setup while the previous run's watchdog is
# still armed (no --confirm-revert yet) must not die in schedule_watchdog()
# on systemd-run refusing the already-loaded unit name - that aborted the
# rerun right after "wg-quick down", leaving the client with no tunnel.
rc=0
WGFT_MOCK_CURL_RESULT=0 wgft --role client --wg-address 10.0.1.10/24 --peer-pubkey PEERKEY123= \
  --endpoint 192.168.2.13:51820 --dns 192.168.2.1 \
  --mgmt-iface wgft-mgmt0 --mgmt-gateway 192.168.2.1 --mgmt-subnet 192.168.2.0/24 \
  <<< "yes" || rc=$?
assert_success "$rc" "rerunning setup while the previous watchdog is still armed exits 0"
[[ -f "$WGFT_MOCK_STATE_DIR/wg-debian-vpn.state" ]] && ok "tunnel is up again after the rerun" \
  || fail "rerun left the tunnel down"

rc=0
wgft --confirm-revert --iface wg-debian-vpn || rc=$?
assert_success "$rc" "--confirm-revert exits 0"
[[ ! -f "$WATCHDOG_STATE_DIR/wg-debian-vpn.method" ]] && ok "--confirm-revert cancelled the watchdog" \
  || fail "watchdog method file still present after --confirm-revert"
[[ -f "$WGFT_MOCK_STATE_DIR/wg-debian-vpn.state" ]] && ok "the tunnel itself is untouched by --confirm-revert" \
  || fail "--confirm-revert should not have torn down the tunnel"

finish
