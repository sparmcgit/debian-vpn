# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single-script WireGuard setup tool (`wg-fulltunnel.sh`) plus its design doc
(`implement.md`). It configures a full-tunnel WireGuard client (a Kubuntu box
routing all traffic through a remote exit node) and the corresponding exit
node server, while preserving the client's reachability on its own original
IP for inbound connections (e.g. SSH) — the tricky part `implement.md`
explains under "the routing loopback problem".

There is no build system or package manifest. There is a test suite
(`tests/`, see below); also validate changes with:

```
bash -n wg-fulltunnel.sh   # syntax check
sudo ./wg-fulltunnel.sh --config-example   # inspect generated defaults
sudo ./wg-fulltunnel.sh --role <server|client> ... --dry-run   # exercise a flow with no system changes
```

`--dry-run` requires root even though it changes nothing, because it reads
live routing/firewall state to report accurately — keep this in mind if
adding new inspection logic.

## Test suite (`tests/`)

`tests/run.sh` runs everything: `tests/unit/*.sh` (pure function/string
checks against `client_conf()`/`server_conf()`/`parse_args()`/etc., no root
needed) and `tests/integration/*.sh` (runs the real script end-to-end,
including real `nft`/`ip` execution, inside an isolated
`unshare --user --map-root-user --net` sandbox — real root and a throwaway
network stack with no risk to the host, auto-cleaned on exit). Integration
tests mock `wg`/`wg-quick`/`systemctl`/`systemd-run`/`sysctl`/`curl`/
`resolvectl` (see `tests/lib/mockbin/`) since there's no real WireGuard peer
or systemd instance to talk to. `ufw` is mocked too, for a different reason:
the real binary, run for real if it happens to be installed on whatever
machine the tests run on, tries to read `/etc/ufw/*` as "root" — but
`unshare --map-root-user` only maps one UID to 0, so real-root-owned host
files have no mapping and appear owned by the overflow UID, which `ufw`'s
own sanity checks complain very loudly about (real files, real permission
denials, all harmless since `ensure_ufw_port()` just falls back to
"inactive" either way — but noisy enough to look like something's wrong
when it isn't). The mock `wg-quick`/`systemctl` shims
actually extract and execute the real `PostUp`/`PostDown` line from the
generated conf via `tests/lib/mockbin/_apply.sh`, so the real nft/ip state
this produces is genuinely verified, not just the string that generated it.

This relies on the small `: "${VAR:=default}"` overrides at the top of
`wg-fulltunnel.sh` (`CONF_DIR`, `LOG_FILE`, `WATCHDOG_STATE_DIR`,
`LOCK_FILE`, `SYSCTL_DIR`) — real invocations are unaffected since nothing
normally sets those env vars, but tests point them at a scratch directory
instead of the real `/etc/wireguard` etc. Keep every hardcoded absolute
path routed through one of these (or a new one, added the same way) rather
than reintroducing a literal path, or the test suite silently starts
touching the real filesystem again.

Integration tests auto-skip (with a message, not a failure) if
unprivileged user namespaces aren't available, or if `nft` itself isn't
installed (checked against `/usr/sbin:/usr/bin:/sbin:/bin` directly in
`tests/run.sh`, not just the caller's `$PATH` — `/usr/sbin` commonly isn't
on a normal user's PATH even when `nft` is right there, which is a real
false-skip bug this was fixed from once already).

Confirmed cause of the userns skip in the field: AppArmor's
`unprivileged_userns` profile denying `unshare` the `sys_admin` capability
— visible in `dmesg`/`journalctl -k` as `apparmor="DENIED"
operation="capable" ... profile="unprivileged_userns" comm="unshare"
capability=21 capname="sys_admin"`. This is a real hardening feature on
newer Ubuntu (the `kernel.apparmor_restrict_unprivileged_userns` sysctl),
not a misconfiguration — don't "fix" it by disabling it just to get
integration coverage on a given box; unit tests still run and cover the
generated nft/config logic, and treat the integration tier as
best-effort per-machine.

## Architecture

Everything lives in `wg-fulltunnel.sh`, dispatched by `--role server|client`
or a standalone `ACTION` (`rollback`, `confirm-revert`, `status`, `keygen`).
The same script is meant to be copied to and run once on each machine
(server and client), not orchestrated remotely from one place.

Both roles require the *other* machine's public key via `--peer-pubkey`, so
there's a bootstrap step before either can run: `--keygen` (`do_keygen()`)
just calls `ensure_keys()` and prints the public key, with none of the
role-specific requirements. `ensure_keys()` is idempotent (reuses an
existing keypair rather than regenerating), so running `--keygen` first and
then `--role server`/`--role client` later reuses the same key. Don't add a
new required flag to `setup_server()`/`setup_client()` without checking
whether `--keygen` needs to stay exempt from it.

Key mechanisms, in the order the client flow actually needs them:

- **`run()` wrapper** — every mutating shell command goes through this so
  `--dry-run` can intercept it uniformly. File writes go through
  `write_file()` / `backup_file()` instead, which timestamp-back up any file
  they'd overwrite (`*.conf.bak.<timestamp>`).
- **Config generation** (`server_conf()` / `client_conf()`) — builds the
  `wg-quick`-style `.conf` content as a string, embedding the PostUp/PostDown
  shell commands directly (with variables already substituted, not left as
  `%i` for wg-quick to expand). The client's PostUp/PostDown pair is
  symmetric by construction: whatever ip rule/route state PostUp adds,
  PostDown removes, and whatever nft rules PostUp adds, PostDown flushes —
  this is what makes `--rollback` simple (see `do_rollback()`, which is
  mostly just `wg-quick down`).
- **nft base chains** (`ensure_nft_server_base()` / `ensure_nft_client_base()`,
  called once during setup, before the PostUp lines they support ever run) —
  unlike `iptables -D` (delete by restating the exact match spec), nft has no
  "delete by spec" at all, so PostDown can't mirror PostUp rule-for-rule the
  way an iptables-based version could. The fix: create the `inet` table and
  its hooked chains once (idempotent — adding an already-identical
  table/chain is a no-op, not an error), have PostUp only ever `nft add
  rule` into them, and have PostDown just `nft flush chain` them empty again
  — symmetric without needing per-rule handles. `ensure_*_base()` also
  flushes every chain up front (not just relying on PostDown having run), so
  a rerun, or a crash that skipped PostDown, always starts from a clean
  chain instead of silently accumulating duplicate rules. The client's
  `dns_out` chain is created unconditionally even when
  `--no-dns-leak-protect` is given — a hooked chain keeps filtering
  regardless of whether we're currently populating it, so a stale rule left
  over from a previous run *with* protection enabled would otherwise survive
  a rerun with it disabled. Chain/table names are derived from `--iface` via
  `nft_tag()` — nft identifiers are stricter than interface names (the
  default `wg-debian-vpn` contains a hyphen).
  PostUp *also* re-creates (and flushes) its own table/chains before adding
  rules — don't drop that as redundant with `ensure_*_base()`. nft state
  isn't persisted across reboots, and the boot-time `wg-quick@` unit runs
  PostUp without the setup script, so a PostUp that only does `nft add
  rule` fails on the missing table and wg-quick aborts the whole interface.
  This happened in the field: a server reboot silently killed the tunnel.
  The "simulated reboot" checks in the integration tests cover it.
  Using `inet` (not separate `ip`/`ip6` tables) is also why `--ipv6` needs no
  duplicate firewall rules on the server or for the client's CONNMARK
  equivalent — an `inet` table's rules match both IPv4 and IPv6 packets by
  default. Only `ip rule`/`ip route` still need a real `-6` mirror in
  `client_conf()`, since those are genuinely separate v4/v6 kernel stacks
  regardless of firewall backend.
- **Preserve-inbound-access routing** — the client's PostUp marks packets
  arriving on the original management interface (`CONNMARK`) and routes
  their replies back out the original gateway via a separate table
  (`--mark`/`--table`, default 100/100), so setting the WireGuard interface
  as the default route doesn't break inbound SSH etc. This is the load-
  bearing trick in the whole design — see `implement.md` for the full
  rationale before changing it. The `ip rule add ... priority ${TABLE}` on
  this rule is not cosmetic: without an explicit priority the rule can land
  at the same or a later priority than the pre-existing `main` rule
  (32766), so `main`'s now-hijacked default route matches first and table
  `${TABLE}` is silently never consulted — this actually happened in the
  field (a `--dry-run`-free run that got as far as `wg-quick up` broke SSH
  access even though `ip route show table 100` looked fine, because that
  check alone doesn't prove marked packets are routed there). This is why
  `validate_client()` checks `ip route get 1.1.1.1 mark $MARK` for the
  actual egress device instead of just checking table `$TABLE` has *a*
  route.
- **DNS-leak kill switch needs `ip daddr != 127.0.0.0/8`.** The `reject`
  rules for non-tunnel port-53 traffic (`client_conf()`'s `dns_out` chain,
  `DNS_LEAK_PROTECT`) match on output interface, and loopback queries to
  `127.0.0.53` (systemd-resolved's stub) go out via `lo` — "not `$IFACE`" is
  true for `lo` too, so without this exemption the kill switch blocks *all*
  local DNS resolution, not just leaks. This one cost a long debugging
  session: `validate_client()`'s `curl https://ifconfig.co` check needs DNS
  to resolve the hostname first, so this bug alone produced the exact same
  "outbound connectivity failed" symptom as an actually-broken NAT/forwarding
  path on the server, with no way to tell them apart from the validation
  failure alone. If touching these rules again, test hostname resolution
  (`dig`/`curl` with a hostname, not just an IP) specifically, not just raw
  IP reachability.

  Second layer of the same bug: an explicit `accept` for `ip daddr
  ${DNS_SERVER}` is also needed, added to `dns_out` *before* the `reject`
  lines. nft evaluates a chain top-to-bottom and `nft add rule` appends to
  the end, so whichever gets added first is checked first — the opposite of
  iptables' `-I` (which prepends), which is why an iptables-based version of
  this needs the exception inserted *after* the rejects instead. If
  `DNS_SERVER` sits on a directly-connected subnet (e.g. the LAN gateway),
  the kernel correctly routes queries to it out the LAN interface rather
  than the tunnel — a connected `/24` always beats the tunnel's `/1`
  override routes — but that means "not `$IFACE`" and unmarked, so without
  this exception the kill switch rejects its own configured upstream
  resolver too.
- **Table `${TABLE}` needs the connected subnet route too, not just
  `default`** (`detect_mgmt_subnet()`, `client_conf()`). Since our rule
  (priority `${TABLE}`) is consulted before `main` for marked packets, a
  reply to another host on `${MGMT_IFACE}`'s own LAN segment would match
  table `${TABLE}`'s `default via <gateway>` entry and get sent indirectly
  via the gateway instead of directly on the LAN — `main`'s correct, more
  specific connected route is never reached, because table `${TABLE}`'s
  lookup already produced *a* route. This is the bug this whole project
  exists to prevent, and it slipped past every automated check because
  `validate_client()`'s `ip route get ... mark $MARK` test used a genuinely
  remote IP (`1.1.1.1`), which correctly hit the default route — the
  failure only showed up testing SSH from another host on the *same*
  subnet as the client. If touching this again, test same-subnet
  reachability specifically, not just a remote IP's route.
- **`validate_client()`'s curl check must force `-4`.** `wg-quick` adds a
  `::/0 dev $IFACE` route whenever `AllowedIPs` includes `::/0` regardless
  of whether IPv6 actually works over this tunnel (no IPv6 address is
  configured on the interface unless `--ipv6` was given) — so an
  unqualified `curl https://ifconfig.co` can have happy-eyeballs try that
  dead IPv6 path first and burn the whole `--max-time` before ever
  attempting IPv4, failing validation even though the tunnel is fine. This
  is exactly the kind of thing that passes a manual `curl -4 ...` test
  right after `wg-quick up` but still fails inside the script — if
  `validate_client()` and a manual check ever disagree again, diff the
  exact curl invocation first, don't assume the tunnel state changed.
- **A foreign forward-hook `policy drop` beats our `accept`.** In nft a
  drop in any hooked chain is final, so another table's kill switch
  silently eats forwarded client traffic while `wg show`, our table and
  `ip_forward` all look correct. Seen in the field: a third-party VPN
  client auto-connected after a server reboot and its kill switch took
  over. `setup_server()` only warns (`warn_foreign_forward_drop()`); the
  client side reports it via
  `diagnose_client_failure()`'s "handshake OK but raw IP unreachable" line.
- **Client watchdog** (`schedule_watchdog()` / `cancel_watchdog()`) — an
  auto-rollback is scheduled *before* `wg-quick up` runs, via `systemd-run`
  (falling back to `at`, then a detached `nohup sleep`). It only gets
  cancelled by `--confirm-revert` (meant to be run from a fresh connection
  proving the box is still reachable) or, with `--yes`, by the script's own
  post-up `validate_client()` check succeeding. Any change to the up/down
  flow must keep the watchdog scheduled first, so a mid-script crash still
  self-heals.
- **Config file loading** (`prescan_config()` → `parse_config_file()` →
  `parse_args()`) — `--config FILE` is pulled out of argv wherever it
  appears, turned into a synthetic `--flag value` argument list, then
  prepended to the real argv before the normal parser runs — so explicit
  CLI flags always win. `BOOL_FLAGS` must stay in sync with which
  `parse_args` cases take no value (`shift` vs `shift 2`), since that list
  decides whether a config-file key expects `=true` or a value — this is
  checked by `tests/unit/test_bool_flags_sync.sh`, not just by eye.
- **`--config-example`** (`print_config_example()`) — must stay parseable by
  `parse_config_file()`; `tests/unit/test_config_example_roundtrip.sh`
  actually runs that round-trip now, so if you change the config format
  and forget to regenerate the example, the test suite catches it instead
  of only a manual eyeball check.

- **Rerunning `setup_client()` on an already-up interface.** `wg-quick up`
  refuses if the interface already exists — unlike `setup_server()`, which
  handles a rerun via `systemctl restart` on an already-active unit,
  `wg-quick` has no reconfigure-in-place. `setup_client()` checks `wg show
  "$IFACE"` and runs `wg-quick down "$IFACE"` first if it's already up —
  and does this *before* `write_file()` overwrites `$conf`, so the `down`
  still runs the currently-loaded PostDown (matching whatever's actually
  applied) rather than a freshly-regenerated one that might disagree with
  it (e.g. if `--mgmt-iface` changed between runs). Found this the hard way:
  a rerun with identical flags failed at `wg-quick up` with `` `wg-debian-vpn'
  already exists `` and left a 5-minute watchdog armed against the
  still-live *previous* tunnel — cancel it with `--confirm-revert` if this
  happens without the fix in place.

When adding a new flag: add it to `parse_args()`, add it to `usage()`, and if
it takes no value add it to `BOOL_FLAGS` — missing any one of these breaks
either `--help`, `--config`, or both silently.
