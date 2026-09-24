#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/unit_helpers.sh"
source_wgft_functions "$HERE/../../wg-fulltunnel.sh"

assert_eq "$(nft_tag "wg-debian-vpn")" "wg_debian_vpn" "hyphenated iface name is sanitized for nft object names"
assert_eq "$(nft_tag "eth0")" "eth0" "plain iface name passes through unchanged"
assert_eq "$(nft_tag "a.b:c")" "a_b_c" "dots and colons are sanitized"
assert_eq "$(nft_tag "wg0")" "wg0" "digits are preserved"

finish
