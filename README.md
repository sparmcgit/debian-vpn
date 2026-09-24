# wg-fulltunnel

Sets up a full-tunnel WireGuard VPN: a Kubuntu (or other Debian-based)
client routes **all** of its traffic through a remote exit-node server,
while staying reachable on its own original IP (e.g. for SSH) via policy
routing — so a remote box doesn't lock you out when it becomes its own
default route.

See [`implement.md`](implement.md) for the full design write-up (why the
routing loopback problem exists, DNS-leak prevention, IPv6 handling).

## Usage

Both roles require the *other* machine's public key up front, so generate
keys first.

**1. On each machine, generate a keypair:**
```
sudo ./wg-fulltunnel.sh --keygen --iface wg-debian-vpn
```
This prints that machine's public key. Exchange the two — server's pubkey
goes to the client, client's pubkey goes to the server.

**2. On the exit-node server:**
```
sudo ./wg-fulltunnel.sh --role server \
  --wg-address 10.0.0.1/24 \
  --peer-pubkey <client_public_key> \
  --peer-allowed-ips 10.0.0.2/32
```
(reuses the key generated in step 1, doesn't make a new one)

**3. On the client:**
```
sudo ./wg-fulltunnel.sh --role client \
  --wg-address 10.0.0.2/24 \
  --peer-pubkey <server_public_key> \
  --endpoint <server_public_ip>:51820
```

Add `--dry-run` to either command first to see exactly what would change
without touching the system.

### Config files

Instead of long command lines, use `--config FILE`:
```
./wg-fulltunnel.sh --config-example > wg-debian-vpn.conf   # generate a template
# edit wg-debian-vpn.conf
sudo ./wg-fulltunnel.sh --config wg-debian-vpn.conf --dry-run
```
Flags given directly on the command line always override the config file.

### Safety net (client only)

Before bringing the tunnel up, an automatic rollback is scheduled for
`--revert-after` minutes (default 5). From a **new** connection to the box's
original IP, confirm the change worked:
```
sudo ./wg-fulltunnel.sh --confirm-revert --iface wg-debian-vpn
```
If you don't confirm in time, or the script's own post-up checks fail, it
reverts itself automatically. Other useful commands:
```
sudo ./wg-fulltunnel.sh --rollback --iface wg-debian-vpn   # undo manually
sudo ./wg-fulltunnel.sh --status   --iface wg-debian-vpn   # inspect current state
```

### Turning it on/off day-to-day

Once a setup is confirmed and working, use `--disable`/`--enable` as a plain
toggle — no watchdog, no re-validation, just stop/start:
```
sudo ./wg-fulltunnel.sh --disable --iface wg-debian-vpn   # stop now, don't start on boot
sudo ./wg-fulltunnel.sh --enable  --iface wg-debian-vpn   # start again, re-enable on boot
```

Full flag reference: `./wg-fulltunnel.sh --help`.

## Testing

```
bash tests/run.sh
```
Runs the unit tests (no root needed) plus integration tests that exercise
the real script — including real `nft`/`ip` execution — inside an isolated,
throwaway network namespace (`unshare --user --map-root-user --net`), with
`wg`/`wg-quick`/`systemctl`/`curl`/`ufw` mocked. No `sudo` needed and nothing on
your real system is touched; the integration tier just skips itself (with a
message, not a failure) if unprivileged user namespaces aren't available,
or if `nft` itself isn't installed — it's deliberately not mocked, since
verifying real rule state is the point.

A common reason for the userns skip on a hardened server: newer Ubuntu's
AppArmor `unprivileged_userns` profile blocking it by default (visible in
`dmesg` as `apparmor="DENIED" ... profile="unprivileged_userns"
comm="unshare"`). That's an intentional security setting, not a bug —
don't disable it just to get integration coverage; the unit tests still
run and cover the generated config/nft logic on their own.

## Requirements

`wireguard-tools`, `nftables`, `ip` (iproute2), `curl`, and `systemd`
(DNS handling uses `resolvectl`, part of systemd-resolved — no separate
package needed on a modern Ubuntu/Debian system). The script checks for
these and tells you what's missing.
