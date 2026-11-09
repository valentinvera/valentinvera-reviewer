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
ingress_bridge=""
ingress_relay=""
ingress_upstream=""
ingress_port=""
fixture_ip=""
fixture_port=""
dns_sink=""
app_network=""
egress_network=""
ingress_network=""
publish_network=""
if_bridges_present=0
before_bridges=0
confirm_stopped=0
action="status"
nft_cmd="${EGRESS_NFT:-nft}"
docker_cmd="${EGRESS_DOCKER:-docker}"
lock_dir="${EGRESS_LOCK_DIR:-/run/lock}"

usage() {
  echo "usage: host-rules.sh {install|status|rollback} [--table NAME] [--app-bridge IF] [--egress-bridge IF] [--ingress-bridge IF] [--publish-bridge IF] [--proxy-ip ADDR] [--ingress-relay ADDR] [--ingress-upstream ADDR] [--ingress-port PORT] [--fixture-ip ADDR] [--fixture-port PORT] [--dns-sink ADDR] [--app-network NAME] [--egress-network NAME] [--ingress-network NAME] [--publish-network NAME] [--if-bridges-present] [--before-bridges] [--confirm-stopped]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|status|rollback) action="$1"; shift ;;
    --table) table="$2"; shift 2 ;;
    --app-bridge) app_bridge="$2"; shift 2 ;;
    --egress-bridge) egress_bridge="$2"; shift 2 ;;
    --publish-bridge) publish_bridge="$2"; shift 2 ;;
    --ingress-bridge) ingress_bridge="$2"; shift 2 ;;
    --ingress-relay) ingress_relay="$2"; shift 2 ;;
    --ingress-upstream) ingress_upstream="$2"; shift 2 ;;
    --ingress-port) ingress_port="$2"; shift 2 ;;
    --fixture-ip) fixture_ip="$2"; shift 2 ;;
    --fixture-port) fixture_port="$2"; shift 2 ;;
    --dns-sink) dns_sink="$2"; shift 2 ;;
    --proxy-ip) proxy_ip="$2"; shift 2 ;;
    --app-network) app_network="$2"; shift 2 ;;
    --egress-network) egress_network="$2"; shift 2 ;;
    --ingress-network) ingress_network="$2"; shift 2 ;;
    --publish-network) publish_network="$2"; shift 2 ;;
    --if-bridges-present) if_bridges_present=1; shift ;;
    --before-bridges) before_bridges=1; shift ;;
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

if [ -z "$ingress_bridge" ] || [ -z "$publish_bridge" ] || [ -z "$ingress_relay" ] || [ -z "$ingress_upstream" ] || [ -z "$ingress_port" ]; then
  echo "ingress bridge, publish bridge, relay, upstream, and port are required" >&2
  exit 1
fi

if [ "$app_bridge" = "$egress_bridge" ] || [ "$ingress_bridge" = "$app_bridge" ] || [ "$ingress_bridge" = "$egress_bridge" ] || [ "$publish_bridge" = "$app_bridge" ] || [ "$publish_bridge" = "$egress_bridge" ] || [ "$publish_bridge" = "$ingress_bridge" ]; then
  echo "app, ingress, egress, and publish bridges must differ" >&2
  exit 1
fi

case "$publish_bridge" in
  br-vvr-publish) ;;
  *)
    stage_name "$publish_bridge" '^br-vvr-s[0-9a-f]{6}p$' || {
      echo "refusing unexpected publish bridge $publish_bridge" >&2
      exit 1
    }
    ;;
esac

case "$ingress_bridge" in
  br-vvr-ingress) ;;
  *)
    stage_name "$ingress_bridge" '^br-vvr-s[0-9a-f]{6}i$' || {
      echo "refusing unexpected ingress bridge $ingress_bridge" >&2
      exit 1
    }
    ;;
esac

case "$ingress_port" in
  ''|*[!0-9]*)
    echo "refusing ingress port $ingress_port" >&2
    exit 1
    ;;
esac
if [ "$ingress_port" -lt 1024 ] || [ "$ingress_port" -gt 65535 ]; then
  echo "refusing ingress port $ingress_port" >&2
  exit 1
fi

printf '%s %s\n' "$ingress_relay" "$ingress_upstream" | awk 'BEGIN { ok=0 }
  {
    split($1, relay, ".")
    split($2, upstream, ".")
    if (relay[1]==172 && relay[2]==30 && relay[4]==2 && upstream[1]==172 && upstream[2]==30 && upstream[4]==10 && relay[3]==upstream[3] && relay[3]+0>=128 && relay[3]+0<=251)
      ok=1
  }
  END { exit ok ? 0 : 1 }' || {
  echo "refusing ingress relay $ingress_relay upstream $ingress_upstream" >&2
  exit 1
}

case "$app_bridge" in
  br-vvr-s*)
    app_tag=$(printf '%s\n' "$app_bridge" | sed 's/^br-vvr-s//; s/a$//')
    egress_tag=$(printf '%s\n' "$egress_bridge" | sed 's/^br-vvr-s//; s/e$//')
    table_tag=$(printf '%s\n' "$table" | sed 's/^reviewer_egress_s//')
    if [ "$app_tag" != "$egress_tag" ] || [ "$app_tag" != "$table_tag" ]; then
      echo "refusing mismatched stage names" >&2
      exit 1
    fi
    publish_tag=$(printf '%s\n' "$publish_bridge" | sed 's/^br-vvr-s//; s/p$//')
    ingress_tag=$(printf '%s\n' "$ingress_bridge" | sed 's/^br-vvr-s//; s/i$//')
    if [ "$publish_tag" != "$app_tag" ] || [ "$ingress_tag" != "$app_tag" ]; then
      echo "refusing mismatched stage names" >&2
      exit 1
    fi
    ;;
esac

case "$app_bridge" in
  br-vvr-app|br-vvr-cia|br-vvr-stga)
    if [ "$ingress_bridge" != "br-vvr-ingress" ] || [ "$publish_bridge" != "br-vvr-publish" ]; then
      echo "refusing mismatched ingress bridges for $app_bridge" >&2
      exit 1
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

fixture_inet=""
fixture_bridge=""
if [ -n "$fixture_ip" ] || [ -n "$fixture_port" ]; then
  if [ -z "$fixture_ip" ] || [ -z "$fixture_port" ]; then
    echo "fixture address and port are both required" >&2
    exit 1
  fi
  if [ "$fixture_port" != "8443" ]; then
    echo "refusing fixture port $fixture_port" >&2
    exit 1
  fi
  stage_name "$table" '^reviewer_egress_s[0-9a-f]{6}$' || {
    echo "refusing fixture exception outside a stage table" >&2
    exit 1
  }
  printf '%s\n' "$fixture_ip" | awk -F. 'BEGIN { ok=0 } $1==172 && $2==30 && $4==10 && $3+0>=128 && $3+0<=251 && $3+0!=208 && $3+0!=209 && $3+0!=210 && $3+0!=216 && $3+0!=217 && $3+0!=218 { ok=1 } END { exit ok ? 0 : 1 }' || {
    echo "refusing fixture $fixture_ip" >&2
    exit 1
  }
  fixture_inet="    iifname \"${egress_bridge}\" ip daddr ${fixture_ip} tcp dport ${fixture_port} counter accept"
  fixture_bridge="    meta ibrname \"${egress_bridge}\" ether type ip ip daddr ${fixture_ip} tcp dport ${fixture_port} counter accept"
fi

dns_inet=""
dns_bridge=""
if [ -n "$dns_sink" ]; then
  stage_name "$table" '^reviewer_egress_s[0-9a-f]{6}$' || {
    echo "refusing dns sink exception outside a stage table" >&2
    exit 1
  }
  printf '%s\n' "$dns_sink" | awk -F. -v proxy="$proxy_ip" 'BEGIN { ok=0 }
    {
      split(proxy, p, ".")
      if ($1 == 172 && $2 == 30 && $4 == 9 && $3 == p[3] && $3+0 >= 128 && $3+0 <= 251 && $3+0 != 208 && $3+0 != 209 && $3+0 != 210 && $3+0 != 216 && $3+0 != 217 && $3+0 != 218) ok = 1
    }
    END { exit ok ? 0 : 1 }' || {
    echo "refusing dns sink $dns_sink" >&2
    exit 1
  }
  dns_inet="    iifname \"${app_bridge}\" ip daddr ${dns_sink} udp dport 53 counter accept
    iifname \"${app_bridge}\" ip daddr ${dns_sink} tcp dport 53 counter accept"
  dns_bridge="    meta ibrname \"${app_bridge}\" ether type ip ip daddr ${dns_sink} udp dport 53 counter accept
    meta ibrname \"${app_bridge}\" ether type ip ip daddr ${dns_sink} tcp dport 53 counter accept"
fi

bridge_present() {
  "${EGRESS_IP:-ip}" link show "$1" >/dev/null 2>&1
}

bridges_ready() {
  bridge_present "$app_bridge" || return 1
  bridge_present "$egress_bridge" || return 1
  bridge_present "$ingress_bridge" || return 1
  bridge_present "$publish_bridge" || return 1
  return 0
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
    iifname "${publish_bridge}" meta nfproto ipv6 counter drop
    iifname "${ingress_bridge}" meta nfproto ipv6 counter drop
    iifname "${app_bridge}" ct state established,related counter accept
    iifname "${app_bridge}" counter drop
    iifname "${egress_bridge}" ct state established,related counter accept
    iifname "${egress_bridge}" counter drop
    iifname "${publish_bridge}" ct state established,related counter accept
    iifname "${publish_bridge}" counter drop
    iifname "${ingress_bridge}" counter drop
  }

  chain forward {
    type filter hook forward priority -150; policy accept;
    iifname "${app_bridge}" meta nfproto ipv6 counter drop
    iifname "${egress_bridge}" meta nfproto ipv6 counter drop
    iifname "${publish_bridge}" meta nfproto ipv6 counter drop
    iifname "${ingress_bridge}" meta nfproto ipv6 counter drop
    iifname "${app_bridge}" ct state established,related counter accept
    iifname "${app_bridge}" ip daddr ${proxy_ip} tcp dport 3128 counter accept
${dns_inet}
    iifname "${app_bridge}" counter drop
    iifname "${egress_bridge}" ct state established,related counter accept
${fixture_inet}
    iifname "${egress_bridge}" ip daddr @bogon4 counter drop
    iifname "${egress_bridge}" tcp dport 443 counter accept
    iifname "${egress_bridge}" counter drop
    iifname "${publish_bridge}" ct state established,related counter accept
    iifname "${publish_bridge}" counter drop
    iifname "${ingress_bridge}" ct state established,related counter accept
    iifname "${ingress_bridge}" ip saddr ${ingress_relay} ip daddr ${ingress_upstream} tcp dport ${ingress_port} ct state new counter accept
    iifname "${ingress_bridge}" counter drop
  }
}

table bridge ${table} {
  chain input {
    type filter hook input priority -150; policy accept;
    meta ibrname "${app_bridge}" ether type ip6 counter drop
    meta ibrname "${egress_bridge}" ether type ip6 counter drop
    meta ibrname "${publish_bridge}" ether type ip6 counter drop
    meta ibrname "${ingress_bridge}" ether type ip6 counter drop
    meta ibrname "${app_bridge}" ether type ip ct state established,related counter accept
    meta ibrname "${app_bridge}" ether type ip counter drop
    meta ibrname "${egress_bridge}" ether type ip ct state established,related counter accept
    meta ibrname "${egress_bridge}" ether type ip tcp dport 443 counter accept comment "gateway-l2-to-routing"
    meta ibrname "${egress_bridge}" ether type ip counter drop
    meta ibrname "${publish_bridge}" ether type ip ct state established,related counter accept
    meta ibrname "${publish_bridge}" ether type ip counter drop
    meta ibrname "${ingress_bridge}" ether type ip counter drop
  }

  chain forward {
    type filter hook forward priority -150; policy accept;
    meta ibrname "${app_bridge}" ether type ip6 counter drop
    meta ibrname "${egress_bridge}" ether type ip6 counter drop
    meta ibrname "${publish_bridge}" ether type ip6 counter drop
    meta ibrname "${ingress_bridge}" ether type ip6 counter drop
    meta ibrname "${app_bridge}" ether type ip ct state established,related counter accept
    meta ibrname "${app_bridge}" ether type ip ip daddr ${proxy_ip} tcp dport 3128 counter accept
${dns_bridge}
    meta ibrname "${app_bridge}" ether type ip counter drop
    meta ibrname "${egress_bridge}" ether type ip ct state established,related counter accept
${fixture_bridge}
    meta ibrname "${egress_bridge}" ether type ip tcp dport 443 counter accept
    meta ibrname "${egress_bridge}" ether type ip counter drop
    meta ibrname "${publish_bridge}" ether type ip ct state established,related counter accept
    meta ibrname "${publish_bridge}" ether type ip counter drop
    meta ibrname "${ingress_bridge}" ether type ip ct state established,related counter accept
    meta ibrname "${ingress_bridge}" ether type ip ip saddr ${ingress_relay} ip daddr ${ingress_upstream} tcp dport ${ingress_port} counter accept
    meta ibrname "${ingress_bridge}" ether type ip counter drop
  }
}
EOF
}

table_present() {
  timeout 15 "$nft_cmd" list table "$1" "$table" >/dev/null 2>&1
}

rules_match() {
  timeout 15 "$nft_cmd" list table inet "$table" >/dev/null 2>&1 || return 1
  timeout 15 "$nft_cmd" list table bridge "$table" >/dev/null 2>&1 || return 1
  listed=$(timeout 15 "$nft_cmd" list table inet "$table"; timeout 15 "$nft_cmd" list table bridge "$table")
  for needle in "$app_bridge" "$ingress_bridge" "$egress_bridge" "$publish_bridge" "$proxy_ip" "$ingress_relay" "$ingress_upstream" "tcp dport ${ingress_port}" "tcp dport 3128" "tcp dport 443" "100.64.0.0/10" "169.254.0.0/16" "meta nfproto ipv6" "ether type ip6" "ct state established,related"; do
    printf '%s\n' "$listed" | grep -q -F "$needle" || return 1
  done
  if [ -n "$fixture_ip" ]; then
    printf '%s\n' "$listed" | grep -q -F "ip daddr ${fixture_ip} tcp dport ${fixture_port}" || return 1
  fi
  if [ -n "$dns_sink" ]; then
    printf '%s\n' "$listed" | grep -q -F "ip daddr ${dns_sink} udp dport 53" || return 1
    printf '%s\n' "$listed" | grep -q -F "ip daddr ${dns_sink} tcp dport 53" || return 1
  fi
  if printf '%s\n' "$listed" | grep -q -F 'tcp sport'; then
    return 1
  fi
  return 0
}

mark_ready() {
  if [ "$table" != "reviewer_egress" ]; then
    return 0
  fi
  ready_dir="${EGRESS_READY_DIR:-/run/valentinvera-reviewer-egress}"
  mkdir -p "$ready_dir"
  printf '%s\n' reviewer_egress > "$ready_dir/ready"
  chmod 0644 "$ready_dir/ready"
}

install_rules() {
  if [ "$before_bridges" -eq 0 ] && ! bridges_ready; then
    if [ "$if_bridges_present" -eq 1 ]; then
      echo "bridges not present; nothing to enforce"
      return 0
    fi
    echo "required bridge is missing" >&2
    exit 1
  fi

  if table_present inet || table_present bridge; then
    if table_present inet && table_present bridge && rules_match; then
      echo "inet and bridge ${table} already installed"
      mark_ready
      return 0
    fi
    echo "refusing to replace existing table ${table}" >&2
    exit 1
  fi

  tmp=$(mktemp)
  rules_file > "$tmp"
  timeout 15 "$nft_cmd" -c -f "$tmp"
  timeout 15 "$nft_cmd" -f "$tmp"
  rm -f "$tmp"
  mark_ready
  echo "installed inet and bridge ${table} for ${app_bridge}, ${ingress_bridge}, ${egress_bridge}, and ${publish_bridge}"
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
  if [ "$before_bridges" -eq 0 ] && ! bridges_ready; then
    echo "required bridge is missing" >&2
    exit 1
  fi
  if ! rules_match; then
    echo "table ${table} does not match the rendered rules" >&2
    exit 1
  fi
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
  removed=0
  if timeout 15 "$nft_cmd" list table inet "$table" >/dev/null 2>&1; then
    timeout 15 "$nft_cmd" delete table inet "$table"
    removed=1
  fi
  if timeout 15 "$nft_cmd" list table bridge "$table" >/dev/null 2>&1; then
    timeout 15 "$nft_cmd" delete table bridge "$table"
    removed=1
  fi
  if [ "$removed" -eq 1 ]; then
    echo "removed inet and bridge ${table}"
  else
    echo "inet and bridge ${table} were not installed"
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
