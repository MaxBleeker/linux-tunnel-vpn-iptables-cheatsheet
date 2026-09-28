# Linux Tunnel, VPN, and iptables Cheatsheet

Command reference for automating **IPIP**, **SSH tunnels**, **OpenVPN**, **WireGuard**, and **iptables**.

Focus: inspect state first, change only what is missing, verify after apply.

```bash
# Safe script header
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077
```

---

## Contents

- [Bash safety](#bash-safety)
- [Inspect state](#inspect-state)
- [Interfaces, addresses, routes](#interfaces-addresses-routes)
- [IPIP](#ipip)
- [SSH tunnels](#ssh-tunnels)
- [WireGuard](#wireguard)
- [OpenVPN](#openvpn)
- [iptables](#iptables)
- [sysctl and modules](#sysctl-and-modules)
- [Policy routing](#policy-routing)
- [Network namespaces](#network-namespaces)
- [Health checks](#health-checks)
- [Idempotent snippets](#idempotent-snippets)
- [Permissions and secrets](#permissions-and-secrets)
- [Teardown order](#teardown-order)

---

## Bash safety

```bash
command -v jq ip wg iptables ssh openvpn >/dev/null

# Quote everything
ip addr add "$CIDR" dev "$IFACE"

# Build commands as arrays (never eval)
cmd=(iptables -A FORWARD -i "$IFACE" -j ACCEPT)
"${cmd[@]}"

# Dry-run wrapper
run() { printf '[dry-run] %q ' "$@"; printf '\n'; }

# Serialize writers
exec {LOCK_FD}>/var/lock/netctl.lock
flock -n "$LOCK_FD" || exit 1

# Debug one function
PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}: '
set -x
set +x
```

```bash
# Atomic config write
tmp=$(mktemp /etc/wireguard/.wg0.conf.XXXXXX)
umask 077
cat >"$tmp" <<EOF
[Interface]
...
EOF
mv -f "$tmp" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
```

```bash
# Wait instead of sleep
wait_for() {
  local n=$1 d=$2; shift 2
  local i
  for ((i=1; i<=n; i++)); do
    "$@" && return 0
    sleep "$d"
  done
  return 1
}
```

---

## Inspect state

Prefer machine output over grepping human text.

```bash
ip -br link
ip -br addr
ip -br route
ip -j link show
ip -j addr show
ip -j route show
ip -j tunnel show
ip -j link show "$IFACE" | jq -r '.[0].operstate'

ss -H -ltn
ss -H -lun
ss -H -ltn "sport = :22"
ss -H -lun "sport = :51820"

wg show
wg show wg0
wg show wg0 peers
wg show wg0 latest-handshakes
wg show wg0 allowed-ips
wg show wg0 endpoints
wg showconf wg0

ip link show type wireguard
ip link show type tun
ip link show type ipip
```

```bash
# Interface exists?
ip link show "$IFACE" >/dev/null 2>&1

# Address already on iface?
ip -j addr show dev "$IFACE" \
  | jq -e --arg c "$CIDR" \
    '.[].addr_info[] | select((.local+"/"+(.prefixlen|tostring))==$c)' >/dev/null

# Default WAN iface
ip -j route show default | jq -r '.[0].dev'
```

---

## Interfaces, addresses, routes

```bash
ip link set "$IFACE" up
ip link set "$IFACE" down
ip link set "$IFACE" mtu 1400

ip addr add 10.8.0.1/24 dev "$IFACE"
ip addr del 10.8.0.1/24 dev "$IFACE"
ip addr flush dev "$IFACE"

ip route add 10.9.0.0/24 via 10.8.0.2 dev "$IFACE"
ip route add default via 10.8.0.1 dev "$IFACE"
ip route del 10.9.0.0/24
ip route replace 10.9.0.0/24 via 10.8.0.2 dev "$IFACE"

ip route get 1.1.1.1
ip route get 10.9.0.2 from 10.8.0.1 iif "$IFACE"
```

```bash
# Add only if missing
ip addr show dev "$IFACE" | grep -q '10.8.0.1/24' \
  || ip addr add 10.8.0.1/24 dev "$IFACE"

ip route show 10.9.0.0/24 | grep -q . \
  || ip route add 10.9.0.0/24 via 10.8.0.2 dev "$IFACE"
```

---

## IPIP

```bash
modprobe ipip
lsmod | grep ipip

# Create
ip tunnel add tun0 mode ipip \
  local 192.0.2.1 remote 198.51.100.1 ttl 64
ip addr add 10.10.10.1/30 dev tun0
ip link set tun0 up
ip route add 10.20.20.0/24 dev tun0

# Inspect
ip tunnel show
ip tunnel show tun0
ip -d link show tun0
ip -s link show tun0

# Change endpoints (delete + recreate is usual)
ip tunnel change tun0 local 192.0.2.1 remote 198.51.100.2 ttl 64

# Destroy
ip route del 10.20.20.0/24 dev tun0 || true
ip link set tun0 down
ip tunnel del tun0
```

```bash
# Idempotent create
if ! ip link show tun0 >/dev/null 2>&1; then
  ip tunnel add tun0 mode ipip local "$LOCAL" remote "$REMOTE" ttl 64
fi
ip link set tun0 up
```

Notes:

- Set `ttl` explicitly. Inherited TTL in nested tunnels is a common lab failure.
- Lower MTU if you encapsulate inside another tunnel (`1400` or `1280`).
- IPIP has no built-in auth. Pair with iptables and a known peer address.

---

## SSH tunnels

```bash
# Local forward: local:8080 -> remote host's 127.0.0.1:80
ssh -N -L 8080:127.0.0.1:80 user@jump

# Remote forward: jump:2222 -> local 22
ssh -N -R 2222:127.0.0.1:22 user@jump

# Dynamic SOCKS
ssh -N -D 1080 user@jump

# Background + fail if bind fails
ssh -f -N -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY" \
  -L 8080:10.8.0.2:22 \
  user@jump

# Multiplex many forwards on one TCP session
ssh -f -N -M -S /run/ssh-tun-%r@%h:%p \
  -o ControlPersist=600 \
  user@jump
ssh -S /run/ssh-tun-%r@%h:%p -O forward -L 8080:10.8.0.2:22 user@jump
ssh -S /run/ssh-tun-%r@%h:%p -O check user@jump
ssh -S /run/ssh-tun-%r@%h:%p -O exit user@jump
```

```bash
# autossh reconnect
autossh -M 0 -f -N \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -i "$KEY" -L 8080:10.8.0.2:22 user@jump
```

```bash
# Is the local listen up?
ss -H -ltn "sport = :8080"

# Find the process
pgrep -af 'ssh .* -L 8080'
```

Restricted key on the jump box (`authorized_keys`):

```text
restrict,port-forwarding,permitopen="10.8.0.2:22",command="/bin/false" ssh-ed25519 AAAA...
```

---

## WireGuard

```bash
modprobe wireguard
wg --version

# Keys
umask 077
wg genkey | tee private.key | wg pubkey > public.key
wg genpsk > preshared.key
chmod 600 private.key preshared.key
```

```bash
# Quick path (preferred in scripts)
wg-quick up wg0
wg-quick down wg0
wg-quick strip /etc/wireguard/wg0.conf
wg-quick up /path/to/wg0.conf
```

Minimal `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.7.0.1/24
ListenPort = 51820
PrivateKey = <server-private>
# PostUp / PostDown belong here if wg-quick should own NAT

[Peer]
PublicKey = <peer-public>
AllowedIPs = 10.7.0.2/32
Endpoint = 198.51.100.10:51820
PersistentKeepalive = 25
```

```bash
# Raw wg (no wg-quick address/route handling)
ip link add dev wg0 type wireguard
ip addr add 10.7.0.1/24 dev wg0
wg set wg0 listen-port 51820 private-key /etc/wireguard/private.key
wg set wg0 peer "$PUB" \
  allowed-ips 10.7.0.2/32 \
  endpoint 198.51.100.10:51820 \
  persistent-keepalive 25
ip link set wg0 up

wg set wg0 peer "$PUB" remove
ip link del wg0
```

```bash
# Peer already present?
wg show wg0 peers | grep -qx "$PUB"

# Handshake newer than 3 minutes?
wg show wg0 latest-handshakes
```

```bash
# Sync live iface from file without bounce
wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)
```

---

## OpenVPN

```bash
openvpn --version
openvpn --config client.ovpn
openvpn --config server.conf --daemon ovpn-server --writepid /run/ovpn-server.pid

# Stay in foreground while testing
openvpn --config client.ovpn --verb 4

# TLS / key direction sanity
openvpn --genkey secret ta.key
```

```bash
# Running?
pgrep -af openvpn
test -f /run/ovpn-server.pid && kill -0 "$(cat /run/ovpn-server.pid)"

# Device and address
ip -br link | grep -E 'tun|tap'
ip -br addr | grep -E 'tun|tap'
```

Common server knobs you will script around:

```text
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
push "route 10.9.0.0 255.255.255.0"
keepalive 10 60
```

Stop cleanly:

```bash
kill "$(cat /run/ovpn-server.pid)"
# or
pkill -f 'openvpn --config server.conf'
```

---

## iptables

Do **not** start scripts with `iptables -F`. You will drop SSH.

```bash
# List
iptables -L -n -v --line-numbers
iptables -S
iptables -t nat -S
iptables -t mangle -S
iptables -t raw -S

# IPv6 twin
ip6tables -S
```

```bash
# Check then add (idempotent)
iptables -C INPUT -p tcp --dport 22 -s 10.8.0.0/24 -j ACCEPT \
  || iptables -A INPUT -p tcp --dport 22 -s 10.8.0.0/24 -j ACCEPT

iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE \
  || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

```bash
# Own a chain instead of polluting FORWARD
iptables -t filter -N TUNFWD 2>/dev/null || true
iptables -C FORWARD -j TUNFWD || iptables -I FORWARD 1 -j TUNFWD

iptables -C TUNFWD -i wg0 -j ACCEPT || iptables -A TUNFWD -i wg0 -j ACCEPT
iptables -C TUNFWD -o wg0 -j ACCEPT || iptables -A TUNFWD -o wg0 -j ACCEPT

# Teardown only your chain
iptables -F TUNFWD
iptables -D FORWARD -j TUNFWD
iptables -X TUNFWD
```

```bash
# NAT / forward lab set
iptables -C FORWARD -i wg0 -o eth0 -j ACCEPT \
  || iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
iptables -C FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT \
  || iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.7.0.0/24 -o eth0 -j MASQUERADE \
  || iptables -t nat -A POSTROUTING -s 10.7.0.0/24 -o eth0 -j MASQUERADE
```

```bash
# Delete one rule
iptables -D INPUT -p tcp --dport 22 -s 10.8.0.0/24 -j ACCEPT
iptables -D FORWARD 3          # by line number (changes after each delete)

# Snapshot / restore
iptables-save > /tmp/iptables.before
iptables-restore < /tmp/iptables.before
iptables-save > /etc/iptables/rules.v4
```

```bash
# Counters prove traffic is hitting the rule
iptables -L FORWARD -n -v
iptables -t nat -L POSTROUTING -n -v
```

Insert vs append:

| Flag | Effect |
| --- | --- |
| `-A` | append at end |
| `-I CHAIN` | insert at top |
| `-I CHAIN N` | insert at line N |
| `-C` | check existence (exit 0 if present) |
| `-D` | delete matching rule |

If policy is `DROP`, a late `-A ACCEPT` never matches. Put jumps near the top.

---

## sysctl and modules

```bash
sysctl net.ipv4.ip_forward
sysctl -w net.ipv4.ip_forward=1
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf.all.send_redirects
sysctl net.ipv4.conf.all.accept_redirects

# Persist one key without dupes
grep -q '^net.ipv4.ip_forward' /etc/sysctl.d/99-tunnels.conf \
  || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-tunnels.conf
sysctl --system
```

```bash
modprobe ipip
modprobe wireguard
modprobe tun
lsmod | grep -E 'ipip|wireguard|tun'
```

`rp_filter` often breaks asymmetric tunnel return paths. Change it only if you know why.

---

## Policy routing

Used when WireGuard or OpenVPN should own some sources but not the default route.

```bash
ip rule add from 10.7.0.2/32 table 100
ip route add default dev wg0 table 100
ip route add 198.51.100.10/32 via "$WAN_GW" dev "$WAN_IF" table 100

ip rule show
ip route show table 100
ip route get 1.1.1.1 from 10.7.0.2

ip rule del from 10.7.0.2/32 table 100
ip route flush table 100
```

```bash
# Avoid duplicate rules
ip rule show | grep -q 'from 10.7.0.2 lookup 100' \
  || ip rule add from 10.7.0.2/32 table 100
```

---

## Network namespaces

Best way to rehearse two tunnel endpoints on one box.

```bash
ip netns add alice
ip netns add bob

ip link add veth-a type veth peer name veth-b
ip link set veth-a netns alice
ip link set veth-b netns bob

ip netns exec alice ip addr add 192.0.2.1/30 dev veth-a
ip netns exec bob   ip addr add 192.0.2.2/30 dev veth-b
ip netns exec alice ip link set veth-a up
ip netns exec bob   ip link set veth-b up
ip netns exec alice ip link set lo up
ip netns exec bob   ip link set lo up

ip netns exec alice ping -c1 192.0.2.2
ip netns exec alice bash /opt/class/alice-up.sh
ip netns exec bob   wg-quick up wg0

ip netns pids alice
ip netns del alice
ip netns del bob
```

---

## Health checks

```bash
# Link
cat /sys/class/net/tun0/operstate
ip -br link show tun0

# L3
ping -c1 -W1 -I tun0 10.10.10.2
ping -c1 -W1 10.7.0.2

# WG live
wg show wg0 latest-handshakes

# Listener
ss -H -ltn "sport = :22"
ss -H -lun "sport = :51820"
ss -H -lun "sport = :1194"

# Path
ip route get 10.20.20.1
traceroute -n 10.20.20.1

# NAT / forward actually hitting
watch -n1 iptables -L FORWARD -n -v
```

```bash
# One-screen status
{
  echo '=== link ===';  ip -br link
  echo '=== addr ===';  ip -br addr
  echo '=== route ==='; ip route
  echo '=== wg ===';    wg show 2>/dev/null || true
  echo '=== listen ==='; ss -ltun | grep -E '22|1194|51820|8080' || true
  echo '=== fwd ===';   iptables -S FORWARD
  echo '=== nat ===';   iptables -t nat -S POSTROUTING
}
```

---

## Idempotent snippets

```bash
ensure_ipip() {
  local name=$1 local_ip=$2 remote_ip=$3
  ip link show "$name" >/dev/null 2>&1 \
    || ip tunnel add "$name" mode ipip local "$local_ip" remote "$remote_ip" ttl 64
  ip link set "$name" up
}

ensure_addr() {
  ip addr show dev "$1" | grep -q "$2" || ip addr add "$2" dev "$1"
}

ensure_ipt() {
  local table=filter
  if [[ $1 == -t ]]; then table=$2; shift 2; fi
  local action=$1; shift
  local chain=$1; shift
  iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1 \
    || iptables -t "$table" "$action" "$chain" "$@"
}

ensure_sysctl() {
  [[ $(sysctl -n "$1") == "$2" ]] || sysctl -w "$1=$2"
}

ensure_wg_up() {
  wg show "$1" >/dev/null 2>&1 || wg-quick up "$1"
}
```

Usage:

```bash
ensure_sysctl net.ipv4.ip_forward 1
ensure_ipip tun0 192.0.2.1 198.51.100.1
ensure_addr tun0 10.10.10.1/30
ensure_ipt -A FORWARD -i tun0 -j ACCEPT
ensure_ipt -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ensure_wg_up wg0
```

---

## Permissions and secrets

```bash
umask 077
chmod 700 /etc/wireguard /etc/openvpn
chmod 600 /etc/wireguard/*.conf /etc/wireguard/*.key
chmod 600 /etc/openvpn/server/*.key /etc/openvpn/server/*.crt
chown root:root /etc/wireguard/wg0.conf
```

Do not commit:

- `PrivateKey`, `.key`, `.pem`, embedded OpenVPN `<key>` blocks
- live `iptables-save` dumps from a classified or school-graded range
- lab endpoint IPs if the repo is public

---

## Teardown order

Reverse of bring-up. Typical order:

1. Health / status snapshot
2. Routes and `ip rule`
3. iptables rules in **your** chain only
4. OpenVPN / SSH process
5. `wg-quick down` or `ip link del wg0`
6. `ip tunnel del tun0`
7. Restore `iptables` snapshot if the script failed mid-apply

```bash
ip route del 10.20.20.0/24 dev tun0 || true
iptables -D FORWARD -i tun0 -j ACCEPT || true
ip link set tun0 down || true
ip tunnel del tun0 || true
```

```bash
# Failure rollback pattern
iptables-save > /tmp/ipt.before.$$
# ... apply ...
# on error:
iptables-restore < /tmp/ipt.before.$$
```

---

## Quick lab sequence

```bash
# 1. forwarding
sysctl -w net.ipv4.ip_forward=1

# 2. tunnel
modprobe ipip
ip tunnel add tun0 mode ipip local "$LOCAL" remote "$REMOTE" ttl 64
ip addr add 10.10.10.1/30 dev tun0
ip link set tun0 up

# 3. overlay VPN (pick one)
wg-quick up wg0
# openvpn --config server.conf --daemon

# 4. firewall
iptables -I FORWARD 1 -i tun0 -j ACCEPT
iptables -I FORWARD 1 -o tun0 -j ACCEPT
iptables -t nat -A POSTROUTING -o "$(ip -j route show default | jq -r '.[0].dev')" -j MASQUERADE

# 5. prove it
ping -c1 -W1 10.10.10.2
wg show
iptables -L FORWARD -n -v
```

---

## Don't

| Command / habit | Why |
| --- | --- |
| `iptables -F` at script start | Drops SSH and lab baseline |
| `sleep 5` after `ip link set up` | Racy and slow; wait on operstate / ping |
| `grep` on `ip addr` as the only check | Format changes; use `ip -j` + `jq` or `iptables -C` |
| `echo $KEY >> wg0.conf` | Non-atomic, wrong mode, word-split |
| `wg-quick up` with no existence check | Second run exits non-zero |
| `openvpn &` with no pid/log | Silent auth failure |
| Hardcoded `eth0` | Labs use `ens3`, `enp0s3`, `wlan0` |
| `eval "iptables $RULE"` | Injection if input is not literal |

Detect WAN instead:

```bash
WAN_IF=$(ip -j route show default | jq -r '.[0].dev')
```
