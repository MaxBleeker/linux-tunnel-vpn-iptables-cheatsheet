#!/usr/bin/env bash
# wg-ap-peer.sh — generate WireGuard keys on the AP and emit:
#   1. a Linux wg-quick client conf (this AP)
#   2. a RouterOS snippet to paste on the MikroTik router
#
# The router already has a WG interface and keypair. This script never
# writes a server conf. Endpoint is the router. The only value copied
# off the router is its public key.
#
# Usage:
#   echo '<router-wg-public-key>' > router.pub
#   ./wg-ap-peer.sh add ap1
#   ./wg-ap-peer.sh add ap2 --lan 192.168.88.0/24
#   ./wg-ap-peer.sh list
#
# Then:
#   1. paste peers/<name>/mikrotik.rsc on the router
#   2. sudo wg-quick up peers/<name>/<name>.conf
#   3. ping the router tunnel IP
set -euo pipefail
IFS=$'\n\t'
umask 077

########################################
# CONFIG
########################################
OUT_DIR="${OUT_DIR:-$PWD/peers}"
ROUTER_PUB_FILE="${ROUTER_PUB_FILE:-$PWD/router.pub}"

# Inner WireGuard net already used on the router. Router is .1
WG_PREFIX="${WG_PREFIX:-10.10.10}"
ROUTER_TUN_IP="${ROUTER_TUN_IP:-${WG_PREFIX}.1}"
FIRST_HOST="${FIRST_HOST:-2}"

# Real-world reachability of the ROUTER. Never a ${WG_PREFIX}.x address.
ROUTER_ENDPOINT="${ROUTER_ENDPOINT:-192.0.2.1}"
ROUTER_PORT="${ROUTER_PORT:-13231}"

# Existing WG interface name on RouterOS
ROUTER_IFACE="${ROUTER_IFACE:-wg-server}"

# Default AllowedIPs on the AP: the WG net only. Add LANs with --lan.
SPLIT_ALLOWED="${WG_PREFIX}.0/24"

########################################
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
die()  { echo "error: $*" >&2; exit 1; }

read_router_pub() {
  [[ -f "$ROUTER_PUB_FILE" ]] || die "put the router WG public key in $ROUTER_PUB_FILE
  (one line from MikroTik: /interface wireguard print)"
  local k
  k=$(tr -d '[:space:]' <"$ROUTER_PUB_FILE")
  [[ -n "$k" && "$k" != *'<'* ]] || die "router.pub looks empty or still a placeholder"
  printf '%s\n' "$k"
}

next_ip() {
  local used="" f last n
  shopt -s nullglob
  for f in "$OUT_DIR"/*/ip; do
    last=$(<"$f"); last="${last##*.}"
    used+=" $last"
  done
  shopt -u nullglob
  for n in $(seq "$FIRST_HOST" 254); do
    if ! grep -qw "$n" <<<"$used"; then
      echo "${WG_PREFIX}.${n}"
      return 0
    fi
  done
  die "no free host in ${WG_PREFIX}.0/24"
}

atomic_write() {
  local dest=$1
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")
  cat >"$tmp"
  mv -f "$tmp" "$dest"
  chmod 600 "$dest"
}

write_ap_conf() {
  local name=$1 priv=$2 psk=$3 ip=$4 allowed=$5 router_pub=$6
  atomic_write "$OUT_DIR/$name/$name.conf" <<EOF
[Interface]
# This AP inside the WireGuard net. Must match allowed-address on the router.
Address = ${ip}/32
PrivateKey = ${priv}

[Peer]
# Router WG public key — copied off the MikroTik, not generated here.
PublicKey = ${router_pub}
PresharedKey = ${psk}
# Real address of the router. Not ${ROUTER_TUN_IP}.
Endpoint = ${ROUTER_ENDPOINT}:${ROUTER_PORT}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
EOF
}

write_routeros() {
  local name=$1 pub=$2 psk=$3 ip=$4
  atomic_write "$OUT_DIR/$name/mikrotik.rsc" <<EOF
# Paste on the MikroTik. Do not paste the AP private key.

/interface wireguard peers add \\
    interface=${ROUTER_IFACE} \\
    comment="${name}" \\
    public-key="${pub}" \\
    preshared-key="${psk}" \\
    allowed-address=${ip}/32

# Leave endpoint-address empty — the AP initiates.
# Confirm:
#   /interface wireguard peers print where comment="${name}"
#   /interface wireguard peers monitor [find comment="${name}"]
EOF
}

cmd_add() {
  need wg
  local name="" allowed="$SPLIT_ALLOWED"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lan)
        [[ -n "${2:-}" ]] || die "--lan needs a CIDR"
        allowed="${allowed}, $2"
        shift 2
        ;;
      --full)
        echo "warning: AllowedIPs=0.0.0.0/0 will swallow the path to Endpoint" >&2
        echo "         unless you pin a host route to ${ROUTER_ENDPOINT} first" >&2
        allowed="0.0.0.0/0, ::/0"
        shift
        ;;
      -*)
        die "unknown flag: $1"
        ;;
      *)
        [[ -z "$name" ]] || die "unexpected arg: $1"
        name=$1
        shift
        ;;
    esac
  done
  [[ -n "$name" ]] || die "usage: $0 add <name> [--lan CIDR] [--full]"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "name must be alphanumeric/_/-"

  local router_pub
  router_pub=$(read_router_pub)

  mkdir -p "$OUT_DIR"
  [[ -e "$OUT_DIR/$name" ]] && die "peer exists: $OUT_DIR/$name"

  local ip priv pub psk
  ip=$(next_ip)
  mkdir -p "$OUT_DIR/$name"
  printf '%s\n' "$ip" >"$OUT_DIR/$name/ip"

  priv=$(wg genkey)
  pub=$(wg pubkey <<<"$priv")
  psk=$(wg genpsk)
  printf '%s\n' "$priv" >"$OUT_DIR/$name/$name.key"
  printf '%s\n' "$pub"  >"$OUT_DIR/$name/$name.pub"
  printf '%s\n' "$psk"  >"$OUT_DIR/$name/$name.psk"
  chmod 600 "$OUT_DIR/$name/$name.key" "$OUT_DIR/$name/$name.psk"

  write_ap_conf   "$name" "$priv" "$psk" "$ip" "$allowed" "$router_pub"
  write_routeros  "$name" "$pub"  "$psk" "$ip"

  echo "added $name"
  echo "  tunnel IP   : $ip"
  echo "  allowed IPs : $allowed"
  echo "  endpoint    : ${ROUTER_ENDPOINT}:${ROUTER_PORT}"
  echo "  AP conf     : $OUT_DIR/$name/$name.conf"
  echo "  ROS paste   : $OUT_DIR/$name/mikrotik.rsc"
  echo
  echo "next:"
  echo "  1. paste $OUT_DIR/$name/mikrotik.rsc on the router"
  echo "  2. sudo wg-quick up $OUT_DIR/$name/$name.conf"
  echo "  3. ping $ROUTER_TUN_IP"
}

cmd_list() {
  [[ -d "$OUT_DIR" ]] || die "no peers yet"
  echo "endpoint : ${ROUTER_ENDPOINT}:${ROUTER_PORT}"
  echo "router   : ${ROUTER_TUN_IP}  iface ${ROUTER_IFACE}"
  echo
  printf '%-16s %-16s\n' "NAME" "WG_IP"
  shopt -s nullglob
  local d
  for d in "$OUT_DIR"/*/; do
    printf '%-16s %-16s\n' "$(basename "$d")" "$(<"$d/ip")"
  done
}

case "${1:-}" in
  add)  shift; cmd_add "$@" ;;
  list) cmd_list ;;
  *)
    cat <<EOF
usage: $0 add <name> [--lan CIDR] [--full]
       $0 list

Generate AP keypairs against an existing MikroTik WireGuard interface.
Put the router public key in: $ROUTER_PUB_FILE
Outputs land in:             $OUT_DIR
EOF
    exit 1
    ;;
esac
