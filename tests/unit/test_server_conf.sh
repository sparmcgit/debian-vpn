#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/unit_helpers.sh"
source_wgft_functions "$HERE/../../wg-fulltunnel.sh"

IFACE=wg-debian-vpn
WG_ADDRESS=10.0.0.1/24
WG_PORT=51820
PRIV_KEY="<server_private_key>"
PEER_PUBKEY="<client_public_key>"
PEER_ALLOWED_IPS="10.0.0.2/32"
EXT_IFACE=eth0
IPV6=0

out=$(server_conf)

assert_contains "$out" 'oifname "eth0" masquerade' "MASQUERADE rule uses the configured EXT_IFACE"
assert_contains "$out" 'iifname "wg-debian-vpn" accept' "FORWARD accept rule for inbound tunnel traffic"
assert_contains "$out" 'oifname "wg-debian-vpn" accept' "FORWARD accept rule for outbound tunnel traffic"
assert_contains "$out" "nft flush chain inet wgft_server_wg_debian_vpn forward" "PostDown flushes the forward chain"
assert_contains "$out" "nft flush chain inet wgft_server_wg_debian_vpn postrouting" "PostDown flushes the postrouting chain"
assert_not_contains "$out" "iptables" "no iptables commands remain"
assert_not_contains "$out" "ip6tables" "no ip6tables duplication for IPv6 (inet table already covers it)"

# --ext-iface substitution with a different value.
EXT_IFACE=enp3s0
out2=$(server_conf)
assert_contains "$out2" 'oifname "enp3s0" masquerade' "changing --ext-iface changes the MASQUERADE target"

# Fallback list: one masquerade per interface, in the given order.
EXT_IFACE=wg0,enp3s0
out3=$(server_conf)
assert_contains "$out3" 'postrouting oifname "wg0" masquerade; nft add rule inet wgft_server_wg_debian_vpn postrouting oifname "enp3s0" masquerade' "a comma-separated --ext-iface masquerades on every listed interface"
assert_not_contains "$out3" 'oifname "wg0,enp3s0"' "the list is split, never used as one interface name"

finish
