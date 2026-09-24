#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/unit_helpers.sh"
source_wgft_functions "$HERE/../../wg-fulltunnel.sh"

IFACE=wg-debian-vpn
MGMT_IFACE=enp4s0
ORIG_GW=192.168.2.1
MGMT_SUBNET=192.168.2.0/24
DNS_SERVER=192.168.2.1
MARK=100
TABLE=100
DNS_LEAK_PROTECT=1
IPV6=0
PEER_PUBKEY="<server_pubkey>"
ENDPOINT="203.0.113.5:51820"
ALLOWED_IPS="0.0.0.0/0, ::/0"
KEEPALIVE=25
PRIV_KEY="<client_private_key>"
WG_ADDRESS="10.0.0.2/24"

out=$(client_conf)

assert_contains "$out" "nft add rule inet wgft_client_wg_debian_vpn mangle_pre" "PostUp adds the mangle_pre CONNMARK-equivalent rule"
assert_contains "$out" "nft add rule inet wgft_client_wg_debian_vpn mangle_out" "PostUp adds the mangle_out restore-mark rule"
assert_before "$out" 'dns_out ip daddr 192.168.2.1 udp dport 53 accept' 'dns_out oifname != "wg-debian-vpn"' \
  "DNS-server accept exception is added before the catch-all reject (nft appends, so order-added = order-checked)"
assert_contains "$out" "ip daddr != 127.0.0.0/8" "loopback is exempted from the DNS-leak kill switch"
assert_not_contains "$out" "iptables" "no iptables commands remain in the generated conf"
assert_not_contains "$out" "ip6tables" "no ip6tables commands remain in the generated conf"
assert_contains "$out" "nft flush chain inet wgft_client_wg_debian_vpn mangle_pre" "PostDown flushes mangle_pre"
assert_contains "$out" "nft flush chain inet wgft_client_wg_debian_vpn mangle_out" "PostDown flushes mangle_out"
assert_contains "$out" "nft flush chain inet wgft_client_wg_debian_vpn dns_out" "PostDown flushes dns_out"
assert_contains "$out" 'ip rule add fwmark 100 table 100 priority 100' "policy-routing rule has an explicit priority"
assert_contains "$out" 'ip route add 192.168.2.0/24 dev enp4s0 table 100' "connected-subnet route is added to table 100"

# DNS-leak protection disabled: dns_out must never be touched by PostUp/PostDown.
DNS_LEAK_PROTECT=0
out_noprotect=$(client_conf)
assert_not_contains "$out_noprotect" "dns_out" "with --no-dns-leak-protect, PostUp/PostDown never reference dns_out"

# IPv6: policy routing is mirrored, but firewall/mark rules are not
# duplicated (inet table already matches both families).
DNS_LEAK_PROTECT=1
IPV6=1
ORIG_GW6="fe80::1"
out_v6=$(client_conf)
assert_contains "$out_v6" "ip -6 rule add fwmark 100 table 100 priority 100" "with --ipv6, ip -6 rule mirrors the v4 one"
assert_contains "$out_v6" "ip -6 route add default via fe80::1 dev enp4s0 table 100" "with --ipv6, ip -6 route mirrors the v4 one"
assert_not_contains "$out_v6" "ip6tables" "with --ipv6, no separate ip6tables CONNMARK rules (inet table already covers v6)"

finish
