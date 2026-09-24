#!/usr/bin/env bash
#
# Configures either side of the full-tunnel WireGuard setup described in
# implement.md: an exit-node server, or a client that routes all its traffic
# through it while staying reachable on its own original IP.
#
# Run once per machine with --role server or --role client. See --help.

set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f "$0")
# ":=" (not plain assignment) so the test suite can point these at a scratch
# directory via the environment; every real invocation leaves them at these
# same defaults since nothing normally sets the env vars.
: "${CONF_DIR:=/etc/wireguard}"
: "${LOG_FILE:=/var/log/wg-fulltunnel.log}"
: "${WATCHDOG_STATE_DIR:=/run/wg-fulltunnel}"
: "${LOCK_FILE:=/var/lock/wg-fulltunnel.lock}"
: "${SYSCTL_DIR:=/etc/sysctl.d}"

IFACE=wg-debian-vpn
ROLE=""
ACTION=setup
DRY_RUN=0
ASSUME_YES=0

WG_PORT=51820
WG_ADDRESS=""
EXT_IFACE=""
PEER_PUBKEY=""
PEER_ALLOWED_IPS=""      # server: client's tunnel IP, e.g. 10.0.0.2/32
ENDPOINT=""               # client: server_ip:port
ALLOWED_IPS="0.0.0.0/0, ::/0"
DNS_SERVER="1.1.1.1"
KEEPALIVE=25
MARK=100
TABLE=100
MGMT_IFACE=""
MGMT_SUBNET=""
ORIG_GW=""
ORIG_GW6=""
REVERT_AFTER=5
DNS_LEAK_PROTECT=1
IPV6=0
DISABLE_IPV6=0
CONFIG_FILE=""

# Flags that take no value — must match parse_args' zero-shift cases exactly.
BOOL_FLAGS=(rollback confirm-revert status keygen disable enable dry-run yes no-dns-leak-protect ipv6 disable-ipv6 help)

usage() {
  cat <<'EOF'
wg-fulltunnel.sh --keygen --iface <name>
wg-fulltunnel.sh --role server|client [options]
wg-fulltunnel.sh --rollback --iface <name>
wg-fulltunnel.sh --confirm-revert --iface <name>
wg-fulltunnel.sh --disable --iface <name>
wg-fulltunnel.sh --enable --iface <name>
wg-fulltunnel.sh --status --iface <name>

Bootstrapping (--peer-pubkey is required by both roles, so generate keys
and exchange public keys BEFORE running full setup):
  1. On each machine:  sudo wg-fulltunnel.sh --keygen --iface wg-debian-vpn
  2. Give the server's printed pubkey to the client's --peer-pubkey, and
     the client's printed pubkey to the server's --peer-pubkey.
  3. Then run --role server / --role client as normal — the keys generated
     in step 1 are reused, not regenerated.

Common:
  --config FILE           Load flag values from FILE (see format below)
  --config-example        Print an example config file to stdout and exit
  --keygen                Generate (or reuse) this machine's keypair, print
                           its public key, and exit — no peer info needed
  --iface NAME            WireGuard interface name (default: wg-debian-vpn)
  --disable               Stop the tunnel now and don't start it on boot
                           (for an already-confirmed, working setup — no
                           watchdog/validation, just a plain on/off switch)
  --enable                Start the tunnel and re-enable it on boot
  --dry-run               Print every action, change nothing
  --yes                   Assume yes to prompts / auto-confirm after validation
  -h, --help              This help

Server role:
  --wg-address CIDR       Tunnel address, e.g. 10.0.0.1/24 (required)
  --wg-port PORT          Listen port (default: 51820)
  --ext-iface LIST        Interface to NAT client traffic out of, or a
                          comma-separated list of interfaces, e.g. "eth0" or
                          "wg0,eth0" (default: auto-detect one). With a list,
                          routing picks the exit and the others act as
                          fallback: "wg0,eth0" goes out another VPN's wg0
                          while it's up and routes there, and out eth0 when
                          it's down
  --peer-pubkey KEY       Client's public key (required)
  --peer-allowed-ips CIDR Client's tunnel IP, e.g. 10.0.0.2/32 (required)
  --ipv6                  Also set up IPv6 forwarding/NAT

Client role:
  --wg-address CIDR       Tunnel address, e.g. 10.0.0.2/24 (required)
  --peer-pubkey KEY       Server's public key (required)
  --endpoint HOST:PORT    Server's public endpoint (required)
  --allowed-ips LIST      Default: "0.0.0.0/0, ::/0" (full tunnel)
  --dns IP                Tunnel DNS server (default: 1.1.1.1)
  --keepalive SECONDS     PersistentKeepalive (default: 25)
  --mgmt-iface NAME       Original LAN/WAN interface (default: auto-detect)
  --mgmt-gateway IP       Original default gateway (default: auto-detect)
  --mgmt-subnet CIDR      Mgmt interface's connected subnet (default: auto-detect;
                           needed so same-subnet inbound access also survives)
  --mark N / --table N    fwmark and routing table for preserved access (100)
  --revert-after MINUTES  Auto-rollback delay if not confirmed (default: 5, 0=off)
  --no-dns-leak-protect   Skip the DNS kill-switch nft rules
  --ipv6                  Also preserve inbound IPv6 access + tunnel IPv6
  --disable-ipv6          Instead: just disable IPv6 entirely (leak-safe, simplest)

Client safety model:
  A watchdog is scheduled BEFORE the tunnel is brought up. If you don't run
  --confirm-revert within --revert-after minutes (from a NEW connection, to
  prove the box is still reachable on its original IP), the change is
  reverted automatically. With --yes, successful automated local validation
  confirms immediately instead of waiting for you.

Config file format (--config FILE):
  One "key=value" per line, key is a long option name without the leading
  "--" (e.g. "wg-address=10.0.0.2/24"). Blank lines and lines starting with
  # are ignored. For no-value flags (dry-run, yes, ipv6, disable-ipv6,
  no-dns-leak-protect, rollback, confirm-revert, status), use
  "flagname=true" to enable it; omit or set "=false" to leave it off.
  Values on the actual command line always override the config file,
  regardless of where --config appears among the other flags.

  Example:
    role=client
    wg-address=10.0.0.2/24
    peer-pubkey=abcd...=
    endpoint=203.0.113.5:51820
    revert-after=10
    ipv6=true
EOF
}

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true
  echo "$*" >&2
}

err_exit() {
  log "ERROR: $*"
  exit 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# nft table/chain names are stricter than interface names (e.g. IFACE
# defaults to "wg-debian-vpn", which contains a hyphen) — sanitize before
# using a name as part of an nft object identifier.
nft_tag() { local s="$1"; s="${s//[!A-Za-z0-9_]/_}"; printf '%s' "$s"; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
    return 0
  fi
  log "RUN: $*"
  "$@"
}

write_file() {
  local path=$1 content=$2 mode=${3:-644}
  if [[ -f $path ]]; then
    backup_file "$path"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] would write $path (mode $mode):"
    echo "---"
    printf '%s\n' "$content"
    echo "---"
  else
    printf '%s\n' "$content" > "$path"
    chmod "$mode" "$path"
    log "wrote $path"
  fi
}

backup_file() {
  local path=$1
  local dest="${path}.bak.$(date +%Y%m%d%H%M%S)"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] would back up $path -> $dest"
  else
    cp -a "$path" "$dest"
    log "backed up $path -> $dest"
  fi
}

require_root() {
  [[ $EUID -eq 0 ]] || err_exit "must run as root (sudo) — even --dry-run, since it inspects live routes/firewall state"
}

check_deps() {
  local missing=() c
  for c in ip nft wg wg-quick systemctl sysctl curl; do
    have_cmd "$c" || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err_exit "missing commands: ${missing[*]} — try: apt update && apt install -y wireguard nftables curl"
  fi
}

confirm_or_abort() {
  [[ $DRY_RUN -eq 1 || $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || err_exit "aborted by user"
}

detect_default_route() {
  if [[ -z "$MGMT_IFACE" || -z "$ORIG_GW" ]]; then
    local line
    line=$(ip route show default 2>/dev/null | head -1)
    [[ -z "$MGMT_IFACE" ]] && MGMT_IFACE=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$line")
    [[ -z "$ORIG_GW" ]] && ORIG_GW=$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$line")
  fi
}

detect_mgmt_subnet() {
  [[ -n "$MGMT_SUBNET" ]] && return
  MGMT_SUBNET=$(ip -4 route show dev "$MGMT_IFACE" scope link 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -z "$MGMT_SUBNET" ]]; then
    log "WARNING: could not detect a connected subnet for ${MGMT_IFACE}; same-subnet inbound connections (other than the WireGuard endpoint itself) may not survive. Pass --mgmt-subnet explicitly if this matters for you."
  fi
}

detect_default_route6() {
  if [[ -z "$ORIG_GW6" ]]; then
    local line
    line=$(ip -6 route show default 2>/dev/null | head -1)
    ORIG_GW6=$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$line")
  fi
}

ensure_keys() {
  local priv="$CONF_DIR/${IFACE}_private.key" pub="$CONF_DIR/${IFACE}_public.key"
  if [[ -f "$priv" && -f "$pub" ]]; then
    PRIV_KEY=$(cat "$priv"); PUB_KEY=$(cat "$pub")
    log "using existing keypair $priv"
    return
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] would generate a new keypair at $priv / $pub"
    PRIV_KEY="<generated-private-key>"; PUB_KEY="<generated-public-key>"
    return
  fi
  ( umask 077; wg genkey | tee "$priv" | wg pubkey > "$pub" )
  chmod 600 "$priv"
  PRIV_KEY=$(cat "$priv"); PUB_KEY=$(cat "$pub")
  log "generated new keypair $priv"
}

mkdir_conf_dir() {
  if [[ -d "$CONF_DIR" ]]; then
    log "$CONF_DIR already exists, leaving its contents alone"
  else
    run mkdir -p "$CONF_DIR"
  fi
  run chmod 700 "$CONF_DIR"
}

write_sysctl() {
  local content="net.ipv4.ip_forward=1"
  [[ $IPV6 -eq 1 ]] && content+=$'\n'"net.ipv6.conf.all.forwarding=1"
  write_file "${SYSCTL_DIR}/99-wg-fulltunnel.conf" "$content" 644
  run sysctl --system
}

write_sysctl_disable_ipv6() {
  write_file "${SYSCTL_DIR}/99-wg-fulltunnel-noipv6.conf" \
    $'net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1' 644
  run sysctl --system
}

ensure_ufw_port() {
  local rule=$1
  have_cmd ufw || { log "ufw not installed; open $rule manually if you use another firewall"; return; }
  if ufw status | grep -q '^Status: active'; then
    ufw status | grep -qF "$rule" && { log "ufw rule for $rule already present"; return; }
    run ufw allow "$rule"
  else
    log "ufw inactive; open $rule manually if needed"
  fi
}

# The nft tables/chains referenced by PostUp/PostDown must already exist
# before wg-quick runs PostUp — nft has no equivalent of iptables' -A/-I
# "create the chain implicitly if needed", and unlike iptables -D (delete by
# restating the exact match spec), nft has no "delete by spec" at all, so
# PostDown can't mirror PostUp rule-for-rule the way the old iptables version
# did. Instead: base hook chains are created once here (idempotent — "nft
# add" of an already-identical object is a no-op, not an error), PostUp only
# ever *appends* rules into them, and PostDown just flushes the chain empty
# again — which is symmetric without needing per-rule handles. Flushing here
# too (not just relying on PostDown) means a rerun, or a previous crash that
# skipped PostDown, always starts from a clean chain instead of accumulating
# duplicate rules.
ensure_nft_server_base() {
  local tbl="wgft_server_$(nft_tag "$IFACE")"
  run nft add table inet "$tbl"
  run nft add chain inet "$tbl" forward '{ type filter hook forward priority filter; policy accept; }'
  run nft add chain inet "$tbl" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
  run nft flush chain inet "$tbl" forward
  run nft flush chain inet "$tbl" postrouting
}

ensure_nft_client_base() {
  local tbl="wgft_client_$(nft_tag "$IFACE")"
  run nft add table inet "$tbl"
  run nft add chain inet "$tbl" mangle_pre '{ type filter hook prerouting priority mangle; policy accept; }'
  run nft add chain inet "$tbl" mangle_out '{ type filter hook output priority mangle; policy accept; }'
  # Always create+flush dns_out even when DNS_LEAK_PROTECT is off: if a
  # previous run left rules in it (e.g. --no-dns-leak-protect was just added
  # on a rerun), a hooked chain keeps filtering regardless of whether we're
  # populating it again, so a stale REJECT would otherwise survive silently.
  run nft add chain inet "$tbl" dns_out '{ type filter hook output priority filter; policy accept; }'
  run nft flush chain inet "$tbl" mangle_pre
  run nft flush chain inet "$tbl" mangle_out
  run nft flush chain inet "$tbl" dns_out
}

# Reads an "nft list ruleset" dump on stdin and prints "<family> <name>" for
# every table other than $1 that has a forward-hook chain with policy drop.
forward_drop_tables() {
  awk -v own="$1" '/^table /{t=$2" "$3} /hook forward/ && /policy drop/ && t != own {print t}' | sort -u
}

# Our forward chain's "accept" can't help if any OTHER hooked forward chain
# drops: in nft a drop in any base chain is final, whatever other tables
# accept. Learned the hard way: after a server reboot a third-party VPN
# client auto-connected, its kill-switch table ("policy drop" on forward)
# silently ate every forwarded client packet, while wg show/our table/ip_forward all
# looked perfect. Only a warning - the drop may be deliberate, and rules
# inside such a chain might still accept our traffic.
warn_foreign_forward_drop() {
  local tables t
  tables=$(nft list ruleset 2>/dev/null | forward_drop_tables "inet wgft_server_$(nft_tag "$IFACE")" || true)
  [[ -n "$tables" ]] || return 0
  while read -r t; do
    log "WARNING: nft table '${t}' has a forward chain with 'policy drop' - unless one of its rules accepts traffic from ${IFACE}, it will drop the client's forwarded traffic regardless of our accept rules (a drop in any hooked chain is final). Check with: nft list table ${t}"
  done <<< "$tables"
}

server_conf() {
  local tbl="wgft_server_$(nft_tag "$IFACE")"
  # net.ipv4.ip_forward/net.ipv6.conf.all.forwarding (write_sysctl) is all
  # IPv6 forwarding needs on top of this — an `inet` table's rules match
  # both IPv4 and IPv6 packets by default, so unlike the old iptables/
  # ip6tables split, there's no separate IPv6 FORWARD/MASQUERADE rule set to
  # maintain here even when --ipv6 is given.
  # PostUp (re)creates its own table/chains before adding rules, rather than
  # relying on ensure_nft_server_base() having run: nft state lives only in
  # the kernel, so after a reboot the boot-time wg-quick@ unit would
  # otherwise hit "No such file or directory" on the first "add rule" and
  # abort the whole interface - exactly what happened after a server
  # restart. "add table/chain" is idempotent; the flush covers a previous
  # crash that skipped PostDown.
  local up="nft add table inet ${tbl}; nft add chain inet ${tbl} forward '{ type filter hook forward priority filter; policy accept; }'; nft add chain inet ${tbl} postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'; nft flush chain inet ${tbl} forward; nft flush chain inet ${tbl} postrouting"
  up+="; nft add rule inet ${tbl} forward iifname \"${IFACE}\" accept; nft add rule inet ${tbl} forward oifname \"${IFACE}\" accept"
  # One masquerade per --ext-iface entry. NAT doesn't choose the exit -
  # routing does - so listing several is what gives the fallback: whichever
  # interface the kernel currently routes client traffic out of gets
  # masqueraded (e.g. another VPN's tunnel while it's connected and its
  # policy routing is active, the physical uplink once it isn't). Matching
  # by oifname (a string) means an interface that doesn't exist yet or right
  # now is fine.
  local ext
  for ext in ${EXT_IFACE//,/ }; do
    up+="; nft add rule inet ${tbl} postrouting oifname \"${ext}\" masquerade"
  done
  local down="nft flush chain inet ${tbl} forward; nft flush chain inet ${tbl} postrouting"
  cat <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${PRIV_KEY}
PostUp = ${up}
PostDown = ${down}

[Peer]
PublicKey = ${PEER_PUBKEY}
AllowedIPs = ${PEER_ALLOWED_IPS}
EOF
}

client_conf() {
  local tbl="wgft_client_$(nft_tag "$IFACE")"
  # Explicit priority is required: without one, this rule can land at the
  # same or a later priority than the pre-existing "main" rule (32766), so
  # main's (now tunnel-default) route matches first and table ${TABLE} is
  # never actually consulted for marked reply packets. Must be well below
  # 32766.
  local up="ip rule add fwmark ${MARK} table ${TABLE} priority ${TABLE}; ip route add default via ${ORIG_GW} dev ${MGMT_IFACE} table ${TABLE}"
  local down="ip rule del fwmark ${MARK} table ${TABLE} priority ${TABLE}; ip route del default via ${ORIG_GW} dev ${MGMT_IFACE} table ${TABLE}"
  if [[ -n "$MGMT_SUBNET" ]]; then
    # Table ${TABLE} otherwise only has a default route. Since our rule
    # (priority ${TABLE}) is consulted before "main" for marked packets, a
    # reply to a host on ${MGMT_IFACE}'s own connected subnet (e.g. another
    # box on the same LAN) would match table ${TABLE}'s default entry and go
    # out via the gateway instead of directly on the LAN - main's correct,
    # more specific connected route is never reached because table ${TABLE}
    # already produced *a* route. Learned this the hard way: same-subnet SSH
    # broke while a different peer's tunnel address stayed reachable.
    up+="; ip route add ${MGMT_SUBNET} dev ${MGMT_IFACE} table ${TABLE}"
    down+="; ip route del ${MGMT_SUBNET} dev ${MGMT_IFACE} table ${TABLE}"
  fi
  # Same reboot problem as server_conf(): recreate the base table/chains in
  # PostUp itself so the boot-time wg-quick@ unit works without
  # ensure_nft_client_base() having run in this boot.
  up+="; nft add table inet ${tbl}; nft add chain inet ${tbl} mangle_pre '{ type filter hook prerouting priority mangle; policy accept; }'; nft add chain inet ${tbl} mangle_out '{ type filter hook output priority mangle; policy accept; }'; nft flush chain inet ${tbl} mangle_pre; nft flush chain inet ${tbl} mangle_out"
  up+="; nft add rule inet ${tbl} mangle_pre iifname \"${MGMT_IFACE}\" ct mark set ${MARK}; nft add rule inet ${tbl} mangle_out meta mark set ct mark"
  down+="; nft flush chain inet ${tbl} mangle_pre; nft flush chain inet ${tbl} mangle_out"
  if [[ $DNS_LEAK_PROTECT -eq 1 ]]; then
    # Exceptions must be appended to dns_out BEFORE the catch-all reject
    # rules below: nft evaluates a chain top-to-bottom and "add rule"
    # appends to the end, so whichever gets added first is checked first —
    # the opposite of iptables' "-I" (which prepends), where the exceptions
    # had to be inserted AFTER the rejects so they'd end up on top.
    #
    # Also exempt the configured resolver itself, by destination, regardless
    # of interface: if DNS_SERVER is on a directly-connected subnet (e.g. the
    # LAN gateway), the kernel correctly routes queries to it straight out
    # the LAN interface rather than through the tunnel (a connected /24 route
    # always beats the tunnel's /1 override) - and that's the deliberately
    # configured resolver, not a leak. Without this, the kill switch blocks
    # its own upstream DNS server, breaking every hostname lookup.
    up+="; nft add chain inet ${tbl} dns_out '{ type filter hook output priority filter; policy accept; }'; nft flush chain inet ${tbl} dns_out"
    up+="; nft add rule inet ${tbl} dns_out ip daddr ${DNS_SERVER} udp dport 53 accept; nft add rule inet ${tbl} dns_out ip daddr ${DNS_SERVER} tcp dport 53 accept"
    # daddr != 127.0.0.0/8 exempts loopback: without it, this also rejects
    # the local app -> 127.0.0.53 (systemd-resolved's stub) query, since that
    # goes out via "lo" which is "not ${IFACE}" too - breaking ALL DNS
    # resolution inside the tunnel, not just leaks. Learned the hard way.
    up+="; nft add rule inet ${tbl} dns_out oifname != \"${IFACE}\" ip daddr != 127.0.0.0/8 meta mark != ${MARK} udp dport 53 reject; nft add rule inet ${tbl} dns_out oifname != \"${IFACE}\" ip daddr != 127.0.0.0/8 meta mark != ${MARK} tcp dport 53 reject"
    down+="; nft flush chain inet ${tbl} dns_out"
  fi
  if [[ $IPV6 -eq 1 ]]; then
    # The mangle_pre/mangle_out rules above already live in an `inet` table,
    # so they match IPv6 packets automatically too — nothing to duplicate
    # there (unlike the old separate ip6tables CONNMARK rules). ip rule/ip
    # route are still two genuinely separate kernel stacks (v4 vs v6), so
    # those do need a real "-6" mirror.
    up+="; ip -6 rule add fwmark ${MARK} table ${TABLE} priority ${TABLE}; ip -6 route add default via ${ORIG_GW6} dev ${MGMT_IFACE} table ${TABLE}"
    down+="; ip -6 rule del fwmark ${MARK} table ${TABLE} priority ${TABLE}; ip -6 route del default via ${ORIG_GW6} dev ${MGMT_IFACE} table ${TABLE}"
  fi
  up+="; resolvectl domain ${IFACE} \"~.\" 2>/dev/null || true"
  cat <<EOF
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${WG_ADDRESS}
DNS = ${DNS_SERVER}
PostUp = ${up}
PostDown = ${down}

[Peer]
PublicKey = ${PEER_PUBKEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = ${KEEPALIVE}
EOF
}

schedule_watchdog() {
  if [[ $REVERT_AFTER -eq 0 ]]; then
    log "watchdog disabled (--revert-after 0) — no automatic rollback safety net"
    return
  fi
  local unit="wg-fulltunnel-revert-${IFACE}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] would schedule auto-rollback in ${REVERT_AFTER} min (unit: $unit)"
    return
  fi
  mkdir -p "$WATCHDOG_STATE_DIR"
  # A rerun before --confirm-revert still has the previous run's watchdog
  # armed - or, if it already fired, a failed/elapsed unit still loaded
  # under the same name. systemd-run refuses a --unit name that's loaded,
  # which aborted a rerun right after it had already done "wg-quick down".
  # Replace the old watchdog: we're about to arm a fresh one anyway, and an
  # old at/pid one left running would roll back this new setup early.
  cancel_watchdog
  if have_cmd systemctl; then
    systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit}.service" "${unit}.timer" >/dev/null 2>&1 || true
  fi
  if have_cmd systemd-run; then
    systemd-run --unit="$unit" --on-active="${REVERT_AFTER}min" "$SCRIPT_PATH" --rollback --iface "$IFACE" --yes
    echo systemd > "$WATCHDOG_STATE_DIR/${IFACE}.method"
    log "scheduled systemd watchdog $unit (${REVERT_AFTER}m)"
  elif have_cmd at; then
    local jobid
    jobid=$(echo "$SCRIPT_PATH --rollback --iface $IFACE --yes" | at now + "${REVERT_AFTER}" minutes 2>&1 | grep -oP 'job \K[0-9]+' || true)
    echo "$jobid" > "$WATCHDOG_STATE_DIR/${IFACE}.atjob"
    echo at > "$WATCHDOG_STATE_DIR/${IFACE}.method"
    log "scheduled at-job $jobid (${REVERT_AFTER}m)"
  else
    nohup bash -c "sleep $((REVERT_AFTER * 60)); '$SCRIPT_PATH' --rollback --iface '$IFACE' --yes" >>"$LOG_FILE" 2>&1 &
    echo $! > "$WATCHDOG_STATE_DIR/${IFACE}.pid"
    echo pid > "$WATCHDOG_STATE_DIR/${IFACE}.method"
    disown
    log "scheduled background watchdog pid $! (${REVERT_AFTER}m)"
  fi
}

cancel_watchdog() {
  local method_file="$WATCHDOG_STATE_DIR/${IFACE}.method"
  [[ -f "$method_file" ]] || { log "no watchdog scheduled for $IFACE"; return 0; }
  local method; method=$(cat "$method_file")
  case "$method" in
    systemd)
      # Already fired/self-collected (e.g. the watchdog already ran, or a
      # prior cancel already got this far) is a success, not a failure.
      run systemctl stop "wg-fulltunnel-revert-${IFACE}.timer" || true
      run systemctl reset-failed "wg-fulltunnel-revert-${IFACE}.service" || true
      ;;
    at)
      local jobid; jobid=$(cat "$WATCHDOG_STATE_DIR/${IFACE}.atjob" 2>/dev/null || true)
      [[ -n "$jobid" ]] && { run atrm "$jobid" || true; }
      ;;
    pid)
      local pid; pid=$(cat "$WATCHDOG_STATE_DIR/${IFACE}.pid" 2>/dev/null || true)
      [[ -n "$pid" ]] && { run kill "$pid" || true; }
      ;;
  esac
  run rm -f "$WATCHDOG_STATE_DIR/${IFACE}.method" "$WATCHDOG_STATE_DIR/${IFACE}.atjob" "$WATCHDOG_STATE_DIR/${IFACE}.pid"
  log "cancelled watchdog ($method)"
}

validate_client() {
  local ok=1
  wg show "$IFACE" >/dev/null 2>&1 || { log "validation: wg show $IFACE failed"; ok=0; }
  # A default route existing in table $TABLE isn't enough on its own — it
  # only proves the route was added, not that marked packets actually reach
  # it ahead of "main" (that depends on the ip rule's priority). Check the
  # real routing decision for a marked packet instead.
  local mark_route
  mark_route=$(ip route get 1.1.1.1 mark "$MARK" 2>/dev/null)
  echo "$mark_route" | grep -qE "dev ${MGMT_IFACE}([[:space:]]|$)" || {
    log "validation: marked traffic does not route via ${MGMT_IFACE} (got: ${mark_route:-<no route>})"
    ok=0
  }
  # -4: wg-quick adds a ::/0 route through the tunnel whenever AllowedIPs
  # includes ::/0, regardless of whether IPv6 is actually usable here (no
  # IPv6 address is configured on this interface unless --ipv6 was given).
  # Without forcing IPv4, curl's happy-eyeballs can try that dead IPv6 path
  # first and burn the whole --max-time before ever attempting IPv4.
  curl -4 -fsS --max-time 6 https://ifconfig.co >/dev/null 2>&1 || { log "validation: outbound connectivity through tunnel failed"; ok=0; }
  [[ $ok -eq 1 ]]
}

# validate_client()'s curl failing is the same one-line symptom for three
# unrelated causes that need fixing in different places - server unreachable
# or key mismatch, server not forwarding/NATing, or only DNS broken. Run once
# on final validation failure (before rollback tears the tunnel down) so the
# log says which.
diagnose_client_failure() {
  local hs now
  hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}' || true)
  if [[ ! "$hs" =~ ^[0-9]+$ || "$hs" -eq 0 ]]; then
    log "diagnosis: NO handshake with the server at ${ENDPOINT} - the tunnel itself isn't up. Check on the server: 'wg show ${IFACE}' (interface up? its peer key must equal this machine's public key), and that UDP ${ENDPOINT##*:} is reachable (server firewall, cloud security group, changed server IP)"
    return 0
  fi
  now=$(date +%s)
  log "diagnosis: handshake OK ($((now - hs))s ago), transfer: $(wg show "$IFACE" transfer 2>/dev/null | awk 'NR==1 {print "rx " $2 " B, tx " $3 " B"}' || true)"
  if curl -4 -fsS --max-time 6 -o /dev/null https://1.1.1.1 >/dev/null 2>&1; then
    log "diagnosis: raw IP (https://1.1.1.1) works but the hostname check failed - DNS problem only (resolver ${DNS_SERVER}, dns_out kill switch)"
  else
    log "diagnosis: handshake OK but raw IP (https://1.1.1.1) unreachable too - the server isn't forwarding/NATing. Check on the server: 'nft list table inet wgft_server_$(nft_tag "$IFACE")' (masquerade on the right --ext-iface?), 'sysctl net.ipv4.ip_forward', and any other firewall with a FORWARD drop policy (ufw, docker)"
  fi
}

do_rollback() {
  log "rolling back $IFACE"
  cancel_watchdog
  if wg show "$IFACE" >/dev/null 2>&1; then
    run wg-quick down "$IFACE" || true
  fi
  run systemctl disable "wg-quick@${IFACE}" 2>/dev/null || true
  local conf="$CONF_DIR/${IFACE}.conf"
  local latest_bak
  latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1 || true)
  if [[ -n "$latest_bak" ]]; then
    run cp -a "$latest_bak" "$conf"
    log "restored $conf from $latest_bak"
  elif [[ -f "$conf" ]]; then
    run rm -f "$conf"
    log "removed $conf (no prior backup existed)"
  fi
  if [[ -f "${SYSCTL_DIR}/99-wg-fulltunnel.conf" ]]; then
    run rm -f "${SYSCTL_DIR}/99-wg-fulltunnel.conf"
    run sysctl --system
  fi
  # Deletes the whole table rather than relying on PostDown's flush, in case
  # PostDown never ran (e.g. the interface never actually came up). Only one
  # of these two will exist for a given IFACE depending on which role this
  # machine was set up as; deleting a nonexistent table is harmless.
  run nft delete table inet "wgft_client_$(nft_tag "$IFACE")" 2>/dev/null || true
  run nft delete table inet "wgft_server_$(nft_tag "$IFACE")" 2>/dev/null || true
  log "rollback complete"
}

do_status() {
  echo "--- wg show $IFACE ---"; wg show "$IFACE" 2>&1 || true
  echo "--- ip rule show ---"; ip rule show
  echo "--- ip route show table $TABLE ---"; ip route show table "$TABLE" 2>&1 || true
  echo "--- nft (client table) ---"; nft list table inet "wgft_client_$(nft_tag "$IFACE")" 2>&1 || true
  echo "--- nft (server table) ---"; nft list table inet "wgft_server_$(nft_tag "$IFACE")" 2>&1 || true
  echo "--- pending watchdog ---"
  if [[ -f "$WATCHDOG_STATE_DIR/${IFACE}.method" ]]; then
    cat "$WATCHDOG_STATE_DIR/${IFACE}.method"
  else
    echo "none"
  fi
}

do_keygen() {
  check_deps
  mkdir_conf_dir
  ensure_keys
  echo
  echo "Public key for ${IFACE} (give this to the OTHER machine's --peer-pubkey):"
  echo "  $PUB_KEY"
}

setup_server() {
  check_deps
  [[ -n "$WG_ADDRESS" ]] || err_exit "--wg-address required (e.g. 10.0.0.1/24)"
  [[ -n "$PEER_PUBKEY" ]] || err_exit "--peer-pubkey required (client's public key)"
  [[ -n "$PEER_ALLOWED_IPS" ]] || err_exit "--peer-allowed-ips required (e.g. 10.0.0.2/32)"
  if [[ -z "$EXT_IFACE" ]]; then
    EXT_IFACE=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [[ -n "$EXT_IFACE" ]] || err_exit "could not auto-detect --ext-iface; pass it explicitly"
  fi
  [[ "$EXT_IFACE" =~ ^[A-Za-z0-9_.@-]+(,[A-Za-z0-9_.@-]+)*$ ]] \
    || err_exit "--ext-iface must be an interface name or a comma-separated list of them (got: '${EXT_IFACE}')"

  mkdir_conf_dir
  ensure_keys
  ensure_nft_server_base

  local conf="$CONF_DIR/${IFACE}.conf"
  write_file "$conf" "$(server_conf)" 600
  write_sysctl
  ensure_ufw_port "${WG_PORT}/udp"
  warn_foreign_forward_drop

  # "enable --now" is a no-op on an already-active unit, so a config change
  # (e.g. a corrected --ext-iface) wouldn't actually take effect on a rerun.
  # restart handles both "not running yet" and "running with stale config".
  run systemctl enable "wg-quick@${IFACE}"
  run systemctl restart "wg-quick@${IFACE}"

  echo
  echo "Server public key (put this in the client's [Peer] PublicKey):"
  echo "  $PUB_KEY"
  echo
  [[ $DRY_RUN -eq 0 ]] && wg show "$IFACE" || true
}

setup_client() {
  check_deps
  [[ -n "$WG_ADDRESS" ]] || err_exit "--wg-address required (e.g. 10.0.0.2/24)"
  [[ -n "$PEER_PUBKEY" ]] || err_exit "--peer-pubkey required (server's public key)"
  [[ -n "$ENDPOINT" ]] || err_exit "--endpoint required (server_ip:port)"

  detect_default_route
  [[ -n "$ORIG_GW" && -n "$MGMT_IFACE" ]] || err_exit "could not detect default gateway/interface; pass --mgmt-iface and --mgmt-gateway explicitly"
  detect_mgmt_subnet
  if [[ $IPV6 -eq 1 ]]; then
    detect_default_route6
    [[ -n "$ORIG_GW6" ]] || err_exit "--ipv6 given but no IPv6 default route detected; pass it via a future --mgmt-gateway6 or drop --ipv6"
  fi

  mkdir_conf_dir
  ensure_keys
  ensure_nft_client_base

  local conf="$CONF_DIR/${IFACE}.conf"

  echo "This machine's public key (make sure the server's --peer-pubkey matches this):"
  echo "  $PUB_KEY"
  echo
  echo "About to make ${IFACE} the DEFAULT ROUTE on this machine."
  echo "Management traffic on ${MGMT_IFACE} (gateway ${ORIG_GW}) is preserved via policy routing (fwmark ${MARK} / table ${TABLE})."
  if [[ $REVERT_AFTER -gt 0 ]]; then
    echo "Automatic rollback in ${REVERT_AFTER} minute(s) unless confirmed with:"
    echo "  sudo $SCRIPT_PATH --confirm-revert --iface ${IFACE}"
  else
    echo "WARNING: --revert-after 0 — no automatic safety net if this breaks access."
  fi
  confirm_or_abort

  # wg-quick refuses to "up" an interface that already exists — unlike
  # setup_server(), which handles a rerun via "systemctl restart" on an
  # already-active unit, wg-quick itself has no reconfigure-in-place. Bring
  # it down BEFORE overwriting $conf, so PostDown still matches whatever is
  # currently loaded (in case a value like --mgmt-iface changed since the
  # last run) rather than running the new PostDown against old state.
  if wg show "$IFACE" >/dev/null 2>&1; then
    log "${IFACE} is already up — bringing it down first so this reconfigure can apply cleanly"
    run wg-quick down "$IFACE" || true
  fi

  write_file "$conf" "$(client_conf)" 600
  [[ $DISABLE_IPV6 -eq 1 ]] && write_sysctl_disable_ipv6

  schedule_watchdog

  run wg-quick up "$IFACE"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] would validate and then wait for --confirm-revert or auto-rollback"
    return
  fi

  # A single fixed-delay check can race the handshake, DNS routing
  # (resolvectl "~."), or route/ARP state settling - retry with backoff
  # instead of failing (and rolling back) on what might just be startup lag.
  local validated=0 attempt
  for attempt in 1 2 3 4; do
    sleep 3
    if validate_client; then
      validated=1
      break
    fi
    log "validation attempt ${attempt} failed, retrying..."
  done
  if [[ $validated -eq 1 ]]; then
    log "automated validation passed"
    if [[ $ASSUME_YES -eq 1 ]]; then
      echo "Automated validation passed and --yes given: confirming immediately."
      cancel_watchdog
      run systemctl enable "wg-quick@${IFACE}"
    else
      echo
      echo "Local checks passed. This does NOT prove your SSH access still works."
      echo "From a NEW terminal, connect to this box on its ORIGINAL IP, then run:"
      echo "  sudo $SCRIPT_PATH --confirm-revert --iface ${IFACE}"
      echo "Otherwise it auto-reverts in ${REVERT_AFTER} minute(s)."
    fi
  else
    diagnose_client_failure
    log "automated validation FAILED — rolling back immediately"
    do_rollback
    err_exit "client setup failed validation and was rolled back"
  fi
}

do_confirm_revert() {
  cancel_watchdog
  run systemctl enable "wg-quick@${IFACE}" 2>/dev/null || true
  log "confirmed: watchdog cancelled, ${IFACE} made persistent"
}

# Simple on/off toggle for an already-confirmed, working tunnel. Unlike
# --rollback (restores an old conf backup, meant for undoing a bad setup)
# or the initial --role client flow (needs the watchdog/validation since
# it's changing the default route for the first time), this just starts or
# stops the systemd unit for a config that's already known-good.
do_disable() {
  if wg show "$IFACE" >/dev/null 2>&1; then
    run systemctl stop "wg-quick@${IFACE}"
  else
    log "${IFACE} is not currently up"
  fi
  run systemctl disable "wg-quick@${IFACE}" 2>/dev/null || true
  log "${IFACE} disabled: stopped, and won't start on next boot"
}

do_enable() {
  run systemctl enable "wg-quick@${IFACE}"
  run systemctl start "wg-quick@${IFACE}"
  log "${IFACE} enabled and started"
}

print_config_example() {
  cat <<'EOF'
# wg-fulltunnel.sh example config file
#
# Save this (edit the REPLACE_ME values first) and run:
#   sudo wg-fulltunnel.sh --config /etc/wg-debian-vpn.conf --dry-run
#
# One "key=value" per line (key = long flag name without "--").
# Blank lines and lines starting with # are ignored.
# No-value flags need "=true" to enable; leave commented out to disable.
# Flags given directly on the command line always override this file.

# --- Required: pick one ---
role=client
# role=server

iface=wg-debian-vpn

# --- Shared tunnel settings ---
wg-address=10.0.0.2/24
mark=100
table=100

# --- Server role only ---
# wg-port=51820
# ext-iface=eth0          (or a fallback list, e.g. wg0,eth0)
# peer-allowed-ips=10.0.0.2/32

# --- Client role only ---
peer-pubkey=REPLACE_WITH_PEER_PUBLIC_KEY
endpoint=REPLACE_WITH_SERVER_IP:51820
allowed-ips=0.0.0.0/0, ::/0
dns=1.1.1.1
keepalive=25
revert-after=5
# mgmt-iface=eth0
# mgmt-gateway=192.168.1.1
# no-dns-leak-protect=true
# disable-ipv6=true

# --- IPv6 (both roles; only ONE line, set at most once) ---
# ipv6=true

# --- Safety / behavior toggles ---
# dry-run=true
# yes=true
EOF
}

is_bool_flag() {
  local f
  for f in "${BOOL_FLAGS[@]}"; do
    [[ "$f" == "$1" ]] && return 0
  done
  return 1
}

# Pulls --config FILE out of the argument list (wherever it appears) and
# returns the remaining args in PRESCAN_REMAINING, so the config file's
# flags can be prepended and still be overridden by explicit CLI flags.
prescan_config() {
  local args=("$@") out=() i=0
  while [[ $i -lt ${#args[@]} ]]; do
    if [[ "${args[$i]}" == "--config" ]]; then
      CONFIG_FILE="${args[$((i + 1))]:-}"
      [[ -n "$CONFIG_FILE" ]] || err_exit "--config requires a file path"
      i=$((i + 2))
    else
      out+=("${args[$i]}")
      i=$((i + 1))
    fi
  done
  PRESCAN_REMAINING=("${out[@]}")
}

parse_config_file() {
  local file=$1 line key value
  local -A seen=()
  [[ -f "$file" ]] || err_exit "config file not found: $file"
  CONFIG_ARGS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || err_exit "config file $file: bad line (expected key=value): $line"
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    [[ "$key" == "config" ]] && continue
    if [[ -n "${seen[$key]:-}" ]]; then
      err_exit "config file $file: '$key' is set more than once (was '${seen[$key]}', now '$value') — remove the duplicate, the file has no defined precedence between them"
    fi
    seen[$key]=$value
    if is_bool_flag "$key"; then
      case "${value,,}" in
        1|true|yes) CONFIG_ARGS+=("--$key") ;;
        0|false|no|"") : ;;
        *) err_exit "config file $file: '$key' is a flag with no value, got '$value'" ;;
      esac
    else
      CONFIG_ARGS+=("--$key" "$value")
    fi
  done < "$file"
  log "config file $file resolved to: ${CONFIG_ARGS[*]:-<none>}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE=$2; shift 2 ;;
      --rollback) ACTION=rollback; shift ;;
      --confirm-revert) ACTION=confirm-revert; shift ;;
      --disable) ACTION=disable; shift ;;
      --enable) ACTION=enable; shift ;;
      --status) ACTION=status; shift ;;
      --keygen) ACTION=keygen; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --iface) IFACE=$2; shift 2 ;;
      --wg-address) WG_ADDRESS=$2; shift 2 ;;
      --wg-port) WG_PORT=$2; shift 2 ;;
      --ext-iface) EXT_IFACE=$2; shift 2 ;;
      --peer-pubkey) PEER_PUBKEY=$2; shift 2 ;;
      --peer-allowed-ips) PEER_ALLOWED_IPS=$2; shift 2 ;;
      --endpoint) ENDPOINT=$2; shift 2 ;;
      --allowed-ips) ALLOWED_IPS=$2; shift 2 ;;
      --dns) DNS_SERVER=$2; shift 2 ;;
      --keepalive) KEEPALIVE=$2; shift 2 ;;
      --mgmt-iface) MGMT_IFACE=$2; shift 2 ;;
      --mgmt-gateway) ORIG_GW=$2; shift 2 ;;
      --mgmt-subnet) MGMT_SUBNET=$2; shift 2 ;;
      --mark) MARK=$2; shift 2 ;;
      --table) TABLE=$2; shift 2 ;;
      --revert-after) REVERT_AFTER=$2; shift 2 ;;
      --no-dns-leak-protect) DNS_LEAK_PROTECT=0; shift ;;
      --ipv6) IPV6=1; shift ;;
      --disable-ipv6) DISABLE_IPV6=1; shift ;;
      --config-example) print_config_example; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
}

main() {
  prescan_config "$@"
  if [[ -n "$CONFIG_FILE" ]]; then
    parse_config_file "$CONFIG_FILE"
    parse_args "${CONFIG_ARGS[@]}" "${PRESCAN_REMAINING[@]}"
  else
    parse_args "${PRESCAN_REMAINING[@]}"
  fi
  require_root

  exec 200>"$LOCK_FILE"
  flock -n 200 || err_exit "another instance is already running (lock: $LOCK_FILE)"

  touch "$LOG_FILE" 2>/dev/null || true

  case "$ACTION" in
    rollback) do_rollback; exit 0 ;;
    confirm-revert) do_confirm_revert; exit 0 ;;
    disable) do_disable; exit 0 ;;
    enable) do_enable; exit 0 ;;
    status) do_status; exit 0 ;;
    keygen) do_keygen; exit 0 ;;
  esac

  case "$ROLE" in
    server) setup_server ;;
    client) setup_client ;;
    *) usage; err_exit "--role server|client required" ;;
  esac
}

trap 'log "ERROR: script failed at line $LINENO"' ERR

main "$@"
