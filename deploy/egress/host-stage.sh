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
    b83c52|sb83c52|vvrstb83c52|vvrstb83c52a|vvrstb83c52e|vvrstb83c52i|vvrstb83c52p|br-vvr-sb83c52a|br-vvr-sb83c52e|br-vvr-sb83c52i|br-vvr-sb83c52p|reviewer_egress_sb83c52|172.30.154.0/24|172.30.155.0/24|172.30.156.0/24|172.30.157.0/24|20566)
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

stage_fail() {
  echo "FAIL: $1" >&2
  echo "stopping staged containers; networks, files, and nft tables stay" >&2
  if [ -n "${env_file:-}" ] && [ -f "$env_file" ]; then
    timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" stop >&2 || true
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
  mkdir -p "$stage_dir/delay" "$stage_dir/fixture" "$stage_dir/client" "$stage_dir/empty"
  printf '0\n' > "$stage_dir/delay/ms"
  cp "$root/testdata/fixture.js" "$root/testdata/health.js" "$root/testdata/client.js" "$stage_dir/"
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
  chmod 0444 "$stage_dir/squid.conf" "$stage_dir/fixture.js" "$stage_dir/health.js" "$stage_dir/client.js"
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
IDLE_MS=$((idle_seconds * 1000))
EOF
  rendered=$(timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" config)
  printf '%s\n' "$rendered" | grep -q 'internal: true' || stage_fail "rendered compose is not an internal app network"
  printf '%s\n' "$rendered" | grep -q 'enable_ip_masquerade: "false"' || stage_fail "publish network masquerades"
  if printf '%s\n' "$rendered" | grep -q 'NET_BIND_SERVICE\|network_mode: host\|docker.sock'; then
    stage_fail "rendered compose adds a capability, the host network, or the docker socket"
  fi
  timeout 600 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" build proxy ingress
  timeout 180 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" up -d proxy fixture client ingress
  client_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q client)
  ingress_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q ingress)
  proxy_id=$("$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" ps -q proxy)
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
  client_exec 25 https "https://api.github.com/" | grep -q '^200 ' || stage_fail "api.github.com"
  client_exec 25 https "https://opencode.ai/" >/dev/null || stage_fail "opencode.ai"
  client_exec 20 https "https://example.com/" && stage_fail "example.com was allowed"
  client_exec 20 https "https://idle.fixture:8443/" | grep -q '^200 ' || stage_fail "fixture handshake"
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
  bound_flow() {
    code=0
    timeout 8 "$docker_cmd" exec "$client_id" bun /opt/client.js bind "$1" "$2" "$3" || code=$?
    if [ "$code" -eq 0 ]; then
      if [ "$4" = "allow" ]; then
        return 0
      fi
      stage_fail "new flow from local port $3 to $1:$2 was accepted"
    fi
    if [ "$4" = "allow" ]; then
      stage_fail "allowed flow from local port $3 to $1:$2 exited $code"
    fi
    if [ "$code" -eq 3 ]; then
      stage_fail "could not bind local port $3, so $1:$2 was not exercised"
    fi
    if [ "$code" -ne 1 ]; then
      stage_fail "bind check from local port $3 to $1:$2 exited $code"
    fi
  }
  quiet_tunnel "quiet tunnel before nft"
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
    --app-network "$(plan_get APP_NETWORK)" \
    --egress-network "$(plan_get EGRESS_NETWORK)" \
    --ingress-network "$(plan_get INGRESS_NETWORK)" \
    --publish-network "$(plan_get PUBLISH_NETWORK)"
  if ! timeout 5 curl -fsS "http://127.0.0.1:$(plan_get PORT)/" | grep -q ok; then
    stage_fail "loopback ingress failed after nft"
  fi
  client_exec 25 https "https://api.github.com/" | grep -q '^200 ' || stage_fail "proxy path failed after nft"
  client_exec 12 proxy-false "https://api.github.com/" && stage_fail "direct path stayed open"
  bound_flow "$(plan_get PROXY_IP)" 3128 3128 allow
  bound_flow "$(plan_get PROXY_IP)" 443 3128 deny
  bound_flow "$(plan_get INGRESS_RELAY_IP)" 8080 8080 deny
  bound_flow "$(plan_get INGRESS_GATEWAY)" 443 8080 deny
  bound_flow "$(plan_get FIXTURE_IP)" 443 3128 deny
  code=0
  timeout 8 "$docker_cmd" exec "$client_id" bun /opt/client.js bind "$(plan_get INGRESS_GATEWAY)" 443 443 || code=$?
  if [ "$code" -eq 0 ]; then
    stage_fail "source port 443 opened a new flow"
  fi
  if [ "$code" -eq 1 ]; then
    echo "source port 443 was bindable and the new flow was denied"
  elif [ "$code" -eq 3 ]; then
    echo "source port 443 could not be bound without privilege; that runtime check was not exercised"
  else
    stage_fail "source port 443 check exited $code"
  fi
  code=0
  dns_out=$(timeout 8 "$docker_cmd" exec "$client_id" bun /opt/client.js dns example.com) || code=$?
  if [ "$code" -eq 0 ]; then
    stage_fail "example.com resolved after nft: ${dns_out}"
  fi
  if [ "$code" -eq 124 ]; then
    stage_fail "dns check did not finish"
  fi
  code=0
  timeout 8 "$docker_cmd" exec "$client_id" bun /opt/client.js direct 2001:db8::1 443 || code=$?
  if [ "$code" -ne 1 ]; then
    stage_fail "ipv6 check exited $code"
  fi
  quiet_tunnel "quiet tunnel after nft"
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
  timeout 60 "$docker_cmd" compose --env-file "$env_file" -f "$root/compose.yml" -f "$root/compose.test.yml" stop
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
