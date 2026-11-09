#!/bin/sh
# Host staging harness.
# This script does not delete containers, networks, images, or nft tables.
# It has no EXIT trap. A cloud VM disposable teardown is not this file.
# On failure it stops containers it started and prints an inventory.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
action="${1:-}"
if [ $# -gt 0 ]; then
  shift
fi

docker_cmd="${EGRESS_DOCKER:-docker}"
nft_cmd="${EGRESS_NFT:-nft}"
ip_cmd="${EGRESS_IP:-ip}"
ss_cmd="${EGRESS_SS:-ss}"
idle_seconds="${EGRESS_IDLE_SECONDS:-310}"

usage() {
  echo "usage: host-stage.sh {plan|preflight|run|stop|inventory|collect} [--inventory FILE] [--plan FILE] [--suffix SUFFIX] [--stage-dir DIR]" >&2
  exit 1
}

inventory_file=""
plan_file=""
suffix=""
stage_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --inventory) inventory_file="$2"; shift 2 ;;
    --plan) plan_file="$2"; shift 2 ;;
    --suffix) suffix="$2"; shift 2 ;;
    --stage-dir) stage_dir="$2"; shift 2 ;;
    *) usage ;;
  esac
done

case "$action" in
  plan|preflight|run|stop|inventory|collect) ;;
  *) usage ;;
esac

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    echo "do not install it from this harness; install it separately if the operator chooses" >&2
    exit 1
  }
}

forbidden_value() {
  case "$1" in
    valentinvera-reviewer|reviewer_egress|br-vvr-app|br-vvr-egress|br-vvr-ingress|br-vvr-publish|br-f5d584fd553b|172.18.0.0/16|172.30.208.0/24|172.30.216.0/24|172.30.219.0/24|172.30.220.0/24|3000)
      return 0
      ;;
  esac
  return 1
}

# Stopped stages stay on the host. Never allocate them again, even when
# inventory misses a name, subnet, or port.
reserved_value() {
  case "$1" in
    a41b73|sa41b73|vvrsta41b73|vvrsta41b73a|vvrsta41b73e|br-vvr-sa41b73a|br-vvr-sa41b73e|reviewer_egress_sa41b73|172.30.149.0/24|172.30.150.0/24|20831|\
    e7b421|se7b421|vvrste7b421|vvrste7b421a|vvrste7b421e|vvrste7b421i|vvrste7b421p|br-vvr-se7b421a|br-vvr-se7b421e|br-vvr-se7b421i|br-vvr-se7b421p|reviewer_egress_se7b421|172.30.167.0/24|172.30.168.0/24|172.30.169.0/24|172.30.170.0/24|20129|\
    b83c52|sb83c52|vvrstb83c52|vvrstb83c52a|vvrstb83c52e|vvrstb83c52i|vvrstb83c52p|br-vvr-sb83c52a|br-vvr-sb83c52e|br-vvr-sb83c52i|br-vvr-sb83c52p|reviewer_egress_sb83c52|172.30.154.0/24|172.30.155.0/24|172.30.156.0/24|172.30.157.0/24|20566|\
    7fa384|s7fa384|vvrst7fa384|vvrst7fa384a|vvrst7fa384e|vvrst7fa384i|vvrst7fa384p|br-vvr-s7fa384a|br-vvr-s7fa384e|br-vvr-s7fa384i|br-vvr-s7fa384p|reviewer_egress_s7fa384|172.30.190.0/24|172.30.191.0/24|172.30.192.0/24|172.30.193.0/24|20332|\
    4dc812|s4dc812|vvrst4dc812|vvrst4dc812a|vvrst4dc812e|vvrst4dc812i|vvrst4dc812p|br-vvr-s4dc812a|br-vvr-s4dc812e|br-vvr-s4dc812i|br-vvr-s4dc812p|reviewer_egress_s4dc812|172.30.198.0/24|172.30.199.0/24|172.30.200.0/24|172.30.201.0/24|20790)
      return 0
      ;;
  esac
  return 1
}

inventory_has() {
  grep -F -x -e "$1 $2" "$inventory_file" >/dev/null 2>&1
}

octet_ok() {
  printf '%s\n' "$1" | awk 'BEGIN { ok=0 } $1+0>=128 && $1+0<=251 && $1+0!=208 && $1+0!=209 && $1+0!=210 && $1+0!=216 && $1+0!=217 && $1+0!=218 { ok=1 } END { exit ok ? 0 : 1 }'
}

write_plan() {
  suffix_value="$1"
  app_octet="$2"
  egress_octet="$3"
  port_value="$4"
  ingress_octet="$5"
  publish_octet="$6"
  cat > "$plan_file" <<EOF
SUFFIX=${suffix_value}
PROJECT=vvrst${suffix_value}
TABLE=reviewer_egress_s${suffix_value}
APP_BRIDGE=br-vvr-s${suffix_value}a
EGRESS_BRIDGE=br-vvr-s${suffix_value}e
INGRESS_BRIDGE=br-vvr-s${suffix_value}i
PUBLISH_BRIDGE=br-vvr-s${suffix_value}p
APP_SUBNET=172.30.${app_octet}.0/24
APP_GATEWAY=172.30.${app_octet}.1
PROXY_IP=172.30.${app_octet}.2
EGRESS_SUBNET=172.30.${egress_octet}.0/24
EGRESS_GATEWAY=172.30.${egress_octet}.1
FIXTURE_IP=172.30.${egress_octet}.10
INGRESS_SUBNET=172.30.${ingress_octet}.0/24
INGRESS_GATEWAY=172.30.${ingress_octet}.1
INGRESS_RELAY_IP=172.30.${ingress_octet}.2
INGRESS_UPSTREAM_IP=172.30.${ingress_octet}.10
PUBLISH_SUBNET=172.30.${publish_octet}.0/24
PUBLISH_GATEWAY=172.30.${publish_octet}.1
PORT=${port_value}
APP_NETWORK=vvrst${suffix_value}a
EGRESS_NETWORK=vvrst${suffix_value}e
INGRESS_NETWORK=vvrst${suffix_value}i
PUBLISH_NETWORK=vvrst${suffix_value}p
IMAGE_TAG=s${suffix_value}
STAGE_DIR=${stage_dir}
EOF
}

plan_collides() {
  suffix_value="$1"
  app_octet="$2"
  egress_octet="$3"
  port_value="$4"
  ingress_octet=$((app_octet + 2))
  publish_octet=$((app_octet + 3))
  inventory_has bridge "br-vvr-s${suffix_value}a" && return 0
  inventory_has bridge "br-vvr-s${suffix_value}e" && return 0
  inventory_has bridge "br-vvr-s${suffix_value}i" && return 0
  inventory_has bridge "br-vvr-s${suffix_value}p" && return 0
  inventory_has table "reviewer_egress_s${suffix_value}" && return 0
  inventory_has network "vvrst${suffix_value}a" && return 0
  inventory_has network "vvrst${suffix_value}e" && return 0
  inventory_has network "vvrst${suffix_value}i" && return 0
  inventory_has network "vvrst${suffix_value}p" && return 0
  inventory_has project "vvrst${suffix_value}" && return 0
  inventory_has subnet "172.30.${app_octet}.0/24" && return 0
  inventory_has subnet "172.30.${egress_octet}.0/24" && return 0
  inventory_has subnet "172.30.${ingress_octet}.0/24" && return 0
  inventory_has subnet "172.30.${publish_octet}.0/24" && return 0
  inventory_has port "$port_value" && return 0
  if grep -F -e "vvrst${suffix_value}-" "$inventory_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

choose_plan() {
  if [ -z "$plan_file" ]; then
    if [ -z "$stage_dir" ]; then
      echo "plan needs --plan or --stage-dir" >&2
      exit 1
    fi
    plan_file="${stage_dir}/plan"
  fi
  [ -n "$inventory_file" ] || {
    echo "plan needs --inventory" >&2
    exit 1
  }
  if grep -F -x -e 'subnet 0.0.0.0/0' -e 'subnet 172.16.0.0/12' -e 'subnet 172.30.0.0/16' "$inventory_file" >/dev/null 2>&1; then
    echo "inventory contains a subnet that covers the stage range" >&2
    exit 1
  fi
  if [ -n "$suffix" ]; then
    set -- "$suffix"
  else
    need od
    set --
    n=0
    while [ "$n" -lt 20 ]; do
      set -- "$@" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
      n=$((n + 1))
    done
  fi
  for candidate in "$@"; do
    case "$candidate" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) continue ;;
    esac
    if reserved_value "$candidate" || reserved_value "s$candidate" || reserved_value "vvrst$candidate"; then
      echo "refusing retained stage $candidate" >&2
      continue
    fi
    app_octet=$((128 + (0x$candidate % 90)))
    egress_octet=$((app_octet + 1))
    ingress_octet=$((app_octet + 2))
    publish_octet=$((app_octet + 3))
    if ! octet_ok "$app_octet" || ! octet_ok "$egress_octet" || ! octet_ok "$ingress_octet" || ! octet_ok "$publish_octet"; then
      continue
    fi
    port_value=$((20000 + (0x$candidate % 900)))
    if [ "$port_value" -eq 3000 ] || [ "$port_value" -eq 20831 ]; then
      continue
    fi
    if reserved_value "172.30.${app_octet}.0/24" || reserved_value "172.30.${egress_octet}.0/24" \
      || reserved_value "172.30.${ingress_octet}.0/24" || reserved_value "172.30.${publish_octet}.0/24" \
      || reserved_value "$port_value"; then
      echo "refusing retained stage address for $candidate" >&2
      continue
    fi
    if plan_collides "$candidate" "$app_octet" "$egress_octet" "$port_value"; then
      continue
    fi
    write_plan "$candidate" "$app_octet" "$egress_octet" "$port_value" "$ingress_octet" "$publish_octet"
    echo "planned $(plan_get SUFFIX) on port $(plan_get PORT)"
    return 0
  done
  echo "could not allocate a stage that avoids the current inventory" >&2
  exit 1
}

plan_get() {
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$plan_file"
}

preflight_plan() {
  [ -n "$plan_file" ] && [ -f "$plan_file" ] || {
    echo "preflight needs --plan" >&2
    exit 1
  }
  [ -n "$inventory_file" ] && [ -f "$inventory_file" ] || {
    echo "preflight needs --inventory" >&2
    exit 1
  }
  for key in PROJECT TABLE APP_BRIDGE EGRESS_BRIDGE INGRESS_BRIDGE PUBLISH_BRIDGE APP_SUBNET EGRESS_SUBNET INGRESS_SUBNET PUBLISH_SUBNET PORT APP_NETWORK EGRESS_NETWORK INGRESS_NETWORK PUBLISH_NETWORK IMAGE_TAG PROXY_IP INGRESS_UPSTREAM_IP INGRESS_RELAY_IP; do
    value=$(plan_get "$key")
    if [ -z "$value" ]; then
      echo "plan is missing $key" >&2
      exit 1
    fi
    if forbidden_value "$value" || reserved_value "$value"; then
      echo "refusing plan value $value" >&2
      exit 1
    fi
  done
  if inventory_has bridge "$(plan_get APP_BRIDGE)" \
    || inventory_has bridge "$(plan_get EGRESS_BRIDGE)" \
    || inventory_has bridge "$(plan_get INGRESS_BRIDGE)" \
    || inventory_has bridge "$(plan_get PUBLISH_BRIDGE)" \
    || inventory_has table "$(plan_get TABLE)" \
    || inventory_has network "$(plan_get APP_NETWORK)" \
    || inventory_has network "$(plan_get EGRESS_NETWORK)" \
    || inventory_has network "$(plan_get INGRESS_NETWORK)" \
    || inventory_has network "$(plan_get PUBLISH_NETWORK)" \
    || inventory_has project "$(plan_get PROJECT)" \
    || inventory_has subnet "$(plan_get APP_SUBNET)" \
    || inventory_has subnet "$(plan_get EGRESS_SUBNET)" \
    || inventory_has subnet "$(plan_get INGRESS_SUBNET)" \
    || inventory_has subnet "$(plan_get PUBLISH_SUBNET)" \
    || inventory_has port "$(plan_get PORT)"; then
    echo "refusing to replace an existing stage resource" >&2
    exit 1
  fi
  echo "preflight clear for $(plan_get PROJECT)"
}

append_inventory() {
  printf '%s\n' "$1" >> "$inventory_file"
}

# A failed command prints its stderr and the inventory collected so far.
# An empty result is success. Do not hide a non-zero status.
capture_cmd() {
  label=$1
  shift
  err=$(mktemp "${TMPDIR:-/tmp}/vvr-inv.XXXXXX")
  out=$(timeout 30 "$@" 2>"$err") && status=0 || status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $label (exit $status)" >&2
    if [ -s "$err" ]; then
      cat "$err" >&2
    fi
    echo "== partial inventory" >&2
    if [ -s "$inventory_file" ]; then
      cat "$inventory_file" >&2
    else
      echo "(empty)" >&2
    fi
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# null, empty, and [] are normal for host, none, and networks without IPAM.
emit_subnets() {
  raw=$1
  compact=$(printf '%s' "$raw" | tr -d '[:space:]')
  case "$compact" in
    ''|null|'null'|'[]')
      return 0
      ;;
  esac
  printf '%s\n' "$raw" | awk '
    {
      line = $0
      while (match(line, /"Subnet"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        item = substr(line, RSTART, RLENGTH)
        sub(/^"Subnet"[[:space:]]*:[[:space:]]*"/, "", item)
        sub(/"$/, "", item)
        if (item != "") print item
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

read_records() {
  while IFS= read -r record || [ -n "$record" ]; do
    if [ -z "$record" ]; then
      continue
    fi
    case "$1" in
      container)
        name=$(printf '%s\n' "$record" | awk '{ print $1 }')
        project=$(printf '%s\n' "$record" | awk '{ print $2 }')
        if [ -n "$name" ]; then
          append_inventory "container $name"
        fi
        if [ -n "$project" ]; then
          append_inventory "project $project"
        fi
        ;;
      network)
        append_inventory "network $record"
        raw=$(capture_cmd "docker network inspect $record" "$docker_cmd" network inspect "$record" --format '{{json .IPAM.Config}}')
        subnets=$(emit_subnets "$raw")
        if [ -n "$subnets" ]; then
          while IFS= read -r item || [ -n "$item" ]; do
            if [ -n "$item" ]; then
              append_inventory "subnet $item"
            fi
          done <<ENDSUBNETS
$subnets
ENDSUBNETS
        fi
        ;;
    esac
  done <<ENDRECORDS
$2
ENDRECORDS
}

collect_inventory() {
  [ -n "$inventory_file" ] || {
    echo "collect needs --inventory" >&2
    exit 1
  }
  : > "$inventory_file"
  containers=$(capture_cmd "docker ps" "$docker_cmd" ps -a --format '{{.Names}} {{.Label "com.docker.compose.project"}}')
  read_records container "$containers"
  networks=$(capture_cmd "docker network ls" "$docker_cmd" network ls --format '{{.Name}}')
  read_records network "$networks"
  links=$(capture_cmd "ip link" "$ip_cmd" -o link show)
  printf '%s\n' "$links" | awk -F': ' '{
    name = $2
    sub(/:.*/, "", name)
    sub(/@.*$/, "", name)
    if (name ~ /^br/) print "bridge", name
  }' >> "$inventory_file"
  tables=$(capture_cmd "nft list tables" "$nft_cmd" list tables)
  printf '%s\n' "$tables" | awk '$1 == "table" && $2 == "inet" { print "table", $3 }' >> "$inventory_file"
  listeners=$(capture_cmd "ss listeners" "$ss_cmd" -H -ltn)
  printf '%s\n' "$listeners" | awk '{
    addr = $4
    n = split(addr, parts, ":")
    if (n >= 2 && parts[n] ~ /^[0-9]+$/) print "port", parts[n]
  }' >> "$inventory_file"
}

require_tools() {
  need timeout
  need flock
  need nft
  need openssl
  need docker
  need ss
  need ip
  need awk
  need curl
  need od
}

stop_project_containers() {
  timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" --profile oracle stop
}

stage_fail() {
  echo "FAIL: $1" >&2
  echo "stopping staged containers; networks, files, and nft tables stay" >&2
  if [ -n "${env_file:-}" ] && [ -f "$env_file" ]; then
    stop_project_containers >&2 || true
  fi
  print_inventory || true
  exit 1
}

print_inventory() {
  echo
  echo "== retained inventory"
  echo "plan ${plan_file:-unset}"
  echo "stage ${stage_dir:-unset}"
  if [ -n "${plan_file:-}" ] && [ -f "$plan_file" ]; then
    echo "project $(plan_get PROJECT)"
    echo "table $(plan_get TABLE)"
    echo "bridges $(plan_get APP_BRIDGE) $(plan_get EGRESS_BRIDGE)"
    echo "port $(plan_get PORT)"
    timeout 20 "$docker_cmd" ps -a --filter "label=com.docker.compose.project=$(plan_get PROJECT)" --format '{{.Names}} {{.Status}}' || true
    if timeout 15 "$nft_cmd" list table inet "$(plan_get TABLE)" >/dev/null 2>&1; then
      echo "nft inet $(plan_get TABLE) present"
    else
      echo "nft inet $(plan_get TABLE) absent"
    fi
  fi
}

mapped_owner() {
  sec=$(timeout 20 "$docker_cmd" info --format '{{json .SecurityOptions}}')
  if printf '%s\n' "$sec" | grep -q userns; then
    "$root/stage-perms.sh" --print --subuid /etc/subuid --remap-user dockremap --container-uid 10001
  else
    "$root/stage-perms.sh" --print --container-uid 10001 --identity
  fi
}

run_stage() {
  require_tools
  if [ "$(id -u)" -ne 0 ]; then
    echo "run the host harness as root so nft and docker can be used. This does not change userns." >&2
    exit 1
  fi
  case "$idle_seconds" in
    ''|*[!0-9]*) echo "EGRESS_IDLE_SECONDS must be seconds" >&2; exit 1 ;;
  esac
  if [ -z "$stage_dir" ]; then
    stage_dir=$(mktemp -d /var/tmp/vvr-stage.XXXXXX)
  else
    mkdir -p "$stage_dir"
  fi
  inventory_file="$stage_dir/inventory-before"
  plan_file="$stage_dir/plan"
  collect_inventory
  choose_plan
  preflight_plan
  env_file="$stage_dir/env"
  mkdir -p "$stage_dir/delay" "$stage_dir/fixture" "$stage_dir/client" "$stage_dir/empty" "$stage_dir/dns"
  chmod 1777 "$stage_dir/dns"
  printf '0\n' > "$stage_dir/delay/ms"
  cp "$root/testdata/fixture.js" "$root/testdata/health.js" "$root/testdata/client.js" "$root/testdata/dns-sink.js" "$stage_dir/"
  cp "$root/allowlist" "$stage_dir/allowlist"
  cat >> "$stage_dir/allowlist" <<'EOF'
metadata.test
lan.test
cgnat.test
loop.test
EOF
  openssl req -x509 -newkey rsa:2048 -keyout "$stage_dir/ca.key" -out "$stage_dir/client/ca.crt" -days 1 -nodes -subj /CN=egress-stage-ca >/dev/null 2>&1
  openssl req -newkey rsa:2048 -keyout "$stage_dir/fixture/srv.key" -out "$stage_dir/srv.csr" -nodes -subj /CN=idle.fixture >/dev/null 2>&1
  printf 'subjectAltName=DNS:idle.fixture,DNS:blocked.fixture\n' > "$stage_dir/san.cnf"
  openssl x509 -req -in "$stage_dir/srv.csr" -CA "$stage_dir/client/ca.crt" -CAkey "$stage_dir/ca.key" -CAcreateserial \
    -out "$stage_dir/fixture/srv.crt" -days 1 -extfile "$stage_dir/san.cnf" >/dev/null 2>&1
  owner=$(mapped_owner)
  if printf '%s\n' "$(timeout 20 "$docker_cmd" info --format '{{json .SecurityOptions}}')" | grep -q userns; then
    for path in "$stage_dir/fixture/srv.key" "$stage_dir/fixture/srv.crt" "$stage_dir/client/ca.crt" "$stage_dir/delay/ms"; do
      "$root/stage-perms.sh" --apply --subuid /etc/subuid --remap-user dockremap --container-uid 10001 --path "$path" >/dev/null
    done
  else
    for path in "$stage_dir/fixture/srv.key" "$stage_dir/fixture/srv.crt" "$stage_dir/client/ca.crt" "$stage_dir/delay/ms"; do
      "$root/stage-perms.sh" --apply --container-uid 10001 --identity --path "$path" >/dev/null
    done
  fi
  unset owner
  "$root/render-squid-conf.sh" \
    --bind "$(plan_get PROXY_IP):3128" \
    --src "$(plan_get APP_SUBNET)" \
    --allow-file "$stage_dir/allowlist" \
    --fixture-name idle.fixture \
    --fixture-dst "$(plan_get FIXTURE_IP)/32" \
    > "$stage_dir/squid.conf"
  chmod 0444 "$stage_dir/squid.conf" "$stage_dir/fixture.js" "$stage_dir/health.js" "$stage_dir/client.js" "$stage_dir/dns-sink.js"
  cat > "$env_file" <<EOF
EGRESS_PROJECT_NAME=$(plan_get PROJECT)
EGRESS_IMAGE_TAG=$(plan_get IMAGE_TAG)
REVIEWER_BIND_PORT=$(plan_get PORT)
REVIEWER_IMAGE=oven/bun:1.4.4
REVIEWER_DATA_DIR=$stage_dir/empty
REVIEWER_BACKUP_DIR=$stage_dir/empty
REVIEWER_SECRETS_DIR=$stage_dir/empty
APP_SUBNET=$(plan_get APP_SUBNET)
APP_GATEWAY=$(plan_get APP_GATEWAY)
PROXY_IP=$(plan_get PROXY_IP)
APP_NETWORK_NAME=$(plan_get APP_NETWORK)
EGRESS_NETWORK_NAME=$(plan_get EGRESS_NETWORK)
APP_BRIDGE=$(plan_get APP_BRIDGE)
EGRESS_BRIDGE=$(plan_get EGRESS_BRIDGE)
EGRESS_SUBNET=$(plan_get EGRESS_SUBNET)
EGRESS_GATEWAY=$(plan_get EGRESS_GATEWAY)
INGRESS_NETWORK_NAME=$(plan_get INGRESS_NETWORK)
INGRESS_BRIDGE=$(plan_get INGRESS_BRIDGE)
INGRESS_SUBNET=$(plan_get INGRESS_SUBNET)
INGRESS_GATEWAY=$(plan_get INGRESS_GATEWAY)
INGRESS_RELAY_IP=$(plan_get INGRESS_RELAY_IP)
INGRESS_UPSTREAM_IP=$(plan_get INGRESS_UPSTREAM_IP)
INGRESS_LISTEN_PORT=8080
PUBLISH_NETWORK_NAME=$(plan_get PUBLISH_NETWORK)
PUBLISH_BRIDGE=$(plan_get PUBLISH_BRIDGE)
PUBLISH_SUBNET=$(plan_get PUBLISH_SUBNET)
PUBLISH_GATEWAY=$(plan_get PUBLISH_GATEWAY)
TEST_CONF=$stage_dir/squid.conf
TEST_DIR=$stage_dir
FIXTURE_DIR=$stage_dir/fixture
CLIENT_CA=$stage_dir/client/ca.crt
FIXTURE_IP=$(plan_get FIXTURE_IP)
DNS_SINK_IP=$(printf '%s\n' "$(plan_get APP_SUBNET)" | awk -F'[./]' '{ printf "%s.%s.%s.9\n", $1, $2, $3 }')
NEIGHBOR_IP=$(printf '%s\n' "$(plan_get APP_SUBNET)" | awk -F'[./]' '{ printf "%s.%s.%s.8\n", $1, $2, $3 }')
IDLE_MS=$((idle_seconds * 1000))
EOF
  rendered=$(timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" config)
  printf '%s\n' "$rendered" | grep -q 'internal: true' || stage_fail "rendered compose is not an internal app network"
  printf '%s\n' "$rendered" | grep -q 'enable_ip_masquerade: "false"' || stage_fail "publish network masquerades"
  if printf '%s\n' "$rendered" | grep -q 'NET_BIND_SERVICE\|network_mode: host\|docker.sock'; then
    stage_fail "rendered compose adds a capability, the host network, or the docker socket"
  fi
  timeout 600 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" build proxy ingress
  timeout 180 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" up -d proxy fixture client ingress dns
  client_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q client)
  ingress_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q ingress)
  proxy_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q proxy)
  fixture_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q fixture)
  dns_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q dns)
  tcp_ok=0
  publish_ok=0
  if timeout 8 "$docker_cmd" exec "$client_id" bun /opt/client.js direct "$(plan_get PROXY_IP)" 3128; then
    tcp_ok=1
  fi
  client_ports=$("$docker_cmd" inspect "$client_id" --format '{{json .NetworkSettings.Ports}}')
  ports=$("$docker_cmd" inspect "$ingress_id" --format '{{json .NetworkSettings.Ports}}')
  echo "client port map: $client_ports"
  echo "ingress port map: $ports"
  if printf '%s\n' "$client_ports" | grep -q 'HostPort'; then
    echo "client published a port; the isolated app must not own the host mapping" >&2
    stage_fail "client port map"
  fi
  if timeout 5 curl -fsS "http://127.0.0.1:$(plan_get PORT)/" | grep -q ok; then
    publish_ok=1
  fi
  if [ "$tcp_ok" -ne 1 ] || [ "$publish_ok" -ne 1 ]; then
    echo "transport proof incomplete (tcp=${tcp_ok} publish=${publish_ok})" >&2
    echo "GitHub, OpenCode, the quiet tunnel, and containment were not run." >&2
    stage_fail "transport"
  fi
  echo "transport ok; remaining checks are still not a production activation"
  client_exec() {
    timeout "$1" "$docker_cmd" exec "$client_id" bun /opt/client.js "$2" "$3"
  }
  run_in() {
    cid=$1
    secs=$2
    shift 2
    run_code=0
    timeout "$secs" "$docker_cmd" exec "$cid" bun /opt/client.js "$@" >"$stage_dir/last.out" 2>"$stage_dir/last.err" || run_code=$?
  }
  err_detail() {
    tr '\n' ' ' < "$stage_dir/last.err" | awk '{ print substr($0, 1, 180) }'
  }
  out_detail() {
    tr '\n' ' ' < "$stage_dir/last.out" | awk '{ print substr($0, 1, 180) }'
  }
  nft_bin=${EGRESS_NFT:-nft}
  nft_packets() {
    timeout 15 "$nft_bin" list table "$1" "$(plan_get TABLE)" | awk -v chain="$2" -v needle="$3" '
      $1 == "chain" { current = $2; next }
      current == chain && index($0, needle) {
        for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); found = 1; exit }
      }
      END { if (!found) exit 1 }
    '
  }
  case_file="$stage_dir/cases"
  : > "$case_file"
  health_state() {
    timeout 8 "$docker_cmd" exec "$client_id" bun -e 'process.stdout.write(await Bun.file("/tmp/health.state").text().catch(() => ""))'
  }
  release_health() {
    timeout 8 "$docker_cmd" exec "$client_id" bun -e 'await Bun.write("/tmp/health.control", "release\n")'
    i=0
    while [ "$i" -lt 30 ]; do
      state=$(health_state) || state=""
      case "$state" in
        released*) return 0 ;;
      esac
      i=$((i + 1))
      sleep 0.1
    done
    return 1
  }
  restore_health() {
    timeout 8 "$docker_cmd" exec "$client_id" bun -e 'await Bun.write("/tmp/health.control", "listen\n")'
    i=0
    while [ "$i" -lt 30 ]; do
      state=$(health_state) || state=""
      case "$state" in
        listening*) return 0 ;;
      esac
      i=$((i + 1))
      sleep 0.1
    done
    return 1
  }
  record_case() {
    printf '%s %s %s\n' "$1" "$2" "$3" | tee -a "$case_file"
    if [ "$2" = "ESCAPE" ]; then
      if ! restore_health; then
        echo "health listener was not restored after an escape" >&2
      fi
      stage_fail "containment escape: $1"
    fi
  }
  quiet_tunnel() {
    label=$1
    printf '%s\n' "$((idle_seconds * 1000))" > "$stage_dir/delay/ms"
    start=$(date +%s)
    timeout $((idle_seconds + 40)) "$docker_cmd" exec "$client_id" bun /opt/client.js idle "https://idle.fixture:8443/slow" | grep -q 'slow-ok' || stage_fail "$label"
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -lt "$idle_seconds" ]; then
      stage_fail "$label ended early"
    fi
    printf '0\n' > "$stage_dir/delay/ms"
    echo "$label ${elapsed}s"
  }
  client_exec 25 https "https://api.github.com/" | grep -q '^200 ' || stage_fail "api.github.com"
  client_exec 25 https "https://opencode.ai/" >/dev/null || stage_fail "opencode.ai"
  client_exec 20 https "https://example.com/" && stage_fail "example.com was allowed"
  client_exec 20 https "https://idle.fixture:8443/" | grep -q '^200 ' || stage_fail "fixture handshake"
  quiet_tunnel "quiet tunnel before nft"
  DNS_SINK_IP=$(awk -F= '/^DNS_SINK_IP=/{ print $2 }' "$env_file")
  timeout 30 "$root/host-rules.sh" install \
    --table "$(plan_get TABLE)" \
    --app-bridge "$(plan_get APP_BRIDGE)" \
    --egress-bridge "$(plan_get EGRESS_BRIDGE)" \
    --ingress-bridge "$(plan_get INGRESS_BRIDGE)" \
    --publish-bridge "$(plan_get PUBLISH_BRIDGE)" \
    --proxy-ip "$(plan_get PROXY_IP)" \
    --ingress-relay "$(plan_get INGRESS_RELAY_IP)" \
    --ingress-upstream "$(plan_get INGRESS_UPSTREAM_IP)" \
    --ingress-port 8080 \
    --fixture-ip "$(plan_get FIXTURE_IP)" \
    --fixture-port 8443 \
    --dns-sink "$DNS_SINK_IP" \
    --app-network "$(plan_get APP_NETWORK)" \
    --egress-network "$(plan_get EGRESS_NETWORK)" \
    --ingress-network "$(plan_get INGRESS_NETWORK)" \
    --publish-network "$(plan_get PUBLISH_NETWORK)"
  if ! timeout 5 curl -fsS "http://127.0.0.1:$(plan_get PORT)/" | grep -q ok; then
    stage_fail "loopback ingress failed after nft"
  fi
  client_exec 25 https "https://api.github.com/" | grep -q '^200 ' || stage_fail "proxy path failed after nft"
  quiet_tunnel "quiet tunnel after nft"
  run_in "$client_id" 25 https "https://opencode.ai/"
  if [ "$run_code" -eq 0 ]; then
    record_case post-rule-opencode PASS "unauthenticated GET through the proxy $(out_detail)"
  else
    record_case post-rule-opencode FAIL "exit ${run_code} $(out_detail) $(err_detail)"
  fi
  run_in "$client_id" 8 route-ip "$(plan_get PROXY_IP)" 3128
  app_ip=$(tr -d '[:space:]' < "$stage_dir/last.out")
  case "$app_ip" in
    *.*.*.*) ;;
    *) app_ip="" ;;
  esac
  if [ -z "$app_ip" ]; then
    record_case sport3128-allow FAIL "route-ip did not return an address $(err_detail)"
  else
  run_in "$client_id" 8 bind "$(plan_get PROXY_IP)" 3128 3128 "$app_ip"
  if [ "$run_code" -eq 0 ] && grep -F -q "connected ${app_ip}:3128" "$stage_dir/last.out"; then
    record_case sport3128-allow PASS "handshake to the proxy on 3128 from ${app_ip}:3128"
  else
    record_case sport3128-allow FAIL "exit ${run_code} $(out_detail) $(err_detail)"
  fi
  fi
  sport3128_ok=0
  if grep -q '^sport3128-allow PASS ' "$case_file"; then
    sport3128_ok=1
  fi
  if [ "$sport3128_ok" -ne 1 ]; then
    record_case sport3128-proxy443 NOT-EXERCISED "source port 3128 was not shown to connect"
  else
    before=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || before=""
    run_in "$client_id" 8 bind "$(plan_get PROXY_IP)" 443 3128 "$app_ip"
    after=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || after=""
    if [ "$run_code" -eq 0 ]; then
      record_case sport3128-proxy443 ESCAPE "handshake to proxy port 443 from source port 3128"
    elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
      record_case sport3128-proxy443 PASS "denied and the app bridge drop counter moved ${before} to ${after}"
    else
      record_case sport3128-proxy443 NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
    fi
  fi
  proof8080=0
  if release_health; then
    run_in "$client_id" 8 bind-proof 8080 "$(plan_get INGRESS_UPSTREAM_IP)"
    if [ "$run_code" -eq 0 ] && grep -F -q "connected $(plan_get INGRESS_UPSTREAM_IP):8080" "$stage_dir/last.out"; then
      record_case sport8080-proof PASS "handshake on the ingress address from source port 8080 without nft on that path"
      proof8080=1
    else
      record_case sport8080-proof NOT-EXERCISED "exit ${run_code} $(err_detail)"
    fi
  else
    record_case sport8080-proof NOT-EXERCISED "health listener did not release port 8080"
  fi
  if [ "$proof8080" -ne 1 ]; then
    record_case sport8080-relay NOT-EXERCISED "source port 8080 was not shown to bind"
    record_case sport8080-gateway NOT-EXERCISED "source port 8080 was not shown to bind"
  else
    run_in "$client_id" 8 bind "$(plan_get INGRESS_RELAY_IP)" 8080 8080 "$(plan_get INGRESS_UPSTREAM_IP)"
    if [ "$run_code" -eq 0 ]; then
      record_case sport8080-relay ESCAPE "new flow from the listen port reached the relay"
    elif [ "$run_code" -eq 3 ]; then
      record_case sport8080-relay NOT-EXERCISED "bind failed $(err_detail)"
    elif [ "$run_code" -eq 1 ]; then
      record_case sport8080-relay PASS "new flow from $(plan_get INGRESS_UPSTREAM_IP):8080 to the relay was denied $(err_detail)"
    else
      record_case sport8080-relay NOT-EXERCISED "exit ${run_code} $(err_detail)"
    fi
    before=$(nft_packets bridge input "meta ibrname \"$(plan_get INGRESS_BRIDGE)\" ether type ip counter") || before=""
    run_in "$client_id" 8 bind "$(plan_get INGRESS_GATEWAY)" 443 8080 "$(plan_get INGRESS_UPSTREAM_IP)"
    after=$(nft_packets bridge input "meta ibrname \"$(plan_get INGRESS_BRIDGE)\" ether type ip counter") || after=""
    if [ "$run_code" -eq 0 ]; then
      record_case sport8080-gateway ESCAPE "source port 8080 reached the ingress gateway"
    elif [ "$run_code" -eq 3 ]; then
      record_case sport8080-gateway NOT-EXERCISED "bind failed $(err_detail)"
    elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
      record_case sport8080-gateway PASS "denied and the ingress bridge input drop moved ${before} to ${after}"
    else
      record_case sport8080-gateway NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
    fi
  fi
  if restore_health && timeout 5 curl -fsS "http://127.0.0.1:$(plan_get PORT)/" | grep -q ok; then
    record_case health-restored PASS "loopback health answered after the listen port was released"
  else
    record_case health-restored FAIL "loopback health did not answer after restoring the listener"
  fi
  run_in "$client_id" 8 bind "$(plan_get INGRESS_GATEWAY)" 443 443 "$(plan_get INGRESS_UPSTREAM_IP)"
  if [ "$run_code" -eq 0 ]; then
    record_case sport443-bind ESCAPE "source port 443 opened a flow"
  elif [ "$run_code" -eq 1 ]; then
    record_case sport443-bind PASS "source port 443 was bindable and the flow was denied $(err_detail)"
  else
    record_case sport443-bind NOT-EXERCISED "exit ${run_code} $(err_detail)"
  fi
  before=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || before=""
  run_in "$client_id" 8 direct "$(plan_get PROXY_IP)" 443
  after=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || after=""
  if [ "$run_code" -eq 0 ]; then
    record_case direct-tcp-proxy443 ESCAPE "direct tcp to the proxy on 443 completed"
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
    record_case direct-tcp-proxy443 PASS "numeric tcp denied and the app bridge drop moved ${before} to ${after}"
  else
    record_case direct-tcp-proxy443 NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
  fi
  if ! "$root/stage-route.sh" \
    --docker "$docker_cmd" \
    --container "$client_id" \
    --project "$(plan_get PROJECT)" \
    --service client \
    --dest "$(plan_get FIXTURE_IP)" \
    --via "$(plan_get PROXY_IP)" \
    >"$stage_dir/route.out" 2>"$stage_dir/route.err"
  then
    route_detail=$(tr '\n' ' ' < "$stage_dir/route.err" | awk '{ print substr($0, 1, 180) }')
    record_case direct-tcp-fixture-ip NOT-EXERCISED "stage route was not installed: ${route_detail}"
    record_case proxy-false-fixture NOT-EXERCISED "stage route was not installed: ${route_detail}"
  else
    before=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || before=""
    run_in "$client_id" 8 direct "$(plan_get FIXTURE_IP)" 8443
    after=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || after=""
    if [ "$run_code" -eq 0 ]; then
      record_case direct-tcp-fixture-ip ESCAPE "client reached the fixture ip without the proxy $(err_detail)"
    elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
      record_case direct-tcp-fixture-ip PASS "numeric tcp to the fixture was dropped ${before} to ${after} $(err_detail)"
    else
      record_case direct-tcp-fixture-ip NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
    fi
    run_in "$client_id" 20 https "https://idle.fixture:8443/"
    if [ "$run_code" -ne 0 ] || ! grep -q '^200 ' "$stage_dir/last.out"; then
      record_case proxy-false-fixture NOT-EXERCISED "proxied fixture TLS did not return 200 $(out_detail) $(err_detail)"
    else
      before=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || before=""
      run_in "$client_id" 12 fetch-direct "https://$(plan_get FIXTURE_IP):8443/" idle.fixture
      after=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || after=""
      if [ "$run_code" -eq 0 ]; then
        record_case proxy-false-fixture ESCAPE "proxy-disabled fetch reached the fixture $(out_detail)"
      elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
        record_case proxy-false-fixture PASS "proxy disabled and the numeric TLS fetch was dropped ${before} to ${after} $(err_detail)"
      else
        record_case proxy-false-fixture NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(out_detail) $(err_detail)"
      fi
    fi
  fi
  run_in "$client_id" 8 dns canary.stage.test
  canary=$(tr -d '[:space:]' < "$stage_dir/last.out")
  run_in "$client_id" 8 dns example.com
  if [ "$canary" = "192.0.2.55" ] && [ "$run_code" -ne 0 ] && grep -F -q -x canary.stage.test "$stage_dir/dns/queries" && grep -F -q -x example.com "$stage_dir/dns/queries"; then
    record_case dns-system PASS "canary resolved only from the stage sink and example.com was refused there"
  elif [ "$run_code" -eq 0 ]; then
    record_case dns-system FAIL "system resolver returned an address for example.com $(out_detail)"
  else
    record_case dns-system NOT-EXERCISED "canary ${canary} exit ${run_code} $(err_detail)"
  fi
  run_in "$client_id" 8 dns-udp 127.0.0.11 example.com
  dns_udp=$(tr -d '[:space:]' < "$stage_dir/last.out")
  if printf '%s' "$dns_udp" | grep -q 'ANSWER'; then
    record_case dns-udp-127.0.0.11 FAIL "stub returned an answer ${dns_udp}"
  elif printf '%s' "$dns_udp" | grep -q 'NOANSWER rcode=5' && grep -F -q -x example.com "$stage_dir/dns/queries"; then
    record_case dns-udp-127.0.0.11 PASS "stub forwarded example.com to the stage sink and got REFUSED"
  else
    record_case dns-udp-127.0.0.11 NOT-EXERCISED "exit ${run_code} ${dns_udp} $(err_detail)"
  fi
  sink_ip=$(awk -F= '/^DNS_SINK_IP=/{ print $2 }' "$env_file")
  run_in "$client_id" 8 dns-tcp "$sink_ip" example.com 53
  dns_tcp=$(tr -d '[:space:]' < "$stage_dir/last.out")
  if printf '%s' "$dns_tcp" | grep -q 'ANSWER'; then
    record_case dns-tcp-sink FAIL "direct tcp to the sink answered ${dns_tcp}"
  elif printf '%s' "$dns_tcp" | grep -q 'NOANSWER rcode=5' && grep -F -q -x example.com "$stage_dir/dns/queries"; then
    record_case dns-tcp-sink PASS "direct tcp/53 to the stage sink was REFUSED"
  else
    record_case dns-tcp-sink NOT-EXERCISED "exit ${run_code} ${dns_tcp} $(err_detail)"
  fi
  run_in "$fixture_id" 8 direct "$(plan_get FIXTURE_IP)" 8443
  if [ "$run_code" -ne 0 ]; then
    record_case host-local-443 NOT-EXERCISED "fixture could not handshake to its own listener exit ${run_code} $(err_detail)"
  else
    before=$(nft_packets inet input "iifname \"$(plan_get EGRESS_BRIDGE)\" counter") || before=""
    run_in "$fixture_id" 8 direct "$(plan_get EGRESS_GATEWAY)" 443
    after=$(nft_packets inet input "iifname \"$(plan_get EGRESS_BRIDGE)\" counter") || after=""
    if [ "$run_code" -eq 0 ]; then
      record_case host-local-443 ESCAPE "fixture completed tcp to the egress gateway on 443"
    elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
      record_case host-local-443 PASS "denied and the inet input drop moved ${before} to ${after}"
    else
      record_case host-local-443 NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
    fi
  fi
  before=$(nft_packets bridge input "meta ibrname \"$(plan_get EGRESS_BRIDGE)\" ether type ip counter") || before=""
  run_in "$fixture_id" 8 udp 192.0.2.1 443
  after=$(nft_packets bridge input "meta ibrname \"$(plan_get EGRESS_BRIDGE)\" ether type ip counter") || after=""
  udp_out=$(tr -d '[:space:]' < "$stage_dir/last.out")
  if [ "$udp_out" = "reply" ] || [ "$run_code" -eq 0 ]; then
    record_case udp-quic-443 ESCAPE "udp port 443 received a reply"
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$udp_out" = "none" ]; then
    record_case udp-quic-443 PASS "no reply and the egress bridge input drop moved ${before} to ${after}"
  else
    record_case udp-quic-443 NOT-EXERCISED "exit ${run_code} ${udp_out} counter ${before}->${after} $(err_detail)"
  fi
  for spec in private-10:10.9.9.9 metadata-link-local:169.254.169.254 cgnat-tailscale-range:100.64.1.1; do
    name=${spec%%:*}
    dest=${spec#*:}
    before=$(nft_packets inet forward "iifname \"$(plan_get EGRESS_BRIDGE)\" ip daddr @bogon4 counter") || before=""
    run_in "$fixture_id" 8 direct "$dest" 443
    after=$(nft_packets inet forward "iifname \"$(plan_get EGRESS_BRIDGE)\" ip daddr @bogon4 counter") || after=""
    if [ "$run_code" -eq 0 ]; then
      record_case "$name" ESCAPE "tcp 443 to ${dest} completed"
    elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
      record_case "$name" PASS "denied and the bogon drop moved ${before} to ${after}"
    else
      record_case "$name" NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
    fi
  done
  before=$(nft_packets bridge input "meta ibrname \"$(plan_get EGRESS_BRIDGE)\" ether type ip counter") || before=""
  run_in "$fixture_id" 8 udp 192.0.2.1 53
  after=$(nft_packets bridge input "meta ibrname \"$(plan_get EGRESS_BRIDGE)\" ether type ip counter") || after=""
  udp_out=$(tr -d '[:space:]' < "$stage_dir/last.out")
  if [ "$udp_out" = "reply" ] || [ "$run_code" -eq 0 ]; then
    record_case dns-udp-external ESCAPE "udp/53 received a reply"
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$udp_out" = "none" ]; then
    record_case dns-udp-external PASS "udp/53 to 192.0.2.1 was dropped ${before} to ${after}"
  else
    record_case dns-udp-external NOT-EXERCISED "exit ${run_code} ${udp_out} counter ${before}->${after} $(err_detail)"
  fi
  before=$(nft_packets bridge input "meta ibrname \"$(plan_get EGRESS_BRIDGE)\" ether type ip counter") || before=""
  run_in "$fixture_id" 8 direct 192.0.2.1 53
  after=$(nft_packets bridge input "meta ibrname \"$(plan_get EGRESS_BRIDGE)\" ether type ip counter") || after=""
  if [ "$run_code" -eq 0 ]; then
    record_case dns-tcp-external ESCAPE "tcp/53 to 192.0.2.1 completed"
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
    record_case dns-tcp-external PASS "tcp/53 to 192.0.2.1 was dropped ${before} to ${after} $(err_detail)"
  else
    record_case dns-tcp-external NOT-EXERCISED "exit ${run_code} counter ${before}->${after} $(err_detail)"
  fi
  before=$(nft_packets bridge input "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || before=""
  run_in "$client_id" 8 udp "$(plan_get APP_GATEWAY)" 53
  after=$(nft_packets bridge input "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || after=""
  udp_out=$(tr -d '[:space:]' < "$stage_dir/last.out")
  if [ "$udp_out" = "reply" ] || [ "$run_code" -eq 0 ]; then
    record_case dns-host-gateway ESCAPE "udp/53 to the app gateway received a reply"
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$udp_out" = "none" ]; then
    record_case dns-host-gateway PASS "udp/53 toward the host gateway was dropped ${before} to ${after}"
  else
    record_case dns-host-gateway NOT-EXERCISED "exit ${run_code} ${udp_out} counter ${before}->${after} $(err_detail)"
  fi
  ipv6_on=0
  for net in "$(plan_get APP_NETWORK)" "$(plan_get EGRESS_NETWORK)" "$(plan_get INGRESS_NETWORK)" "$(plan_get PUBLISH_NETWORK)"; do
    enabled=$("$docker_cmd" network inspect "$net" --format '{{.EnableIPv6}}') || enabled=missing
    if [ "$enabled" != "false" ]; then
      ipv6_on=1
    fi
  done
  for id in "$client_id" "$fixture_id" "$proxy_id" "$ingress_id" "$dns_id"; do
    if "$docker_cmd" inspect "$id" --format '{{json .NetworkSettings.Networks}}' | grep -Eq '"GlobalIPv6Address":"[0-9a-fA-F:]'; then
      ipv6_on=1
    fi
  done
  if [ "$ipv6_on" -eq 0 ]; then
    record_case ipv6-disabled PASS "stage networks and containers have IPv6 disabled; this is not a runtime filter proof"
  else
    record_case ipv6-disabled FAIL "a stage network or container has IPv6 enabled"
  fi
  run_in "$client_id" 15 https "https://idle.fixture:8443/redir"
  redirect_status=$(awk '{ print $1; exit }' "$stage_dir/last.out")
  run_in "$client_id" 15 https "https://blocked.fixture:8443/nope"
  if [ "$redirect_status" = "302" ] && [ "$run_code" -ne 0 ] && grep -q '403' "$stage_dir/last.err" && grep -q 'Proxy refused to open a tunnel' "$stage_dir/last.err"; then
    record_case redirect PASS "fixture returned 302 and the proxy refused the new CONNECT with 403 $(err_detail)"
  elif [ "$run_code" -eq 0 ]; then
    record_case redirect ESCAPE "blocked fixture request succeeded $(out_detail)"
  else
    record_case redirect FAIL "redirect ${redirect_status} blocked $(out_detail) $(err_detail)"
  fi
  if ! timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" stop proxy; then
    record_case proxy-down NOT-EXERCISED "proxy did not stop"
    record_case proxy-restored NOT-EXERCISED "proxy was not stopped"
  else
  run_in "$client_id" 15 https "https://api.github.com/"
  if [ "$run_code" -eq 0 ]; then
    record_case proxy-down ESCAPE "github succeeded while the proxy was stopped"
  else
    record_case proxy-down PASS "no success within 15s exit ${run_code}; bounded observation, not an unlimited fail-closed proof"
  fi
  if ! timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" start proxy; then
    record_case proxy-restored FAIL "proxy did not start"
    proxy_back=0
  else
  proxy_back=0
  i=0
  while [ "$i" -lt 5 ]; do
    run_in "$client_id" 20 https "https://api.github.com/"
    if [ "$run_code" -eq 0 ] && grep -q '^200 ' "$stage_dir/last.out"; then
      proxy_back=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$proxy_back" -eq 1 ]; then
    record_case proxy-restored PASS "allowed github path answered after the proxy started again"
  elif ! grep -q '^proxy-restored ' "$case_file"; then
    record_case proxy-restored FAIL "allowed path did not return after the proxy started"
  fi
  fi
  fi
  before=$(nft_packets bridge input "meta ibrname \"$(plan_get PUBLISH_BRIDGE)\" ether type ip counter") || before=""
  relay_code=0
  timeout 8 "$docker_cmd" exec "$ingress_id" socat -T 3 TCP:192.0.2.1:443 - >"$stage_dir/last.out" 2>"$stage_dir/last.err" || relay_code=$?
  after=$(nft_packets bridge input "meta ibrname \"$(plan_get PUBLISH_BRIDGE)\" ether type ip counter") || after=""
  if [ "$relay_code" -eq 0 ]; then
    record_case relay-egress ESCAPE "relay opened tcp to 192.0.2.1:443"
  elif [ "$relay_code" -eq 127 ]; then
    record_case relay-egress NOT-EXERCISED "socat is not available in the relay"
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
    record_case relay-egress PASS "relay egress failed and the publish bridge input drop moved ${before} to ${after}"
  else
    record_case relay-egress NOT-EXERCISED "exit ${relay_code} counter ${before}->${after} $(err_detail)"
  fi
  neighbor_ip=$(awk -F= '/^NEIGHBOR_IP=/{ print $2 }' "$env_file")
  if ! timeout 90 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" --profile oracle up -d neighbor; then
    record_case cold-neighbor NOT-EXERCISED "neighbor container did not start"
  else
    before=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || before=""
    flags_before=$("$docker_cmd" exec "$client_id" cat /proc/net/arp | awk -v ip="$neighbor_ip" '$1 == ip { print $3 }')
    run_in "$client_id" 8 direct "$neighbor_ip" 443
    after=$(nft_packets bridge forward "meta ibrname \"$(plan_get APP_BRIDGE)\" ether type ip counter") || after=""
    flags_after=$("$docker_cmd" exec "$client_id" cat /proc/net/arp | awk -v ip="$neighbor_ip" '$1 == ip { print $3 }')
    if [ "$run_code" -eq 0 ]; then
      record_case cold-neighbor ESCAPE "new neighbor accepted tcp/443"
    elif [ -z "$flags_before" ] && [ -n "$flags_after" ] && [ "$flags_after" != "0x0" ] && [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ] && [ "$run_code" -eq 1 ]; then
      record_case cold-neighbor PASS "new ARP ${flags_after} and the app bridge drop moved ${before} to ${after}"
    else
      record_case cold-neighbor NOT-EXERCISED "arp ${flags_before}->${flags_after} exit ${run_code} counter ${before}->${after} $(err_detail)"
    fi
  fi
  for name in sport3128-allow sport3128-proxy443 sport8080-proof sport8080-relay sport8080-gateway health-restored sport443-bind direct-tcp-proxy443 direct-tcp-fixture-ip proxy-false-fixture post-rule-opencode dns-system dns-udp-127.0.0.11 dns-tcp-sink dns-udp-external dns-tcp-external dns-host-gateway host-local-443 udp-quic-443 private-10 metadata-link-local cgnat-tailscale-range ipv6-disabled redirect cold-neighbor proxy-down proxy-restored relay-egress; do
    if ! grep -q "^${name} " "$case_file"; then
      record_case "$name" NOT-EXERCISED "case was not recorded"
    fi
  done
  echo "case results:"
  cat "$case_file"
  if grep -Ev '^[^ ]+ PASS ' "$case_file" | grep -q .; then
    stage_fail "negative matrix incomplete"
  fi
  print_inventory
  echo "containers and inet $(plan_get TABLE) were left in place"
  echo "a quiet result before nft is not the post-rule result"
  echo "stop containers only: $root/host-stage.sh stop --plan $plan_file"
}
stop_stage() {
  [ -n "$plan_file" ] && [ -f "$plan_file" ] || {
    echo "stop needs --plan" >&2
    exit 1
  }
  stage_dir=$(plan_get STAGE_DIR)
  env_file="$stage_dir/env"
  [ -f "$env_file" ] || {
    echo "env file is missing; not guessing a project" >&2
    exit 1
  }
  stop_project_containers
  echo "stopped containers for $(plan_get PROJECT)"
  echo "nft inet $(plan_get TABLE) was not removed"
  print_inventory
}

case "$action" in
  plan) choose_plan ;;
  preflight) preflight_plan ;;
  run) run_stage ;;
  stop) stop_stage ;;
  collect) collect_inventory ;;
  inventory)
    [ -n "$plan_file" ] && [ -f "$plan_file" ] || usage
    print_inventory
    ;;
esac
