# WireGuard full-tunnel client + preserve inbound access on original IP

Goal: a Kubuntu PC routes ALL its traffic through a remote exit-node PC via
WireGuard, while still being reachable on its own current IP (e.g. for SSH)
from the outside.

## Architecture

- **Exit node** ("another pc") — runs the WireGuard server, does NAT/masquerade,
  all client traffic exits to the internet from here.
- **Kubuntu PC** (client) — routes `0.0.0.0/0` through the tunnel, but inbound
  connections to its original IP must keep working.

The tricky part isn't the tunnel itself — it's that once the Kubuntu PC's
default route points at `wg-debian-vpn`, *replies* to connections coming in on its real
interface (eth0) will also try to leave via `wg-debian-vpn`, breaking them. Policy
routing fixes that.

## 1. Generate keys first

Both configs below reference the *other* machine's public key, so generate
both keypairs before writing either config:

```
umask 077
wg genkey | tee /etc/wireguard/wg-debian-vpn_private.key | wg pubkey > /etc/wireguard/wg-debian-vpn_public.key
cat /etc/wireguard/wg-debian-vpn_public.key
```

Run this on both the exit node and the Kubuntu PC, then exchange the two
printed public keys — server's pubkey goes into the client's `[Peer]`
section, client's pubkey goes into the server's `[Peer]` section.

## 2. Exit node (server)

nftables' `add` is idempotent (safe to rerun) but has no equivalent of
iptables' `-D` ("delete by restating the exact match spec"), so the
persistent hook chains are created once, up front, and PostUp/PostDown only
ever add rules into them / flush them empty again — that's what keeps
PostDown a clean mirror of PostUp without needing per-rule handles:

```
sudo nft add table inet wg_debian_vpn_server
sudo nft add chain inet wg_debian_vpn_server forward '{ type filter hook forward priority filter; policy accept; }'
sudo nft add chain inet wg_debian_vpn_server postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
```

```
# /etc/wireguard/wg-debian-vpn.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <server_private_key>
PostUp   = nft add rule inet wg_debian_vpn_server forward iifname "wg-debian-vpn" accept; nft add rule inet wg_debian_vpn_server forward oifname "wg-debian-vpn" accept; nft add rule inet wg_debian_vpn_server postrouting oifname "eth0" masquerade
PostDown = nft flush chain inet wg_debian_vpn_server forward; nft flush chain inet wg_debian_vpn_server postrouting

[Peer]
PublicKey = <client_public_key>
AllowedIPs = 10.0.0.2/32
```

Enable forwarding:
```
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
```
Open UDP 51820 in the firewall, then `sudo systemctl enable --now wg-quick@wg-debian-vpn`.

Because this is an `inet` table, both rules above already match IPv6
packets too — that's why section 6B below needs no separate IPv6
FORWARD/MASQUERADE rules on the server, unlike an iptables/ip6tables split.

## 3. Kubuntu PC (client)

Use `wg-quick` (not the KDE NetworkManager GUI) — you need `PostUp`/`PostDown`
hooks that the GUI doesn't expose.

Same idempotent-base-chain pattern as the server (see the note at the top of
section 2). Create all three of the client's chains once, up front — `mangle_pre`
and `mangle_out` are used below; `dns_out` is used in section 5, but it's
harmless to create now even if you skip DNS-leak protection (an empty
`policy accept` chain does nothing):

```
sudo nft add table inet wg_debian_vpn_client
sudo nft add chain inet wg_debian_vpn_client mangle_pre '{ type filter hook prerouting priority mangle; policy accept; }'
sudo nft add chain inet wg_debian_vpn_client mangle_out '{ type filter hook output priority mangle; policy accept; }'
sudo nft add chain inet wg_debian_vpn_client dns_out '{ type filter hook output priority filter; policy accept; }'
```

```
# /etc/wireguard/wg-debian-vpn.conf
[Interface]
PrivateKey = <client_private_key>
Address = 10.0.0.2/24
DNS = 1.1.1.1

# --- preserve access to this box's real IP ---
PostUp   = ip rule add fwmark 100 table 100 priority 100
PostUp   = ip route add default via %i-orig-gw table 100
PostUp   = ip route add %i-orig-subnet dev eth0 table 100
PostUp   = nft add rule inet wg_debian_vpn_client mangle_pre iifname "eth0" ct mark set 100
PostUp   = nft add rule inet wg_debian_vpn_client mangle_out meta mark set ct mark
PostDown = ip rule del fwmark 100 table 100 priority 100
PostDown = ip route del default via %i-orig-gw table 100
PostDown = ip route del %i-orig-subnet dev eth0 table 100
PostDown = nft flush chain inet wg_debian_vpn_client mangle_pre
PostDown = nft flush chain inet wg_debian_vpn_client mangle_out

[Peer]
PublicKey = <server_public_key>
Endpoint = <server_public_ip>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Replace `eth0` with the real interface name, `%i-orig-gw` with the actual
original gateway (`ip route show default` before enabling WireGuard tells you
this, e.g. `192.168.1.1`), and `%i-orig-subnet` with `eth0`'s own connected
subnet (`ip route show dev eth0 scope link`, e.g. `192.168.1.0/24`).

**The `%i-orig-subnet` route is not optional either**, and it's easy to miss
since it only breaks a specific case: without it, table `100` has only a
`default via <gateway>` route, so a reply to another host on `eth0`'s *own*
LAN segment (not just remote connections) gets sent indirectly via the
gateway instead of directly on the LAN — `main`'s correct, more specific
connected-subnet route is never reached, because table `100`'s lookup
already produced a route (the default one) and rule evaluation stops there.
Depending on the router, that indirect same-subnet path may just fail
outright (no hairpinning). Symptom: a peer on the same LAN as the client
loses SSH access to it while the tunnel is up, even though a different,
genuinely remote connection (or the WireGuard tunnel address itself) stays
reachable.

**What this does:** any connection that arrives on `eth0` gets its
connection-tracking mark set to `100`; replies on that connection get that
mark restored, and a separate routing table (`100`) sends anything marked
`100` back out via the original gateway/interface instead of through `wg-debian-vpn`.
This means *any* inbound connection to the box's current IP (SSH, etc., from
anywhere) keeps working, regardless of who connects, while all
locally-initiated outbound traffic still goes through the tunnel via the
normal default route.

**The `priority 100` is not optional.** Without an explicit priority, a new
`ip rule` can land at the same or a later priority than the pre-existing
`main` rule (priority `32766`, check with `ip rule show`). Rules are
evaluated in priority order, and once a rule's table lookup succeeds,
evaluation stops — so if `main` (which now has a default route via `wg-debian-vpn`
too, thanks to wg-quick's own override) gets checked first, table `100` is
never actually consulted, silently defeating this whole mechanism while
`ip route show table 100` still looks correct on its own. Verify the real
behavior with:
```
ip route get 1.1.1.1 mark 100
```
which must show `dev eth0` (the original interface), not `dev wg-debian-vpn`.

`wg-quick` also automatically adds a host route for the WireGuard `Endpoint`
IP via the original gateway, so the tunnel's own handshake traffic doesn't try
to route itself through itself — no manual handling needed for that part.

## 4. Bring it up safely

Since this is a remote box, don't just `wg-quick up wg-debian-vpn` and hope:

```
sudo at now + 5 minutes <<< "wg-quick down wg-debian-vpn"
sudo wg-quick up wg-debian-vpn
# test SSH from a fresh connection now
```
If the new SSH session works, cancel the `at` job (`atq` / `atrm <job>`). If
it doesn't, the scheduled `down` will revert it and the existing session
should recover.

Enable persistently once confirmed: `sudo systemctl enable wg-quick@wg-debian-vpn`.

## 5. DNS-leak prevention

Even with a full-tunnel default route, DNS queries can still leak out the
original interface if the resolver isn't pinned to the tunnel — e.g. if
systemd-resolved keeps using the LAN's DHCP-provided nameserver for some or
all lookups.

1. On a modern Ubuntu/Debian system, `systemd-resolved` is already running
   and `wg-quick` talks to it directly via `resolvectl` — no extra package
   needed. (`openresolv`/`resolvconf` is only relevant as a fallback on
   systems *without* systemd-resolved; don't install it otherwise, since it
   can conflict with the systemd-resolved integration.)
2. `DNS = 10.0.0.1` (or `1.1.1.1`, or the exit node's own resolver) in the
   client's `[Interface]` section — already set above.
3. After `wg-quick up wg-debian-vpn`, verify wg-debian-vpn is the *default route* for DNS, not
   just an additional resolver:
   ```
   resolvectl status wg-debian-vpn
   ```
   Look for the assigned DNS server and `DNS Domain: ~.` (the wildcard domain
   marks wg-debian-vpn as catching all lookups, not just its own domain). If `~.` is
   missing, force it:
   ```
   PostUp = resolvectl domain %i "~."
   ```
4. Belt-and-braces kill switch — block any DNS (port 53) leaving via an
   interface other than wg-debian-vpn, except the mark-100 traffic used for
   preserving inbound access. This uses the `dns_out` chain created in
   section 3.

   **Add the exceptions before the reject lines.** nft evaluates a chain
   top-to-bottom, and `nft add rule` appends to the *end* of the chain — so
   whichever rule is added first is checked first. That's the opposite of
   iptables' `-I`, which prepends (there, the exception had to be inserted
   *after* the rejects so it would land above them); here it's the other
   way round:
   ```
   PostUp   = nft add rule inet wg_debian_vpn_client dns_out ip daddr <dns_server_ip> udp dport 53 accept
   PostUp   = nft add rule inet wg_debian_vpn_client dns_out ip daddr <dns_server_ip> tcp dport 53 accept
   PostUp   = nft add rule inet wg_debian_vpn_client dns_out oifname != "wg-debian-vpn" ip daddr != 127.0.0.0/8 meta mark != 100 udp dport 53 reject
   PostUp   = nft add rule inet wg_debian_vpn_client dns_out oifname != "wg-debian-vpn" ip daddr != 127.0.0.0/8 meta mark != 100 tcp dport 53 reject
   PostDown = nft flush chain inet wg_debian_vpn_client dns_out
   ```
   **The `ip daddr != 127.0.0.0/8` is required.** Without it, this also
   rejects the local app → `127.0.0.53` query (systemd-resolved's stub
   listener), since loopback traffic goes out via `lo`, which is "not
   wg-debian-vpn" too — breaking *all* DNS resolution inside the tunnel
   (every hostname lookup fails), not just genuine leaks.

   **If your `DNS =` server is on a directly-connected subnet** (e.g. your
   LAN gateway, not a public resolver reached through the tunnel), the two
   `ip daddr <dns_server_ip> ... accept` lines above are exactly that
   exception, and they're required: a connected subnet route (e.g. a `/24`
   for your LAN) always beats the tunnel's `/1` override routes, so queries
   to a LAN-local resolver correctly go out the LAN interface directly, not
   through the tunnel — but that means they're "not wg-debian-vpn" and
   unmarked, so without this exception the kill switch rejects its own
   upstream resolver too, breaking every hostname lookup.
5. Confirm with a DNS-leak test (browser-based test site, or `dig` against a
   known resolver and check which source IP the server sees).

## 6. IPv6 handling

**A. No outbound IPv6 needed (simplest, safest):** disable IPv6 entirely so
it can't bypass the tunnel:
```
# /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
```
```
sudo sysctl --system
```
This removes the leak vector outright — there's no IPv6 stack left to route
around the tunnel.

**B. Real IPv6 needed (tunneled, and still reachable on its own public
IPv6):**

1. Give the client an IPv6 address on the WireGuard interface:
   ```
   Address = 10.0.0.2/24, fd42:42:42::2/64
   ```
   `AllowedIPs = 0.0.0.0/0, ::/0` (already set) tunnels it.
2. On the exit node, enable IPv6 forwarding:
   ```
   net.ipv6.conf.all.forwarding = 1
   ```
   No new firewall rule needed here: the `forward`/`postrouting` chains from
   section 2 live in an `inet` table, so the `accept`/`masquerade` rules
   already there match IPv6 packets too — unlike an iptables/ip6tables
   split, which would need a duplicate rule set for this.
3. Mirror the inbound-access *policy routing* for IPv6 on the client, so
   inbound IPv6 connections to the box's real public IPv6 also survive.
   `ip rule`/`ip route` are genuinely separate IPv4/IPv6 stacks in the
   kernel, so this half still needs a real `-6` mirror — but the
   CONNMARK-equivalent rules do **not**: the `mangle_pre`/`mangle_out` rules
   from section 3 are already in the same `inet` table and match IPv6
   packets arriving on `eth0` automatically, with nothing extra to add.
   ```
   PostUp   = ip -6 rule add fwmark 100 table 100 priority 100
   PostUp   = ip -6 route add default via <original_ipv6_gateway> dev eth0 table 100
   PostDown = ip -6 rule del fwmark 100 table 100 priority 100
   PostDown = ip -6 route del default via <original_ipv6_gateway> dev eth0 table 100
   ```
   Find `<original_ipv6_gateway>` with `ip -6 route show default` (often a
   link-local `fe80::...` address) before enabling WireGuard.
4. Test: `curl -6 https://ifconfig.co` from the box should show the exit
   node's IPv6, and an external `ping6`/SSH to the box's real IPv6 should
   still work.
