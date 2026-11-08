#!/bin/sh
# App-scoped netfilter rules for the reviewer egress bridges.
# A separate nft table at priority -150 runs before the filter chains
# Docker, UFW and Tailscale install. This script never flushes those tables
# and never touches host OUTPUT.
set -eu

table="reviewer_egress"
app_bridge="br-vvr-app"
egress_bridge="br-vvr-egress"
proxy_ip="172.30.208.2"
if_bridges_present=0
action="status"

usage() {
  echo "usage: host-rules.sh {install|status|rollback} [--table NAME] [--app-bridge IF] [--egress-bridge IF] [--proxy-ip ADDR] [--if-bridges-present]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|status|rollback) action="$1"; shift ;;
    --table) table="$2"; shift 2 ;;
    --app-bridge) app_bridge="$2"; shift 2 ;;
    --egress-bridge) egress_bridge="$2"; shift 2 ;;
    --proxy-ip) proxy_ip="$2"; shift 2 ;;
    --if-bridges-present) if_bridges_present=1; shift ;;
    *) usage ;;
  esac
done

case "$table" in
  reviewer_egress|reviewer_egress_ci|reviewer_egress_staging) ;;
  *) echo "refusing unexpected table $table" >&2; exit 1 ;;
esac

case "$app_bridge" in
  br-vvr-app|br-vvr-cia|br-vvr-stga) ;;
  *) echo "refusing unexpected app bridge $app_bridge" >&2; exit 1 ;;
esac

case "$egress_bridge" in
  br-vvr-egress|br-vvr-cie|br-vvr-stge) ;;
  *) echo "refusing unexpected egress bridge $egress_bridge" >&2; exit 1 ;;
esac

if [ "$app_bridge" = "$egress_bridge" ]; then
  echo "app and egress bridges must differ" >&2
  exit 1
fi

case "${app_bridge}:${proxy_ip}" in
  br-vvr-app:172.30.208.2|br-vvr-cia:172.30.209.2|br-vvr-stga:172.30.210.2) ;;
  *) echo "refusing proxy $proxy_ip on $app_bridge" >&2; exit 1 ;;
esac

bridge_present() {
  ip link show "$1" >/dev/null 2>&1
}

rules_file() {
  cat <<EOF
table inet ${table} {
  set bogon4 {
    type ipv4_addr
    flags interval
    elements = {
      0.0.0.0/8,
      10.0.0.0/8,
      100.64.0.0/10,
      127.0.0.0/8,
      169.254.0.0/16,
      172.16.0.0/12,
      192.0.0.0/24,
      192.0.2.0/24,
      192.168.0.0/16,
      198.18.0.0/15,
      198.51.100.0/24,
      203.0.113.0/24,
      224.0.0.0/4,
      240.0.0.0/4
    }
  }

  chain input {
    type filter hook input priority -150; policy accept;
    iifname "${app_bridge}" meta nfproto ipv6 counter drop
    iifname "${egress_bridge}" meta nfproto ipv6 counter drop
    iifname "${app_bridge}" ct state established,related counter accept
    iifname "${app_bridge}" counter drop
    iifname "${egress_bridge}" ct state established,related counter accept
    iifname "${egress_bridge}" counter drop
  }

  chain forward {
    type filter hook forward priority -150; policy accept;
    iifname "${app_bridge}" meta nfproto ipv6 counter drop
    iifname "${egress_bridge}" meta nfproto ipv6 counter drop
    iifname "${app_bridge}" ct state established,related counter accept
    iifname "${app_bridge}" ip daddr ${proxy_ip} tcp dport 3128 counter accept
    iifname "${app_bridge}" counter drop
    iifname "${egress_bridge}" ct state established,related counter accept
    iifname "${egress_bridge}" ip daddr @bogon4 counter drop
    iifname "${egress_bridge}" tcp dport 443 counter accept
    iifname "${egress_bridge}" counter drop
  }
}
EOF
}

install_rules() {
  if ! bridge_present "$app_bridge" || ! bridge_present "$egress_bridge"; then
    if [ "$if_bridges_present" -eq 1 ]; then
      echo "bridges not present; nothing to enforce"
      return 0
    fi
    echo "required bridge is missing" >&2
    exit 1
  fi

  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  rules_file > "$tmp"
  nft -c -f "$tmp"
  # One transaction replaces only this table.
  {
    echo "delete table inet ${table}"
    cat "$tmp"
  } | nft -f - 2>/dev/null || nft -f "$tmp"
  echo "installed inet ${table} for ${app_bridge} and ${egress_bridge}"
}

status_rules() {
  if ! bridge_present "$app_bridge" || ! bridge_present "$egress_bridge"; then
    echo "required bridge is missing" >&2
    exit 1
  fi
  nft list table inet "$table" >/dev/null
  listed=$(nft list table inet "$table")
  for needle in "$app_bridge" "$egress_bridge" "$proxy_ip" "tcp dport 3128" "tcp dport 443" "100.64.0.0/10" "169.254.0.0/16"; do
    if ! printf '%s\n' "$listed" | grep -q -F "$needle"; then
      echo "table ${table} is missing ${needle}" >&2
      exit 1
    fi
  done
  echo "ok inet ${table}"
}

rollback_rules() {
  if nft list table inet "$table" >/dev/null 2>&1; then
    nft delete table inet "$table"
    echo "removed inet ${table}"
  else
    echo "inet ${table} was not installed"
  fi
}

case "$action" in
  install)
    exec 9>"/run/lock/${table}.lock"
    flock 9
    install_rules
    ;;
  status) status_rules ;;
  rollback)
    exec 9>"/run/lock/${table}.lock"
    flock 9
    rollback_rules
    ;;
esac
