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
publish_bridge=""
app_network=""
egress_network=""
ingress_network=""
publish_network=""
if_bridges_present=0
confirm_stopped=0
action="status"
nft_cmd="${EGRESS_NFT:-nft}"
docker_cmd="${EGRESS_DOCKER:-docker}"
lock_dir="${EGRESS_LOCK_DIR:-/run/lock}"

usage() {
  echo "usage: host-rules.sh {install|status|rollback} [--table NAME] [--app-bridge IF] [--egress-bridge IF] [--publish-bridge IF] [--proxy-ip ADDR] [--app-network NAME] [--egress-network NAME] [--ingress-network NAME] [--publish-network NAME] [--if-bridges-present] [--confirm-stopped]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|status|rollback) action="$1"; shift ;;
    --table) table="$2"; shift 2 ;;
    --app-bridge) app_bridge="$2"; shift 2 ;;
    --egress-bridge) egress_bridge="$2"; shift 2 ;;
    --publish-bridge) publish_bridge="$2"; shift 2 ;;
    --proxy-ip) proxy_ip="$2"; shift 2 ;;
    --app-network) app_network="$2"; shift 2 ;;
    --egress-network) egress_network="$2"; shift 2 ;;
    --ingress-network) ingress_network="$2"; shift 2 ;;
    --publish-network) publish_network="$2"; shift 2 ;;
    --if-bridges-present) if_bridges_present=1; shift ;;
    --confirm-stopped) confirm_stopped=1; shift ;;
    *) usage ;;
  esac
done

stage_name() {
  printf '%s\n' "$1" | grep -Eq "$2"
}

case "$table" in
  reviewer_egress|reviewer_egress_ci|reviewer_egress_staging) ;;
  *)
    stage_name "$table" '^reviewer_egress_s[0-9a-f]{6}$' || {
      echo "refusing unexpected table $table" >&2
      exit 1
    }
    ;;
esac

case "$app_bridge" in
  br-vvr-app|br-vvr-cia|br-vvr-stga) ;;
  *)
    stage_name "$app_bridge" '^br-vvr-s[0-9a-f]{6}a$' || {
      echo "refusing unexpected app bridge $app_bridge" >&2
      exit 1
    }
    ;;
esac

case "$egress_bridge" in
  br-vvr-egress|br-vvr-cie|br-vvr-stge) ;;
  *)
    stage_name "$egress_bridge" '^br-vvr-s[0-9a-f]{6}e$' || {
      echo "refusing unexpected egress bridge $egress_bridge" >&2
      exit 1
    }
    ;;
esac

if [ "$app_bridge" = "$egress_bridge" ] || { [ -n "$publish_bridge" ] && { [ "$publish_bridge" = "$app_bridge" ] || [ "$publish_bridge" = "$egress_bridge" ]; }; }; then
  echo "app and egress bridges must differ" >&2
  exit 1
fi

if [ -n "$publish_bridge" ]; then
  case "$publish_bridge" in
    br-vvr-publish) ;;
    *)
      stage_name "$publish_bridge" '^br-vvr-s[0-9a-f]{6}p$' || {
        echo "refusing unexpected publish bridge $publish_bridge" >&2
        exit 1
      }
      ;;
  esac
fi

case "$app_bridge" in
  br-vvr-s*)
    app_tag=$(printf '%s\n' "$app_bridge" | sed 's/^br-vvr-s//; s/a$//')
    egress_tag=$(printf '%s\n' "$egress_bridge" | sed 's/^br-vvr-s//; s/e$//')
    table_tag=$(printf '%s\n' "$table" | sed 's/^reviewer_egress_s//')
    if [ "$app_tag" != "$egress_tag" ] || [ "$app_tag" != "$table_tag" ]; then
      echo "refusing mismatched stage names" >&2
      exit 1
    fi
    if [ -n "$publish_bridge" ]; then
      publish_tag=$(printf '%s\n' "$publish_bridge" | sed 's/^br-vvr-s//; s/p$//')
      if [ "$publish_tag" != "$app_tag" ]; then
        echo "refusing mismatched stage names" >&2
        exit 1
      fi
    fi
    ;;
esac

case "${app_bridge}:${proxy_ip}" in
  br-vvr-app:172.30.208.2|br-vvr-cia:172.30.209.2|br-vvr-stga:172.30.210.2) ;;
  br-vvr-s*)
    printf '%s\n' "$proxy_ip" | awk -F. 'BEGIN { ok=0 } $1==172 && $2==30 && $4==2 && $3+0>=128 && $3+0<=251 && $3+0!=208 && $3+0!=209 && $3+0!=210 && $3+0!=216 && $3+0!=217 && $3+0!=218 { ok=1 } END { exit ok ? 0 : 1 }' || {
      echo "refusing proxy $proxy_ip on $app_bridge" >&2
      exit 1
    }
    ;;
  *) echo "refusing proxy $proxy_ip on $app_bridge" >&2; exit 1 ;;
esac

bridge_present() {
  "${EGRESS_IP:-ip}" link show "$1" >/dev/null 2>&1
}

bridges_ready() {
  bridge_present "$app_bridge" && bridge_present "$egress_bridge" || return 1
  if [ -n "$publish_bridge" ] && ! bridge_present "$publish_bridge"; then
    return 1
  fi
  return 0
}

rules_file() {
  publish_forward=""
  publish_input=""
  if [ -n "$publish_bridge" ]; then
    publish_input="    iifname \"${publish_bridge}\" ct state established,related counter accept
    iifname \"${publish_bridge}\" counter drop"
    publish_forward="$publish_input"
  fi
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
${publish_input}
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
${publish_forward}
  }
}
EOF
}

install_rules() {
  if ! bridges_ready; then
    if [ "$if_bridges_present" -eq 1 ]; then
      echo "bridges not present; nothing to enforce"
      return 0
    fi
    echo "required bridge is missing" >&2
    exit 1
  fi

  if timeout 15 "$nft_cmd" list table inet "$table" >/dev/null 2>&1; then
    echo "refusing to replace existing table inet ${table}" >&2
    exit 1
  fi

  tmp=$(mktemp)
  rules_file > "$tmp"
  timeout 15 "$nft_cmd" -c -f "$tmp"
  timeout 15 "$nft_cmd" -f "$tmp"
  rm -f "$tmp"
  echo "installed inet ${table} for ${app_bridge} and ${egress_bridge}"
}

containers_running() {
  set --
  if [ -n "$app_network" ]; then
    set -- "$@" -e "$app_network"
  fi
  if [ -n "$egress_network" ]; then
    set -- "$@" -e "$egress_network"
  fi
  if [ -n "$ingress_network" ]; then
    set -- "$@" -e "$ingress_network"
  fi
  if [ -n "$publish_network" ]; then
    set -- "$@" -e "$publish_network"
  fi
  if [ $# -eq 0 ]; then
    return 1
  fi
  listed=$(timeout 15 "$docker_cmd" ps --filter status=running --format '{{.Names}} {{.Networks}}' 2>/dev/null || true)
  printf '%s\n' "$listed" | grep -F "$@" >/dev/null 2>&1
}

status_rules() {
  if ! bridges_ready; then
    echo "required bridge is missing" >&2
    exit 1
  fi
  timeout 15 "$nft_cmd" list table inet "$table" >/dev/null
  listed=$(timeout 15 "$nft_cmd" list table inet "$table")
  for needle in "$app_bridge" "$egress_bridge" ${publish_bridge:+"$publish_bridge"} "$proxy_ip" "tcp dport 3128" "tcp dport 443" "100.64.0.0/10" "169.254.0.0/16"; do
    if ! printf '%s\n' "$listed" | grep -q -F "$needle"; then
      echo "table ${table} is missing ${needle}" >&2
      exit 1
    fi
  done
  echo "ok inet ${table}"
}

rollback_rules() {
  if [ "$confirm_stopped" -ne 1 ]; then
    echo "rollback requires --confirm-stopped and is not part of staging failure" >&2
    exit 1
  fi
  if containers_running; then
    echo "refusing rollback while staged containers are running" >&2
    exit 1
  fi
  if timeout 15 "$nft_cmd" list table inet "$table" >/dev/null 2>&1; then
    timeout 15 "$nft_cmd" delete table inet "$table"
    echo "removed inet ${table}"
  else
    echo "inet ${table} was not installed"
  fi
}

with_lock() {
  mkdir -p "$lock_dir"
  exec 9>"${lock_dir}/${table}.lock"
  if ! flock -w 15 9; then
    echo "timed out waiting for ${lock_dir}/${table}.lock" >&2
    exit 1
  fi
  "$@"
}

case "$action" in
  install) with_lock install_rules ;;
  status) status_rules ;;
  rollback) with_lock rollback_rules ;;
esac
