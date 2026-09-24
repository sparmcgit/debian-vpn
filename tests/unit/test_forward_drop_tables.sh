#!/usr/bin/env bash
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib/unit_helpers.sh"
source_wgft_functions "$HERE/../../wg-fulltunnel.sh"

# Trimmed from a real server's ruleset (a VPN kill switch + Docker + our own table).
ruleset='table ip filter {
	chain FORWARD {
		type filter hook forward priority filter; policy accept;
		iifname != "docker0" oifname "docker0" counter packets 0 bytes 0 drop
	}
}
table inet otherkill {
	chain output {
		type filter hook output priority filter; policy drop;
	}
	chain forward {
		type filter hook forward priority filter; policy drop;
		oif "wg0-other" ct mark 0x00000f41 drop
	}
}
table inet wgft_server_wg_debian_vpn {
	chain forward {
		type filter hook forward priority filter; policy drop;
	}
}'

out=$(forward_drop_tables "inet wgft_server_wg_debian_vpn" <<< "$ruleset")
assert_contains "$out" "inet otherkill" "flags a foreign table whose forward chain has policy drop"
assert_not_contains "$out" "ip filter" "ignores a forward chain with policy accept (even if it has drop rules)"
assert_not_contains "$out" "wgft_server" "never flags our own table"
out_empty=$(forward_drop_tables "inet wgft_server_wg_debian_vpn" <<< 'table inet otherkill {
	chain output {
		type filter hook output priority filter; policy drop;
	}
}')
[[ -z "$out_empty" ]] && ok "policy drop on a non-forward hook is not flagged" \
  || fail "expected nothing, got: $out_empty"

finish
