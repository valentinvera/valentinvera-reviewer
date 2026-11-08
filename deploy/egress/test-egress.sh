#!/bin/sh
# Isolated egress proof. Uses its own Compose project, subnet and loopback
# port. It does not read production secrets or mount production data.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$root/../.." && pwd)
idle_seconds="${EGRESS_IDLE_SECONDS:-310}"
case "$idle_seconds" in
  ''|*[!0-9]*) echo "EGRESS_IDLE_SECONDS must be a number of seconds" >&2; exit 1 ;;
esac
if [ "$idle_seconds" -lt 310 ]; then
  echo "warning: EGRESS_IDLE_SECONDS=$idle_seconds is below the 310s Bun idle proof" >&2
fi

project=reviewer-egress-ci
table=reviewer_egress_ci
app_bridge=br-vvr-cia
egress_bridge=br-vvr-cie
port=13111
app_subnet=172.30.209.0/24
app_gateway=172.30.209.1
proxy_ip=172.30.209.2
egress_subnet=172.30.217.0/24
egress_gateway=172.30.217.1
fixture_ip=172.30.217.10
docker="${DOCKER:-sudo docker}"

work=$(mktemp -d)
cleanup() {
  set +e
  if [ -f "$work/env" ]; then
    $docker compose --env-file "$work/env" -f "$root/compose.yml" -f "$root/compose.test.yml" down --remove-orphans >/dev/null 2>&1
  fi
  if [ -x "$root/host-rules.sh" ]; then
    sudo "$root/host-rules.sh" rollback --table "$table" --app-bridge "$app_bridge" --egress-bridge "$egress_bridge" >/dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT

step() {
  echo
  echo "== $1"
}

fail() {
  echo "FAIL: $1" >&2
  $docker compose --env-file "$work/env" -f "$root/compose.yml" -f "$root/compose.test.yml" logs --tail 80 >&2 || true
  exit 1
}

expect_fail() {
  if "$@"; then
    fail "command succeeded and must not: $*"
  fi
}

step "render the production proxy config"
rendered=$("$root/render-squid-conf.sh" --bind 172.30.208.2:3128 --src 172.30.208.0/24 --allow-file "$root/allowlist")
printf '%s\n' "$rendered" | cmp -s - "$root/squid.conf" || fail "squid.conf drifted from the renderer"
printf '%s\n' "$rendered" | grep -q 'acl allowed dstdomain api.github.com' || fail "github missing"
printf '%s\n' "$rendered" | grep -q 'acl allowed dstdomain opencode.ai' || fail "opencode missing"
printf '%s\n' "$rendered" | grep -q 'read_timeout 35 minutes' || fail "quiet timeout missing"
if printf '%s\n' "$rendered" | grep -q 'ssl_bump\|fixture_name'; then
  fail "production config contains a test exception or TLS inspection"
fi
expect_fail "$root/render-squid-conf.sh" --bind 0.0.0.0:3128 --src 172.30.208.0/24 --allow-file "$root/allowlist" >/dev/null
expect_fail "$root/host-rules.sh" status --table reviewer_egress --app-bridge br-f5d584fd553b --egress-bridge br-vvr-egress >/dev/null

mkdir -p "$work/delay" "$work/certs" "$work/empty"
printf '0\n' > "$work/delay/ms"
cp "$root/testdata/fixture.js" "$root/testdata/health.js" "$root/testdata/client.js" "$work/"
cat > "$work/allowlist" <<'EOF'
api.github.com
opencode.ai
metadata.test
lan.test
cgnat.test
loop.test
EOF

step "local fixture certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$work/certs/ca.key" -out "$work/certs/ca.crt" -days 1 -nodes -subj /CN=egress-test-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -keyout "$work/certs/srv.key" -out "$work/certs/srv.csr" -nodes -subj /CN=idle.fixture >/dev/null 2>&1
printf 'subjectAltName=DNS:idle.fixture,DNS:blocked.fixture\n' > "$work/certs/san.cnf"
openssl x509 -req -in "$work/certs/srv.csr" -CA "$work/certs/ca.crt" -CAkey "$work/certs/ca.key" -CAcreateserial \
  -out "$work/certs/srv.crt" -days 1 -extfile "$work/certs/san.cnf" >/dev/null 2>&1

"$root/render-squid-conf.sh" \
  --bind "${proxy_ip}:3128" \
  --src "$app_subnet" \
  --allow-file "$work/allowlist" \
  --fixture-name idle.fixture \
  --fixture-dst "${fixture_ip}/32" \
  > "$work/squid.conf"
grep -q 'acl fixture_name dstdomain idle.fixture' "$work/squid.conf" || fail "test fixture exception missing"

cat > "$work/env" <<EOF
EGRESS_PROJECT_NAME=$project
EGRESS_IMAGE_TAG=ci
REVIEWER_BIND_PORT=$port
REVIEWER_IMAGE=oven/bun:1.4.4
REVIEWER_DATA_DIR=$work/empty
REVIEWER_BACKUP_DIR=$work/empty
REVIEWER_SECRETS_DIR=$work/empty
APP_SUBNET=$app_subnet
APP_GATEWAY=$app_gateway
PROXY_IP=$proxy_ip
APP_NETWORK_NAME=vvr-ci-app
EGRESS_NETWORK_NAME=vvr-ci-egress
APP_BRIDGE=$app_bridge
EGRESS_BRIDGE=$egress_bridge
EGRESS_SUBNET=$egress_subnet
EGRESS_GATEWAY=$egress_gateway
TEST_CONF=$work/squid.conf
TEST_DIR=$work
FIXTURE_IP=$fixture_ip
IDLE_MS=$((idle_seconds * 1000))
EOF

compose() {
  $docker compose --env-file "$work/env" -f "$root/compose.yml" -f "$root/compose.test.yml" "$@"
}

step "build the pinned proxy image"
compose build proxy
image_id=$(compose images -q proxy | head -n 1)
if [ -z "$image_id" ]; then
  image_id=$($docker image inspect "valentinvera-reviewer-egress:ci" --format '{{.Id}}')
fi
echo "proxy image id $image_id"
$docker run --rm --entrypoint squid "valentinvera-reviewer-egress:ci" -v
$docker run --rm --user 31:31 --tmpfs /tmp:uid=31,gid=31 \
  -e PROXY_BIND=172.30.209.2:3128 \
  -e PROXY_SRC=172.30.209.0/24 \
  --entrypoint /bin/sh "valentinvera-reviewer-egress:ci" \
  -c '/usr/local/bin/render-squid-conf.sh --bind "$PROXY_BIND" --src "$PROXY_SRC" --allow-file /etc/egress/allowlist > /tmp/squid.conf && squid -k parse -f /tmp/squid.conf'
echo "rendered proxy config parsed"

step "entrypoint refuses a bypass and an open network"
expect_fail $docker run --rm \
  -e EGRESS_REQUIRED=1 \
  -v "$root/app-entrypoint.sh:/usr/local/bin/app-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/app-entrypoint.sh \
  oven/bun:1.4.4 /bin/true
expect_fail $docker run --rm --dns 127.0.0.1 \
  -e EGRESS_REQUIRED=1 \
  -e EGRESS_PROXY_URL=http://172.30.209.2:3128 \
  -e HTTPS_PROXY=http://172.30.209.2:3128 \
  -e HTTP_PROXY=http://172.30.209.2:3128 \
  -e ALL_PROXY=http://172.30.209.2:3128 \
  -v "$root/app-entrypoint.sh:/usr/local/bin/app-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/app-entrypoint.sh \
  oven/bun:1.4.4 /bin/true
expect_fail $docker run --rm --dns 127.0.0.1 \
  -e EGRESS_REQUIRED=1 \
  -e EGRESS_PROXY_URL=http://172.30.209.2:3128 \
  -e HTTPS_PROXY=http://172.30.209.2:3128 \
  -e HTTP_PROXY=http://172.30.209.2:3128 \
  -e ALL_PROXY=http://172.30.209.2:3128 \
  -e NO_PROXY=example.com \
  -v "$root/app-entrypoint.sh:/usr/local/bin/app-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/app-entrypoint.sh \
  oven/bun:1.4.4 /bin/true
expect_fail $docker run --rm --dns 8.8.8.8 \
  -e EGRESS_REQUIRED=1 \
  -e EGRESS_PROXY_URL=http://172.30.209.2:3128 \
  -e HTTPS_PROXY=http://172.30.209.2:3128 \
  -e HTTP_PROXY=http://172.30.209.2:3128 \
  -e ALL_PROXY=http://172.30.209.2:3128 \
  -v "$root/app-entrypoint.sh:/usr/local/bin/app-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/app-entrypoint.sh \
  oven/bun:1.4.4 /bin/true

step "start the isolated project"
compose up -d --wait proxy fixture client
client_id=$(compose ps -q client)
proxy_id=$(compose ps -q proxy)
echo "client $client_id proxy $proxy_id"

resolv=$($docker exec "$client_id" cat /etc/resolv.conf)
echo "$resolv"
printf '%s\n' "$resolv" | grep -q 'ExtServers: \[127.0.0.1\]' || fail "client DNS upstream is not loopback"
proxy_resolv=$($docker exec "$proxy_id" cat /etc/resolv.conf)
echo "$proxy_resolv"
printf '%s\n' "$proxy_resolv" | grep -q '127.0.0.11' || fail "proxy is not using Docker DNS"
printf '%s\n' "$proxy_resolv" | grep -q 'ExtServers: \[127.0.0.1\]' && fail "proxy DNS was pinned to loopback"
routes=$($docker exec "$client_id" cat /proc/net/ipv6_route 2>/dev/null || true)
echo "client ipv6 routes: ${routes:-none}"
if printf '%s\n' "$routes" | awk '$1 ~ /^0+$/ && $2 == "00" && $10 != "lo" { found=1 } END { exit found ? 0 : 1 }'; then
  fail "client has an IPv6 default route"
fi

client() {
  $docker exec "$client_id" bun /opt/client.js "$@"
}

step "app bridge can reach the proxy and the published port"
tcp_ok=0
publish_ok=0
if client direct "$proxy_ip" 3128; then
  tcp_ok=1
  echo "app to proxy TCP connected"
else
  echo "app to proxy TCP timed out"
fi
client_ports=$($docker inspect "$client_id" --format '{{json .NetworkSettings.Ports}}')
echo "client port map: $client_ports"
if curl -fsS --max-time 3 "http://127.0.0.1:${port}/" | grep -q ok; then
  publish_ok=1
  echo "published health ok"
else
  echo "published health failed"
fi
if [ "$tcp_ok" -ne 1 ] || [ "$publish_ok" -ne 1 ]; then
  echo "FAIL: transport proof incomplete (tcp=${tcp_ok} publish=${publish_ok})." >&2
  echo "No GitHub, OpenCode, idle-tunnel, or containment result." >&2
  echo "proxy eth0 $( $docker exec "$proxy_id" awk '$1=="eth0:" { print "rx="$2, "tx="$10 }' /proc/net/dev )" >&2
  exit 1
fi

step "allowed HTTPS through the proxy, with no request body posted"
client https https://api.github.com/ | grep -q '^200 ' || fail "api.github.com was not reachable"
client https https://opencode.ai/ >/dev/null || fail "opencode.ai tunnel failed"

step "denies other names, literals, ports and private resolutions"
expect_fail client https https://example.com/
expect_fail client https https://github.com/
expect_fail client https https://1.1.1.1/
expect_fail client https https://api.github.com:8443/
expect_fail client https http://api.github.com/
expect_fail client https https://metadata.test/
expect_fail client https https://lan.test/
expect_fail client https https://cgnat.test/
expect_fail client https https://loop.test/
expect_fail client follow https://idle.fixture/redir
expect_fail client dns example.com
expect_fail client direct 2606:4700:4700::1111 443
expect_fail client proxy-false https://api.github.com/

step "local quiet tunnel"
printf '0\n' > "$work/delay/ms"
client https https://idle.fixture/ | grep -q '^200 ' || fail "fixture handshake failed"
printf '%s\n' "$((idle_seconds * 1000))" > "$work/delay/ms"
start=$(date +%s)
client idle https://idle.fixture/slow | grep -q 'slow-ok' || fail "quiet tunnel failed"
elapsed=$(( $(date +%s) - start ))
echo "quiet tunnel elapsed ${elapsed}s"
if [ "$elapsed" -lt "$idle_seconds" ]; then
  fail "quiet tunnel ended before ${idle_seconds}s"
fi
printf '0\n' > "$work/delay/ms"

step "host rules are scoped and idempotent"
sudo iptables-save -t filter > "$work/ipt-before"
expect_fail sudo "$root/host-rules.sh" install --table "$table" --app-bridge docker0 --egress-bridge "$egress_bridge"
sudo "$root/host-rules.sh" install --table "$table" --app-bridge "$app_bridge" --egress-bridge "$egress_bridge" --proxy-ip "$proxy_ip"
sudo "$root/host-rules.sh" install --table "$table" --app-bridge "$app_bridge" --egress-bridge "$egress_bridge" --proxy-ip "$proxy_ip"
sudo "$root/host-rules.sh" status --table "$table" --app-bridge "$app_bridge" --egress-bridge "$egress_bridge" --proxy-ip "$proxy_ip"
expect_fail sudo "$root/host-rules.sh" install --table "$table" --app-bridge "$app_bridge" --egress-bridge "$egress_bridge" --proxy-ip 172.30.208.2
sudo iptables-save -t filter > "$work/ipt-after"
diff -u "$work/ipt-before" "$work/ipt-after" || fail "iptables filter table changed"

step "new app flows are dropped and published health remains"
curl -fsS "http://127.0.0.1:${port}/" | grep -q ok || fail "health failed after host rules"
client https https://api.github.com/ | grep -q '^200 ' || fail "allowed HTTPS failed after host rules"
expect_fail client proxy-false https://api.github.com/
expect_fail client proxy-false https://1.1.1.1/
expect_fail client direct "$app_gateway" 53
$docker run --rm --network vvr-ci-app --dns 127.0.0.1 \
  -e EGRESS_REQUIRED=1 \
  -e EGRESS_PROXY_URL=http://172.30.209.2:3128 \
  -e HTTPS_PROXY=http://172.30.209.2:3128 \
  -e HTTP_PROXY=http://172.30.209.2:3128 \
  -e ALL_PROXY=http://172.30.209.2:3128 \
  -v "$root/app-entrypoint.sh:/usr/local/bin/app-entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/app-entrypoint.sh \
  oven/bun:1.4.4 /bin/true

step "proxy stop fails closed without taking down health"
compose stop proxy
expect_fail client https https://api.github.com/
curl -fsS "http://127.0.0.1:${port}/" | grep -q ok || fail "health failed while the proxy was stopped"
compose start proxy
sleep 2
client https https://api.github.com/ | grep -q '^200 ' || fail "proxy did not recover"

step "rollback removes only this table"
sudo "$root/host-rules.sh" rollback --table "$table" --app-bridge "$app_bridge" --egress-bridge "$egress_bridge"
if sudo nft list table inet "$table" >/dev/null 2>&1; then
  fail "table remained after rollback"
fi
sudo iptables-save -t filter > "$work/ipt-rolled"
diff -u "$work/ipt-before" "$work/ipt-rolled" || fail "iptables filter changed across rollback"
curl -fsS "http://127.0.0.1:${port}/" | grep -q ok || fail "health failed after rollback"

echo
echo "egress tests passed (idle ${elapsed}s, image ${image_id})"
