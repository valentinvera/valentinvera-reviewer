#!/bin/sh
# Static checks for the host staging harness.
# Does not start containers, install nft rules, or delete resources.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
work=$(mktemp -d)
keep="$work"
echo "static work directory left at $keep"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "== syntax"
for script in render-squid-conf.sh proxy-entrypoint.sh app-entrypoint.sh host-rules.sh stage-perms.sh host-stage.sh; do
  sh -n "$root/$script"
done

echo "== production proxy config"
rendered=$("$root/render-squid-conf.sh" --bind 172.30.208.2:3128 --src 172.30.208.0/24 --allow-file "$root/allowlist")
printf '%s\n' "$rendered" | cmp -s - "$root/squid.conf" || fail "squid.conf drifted"
printf '%s\n' "$rendered" | grep -q 'read_timeout 35 minutes' || fail "quiet timeout missing"
if printf '%s\n' "$rendered" | grep -q 'ssl_bump\|fixture_name\|8443'; then
  fail "production config contains a fixture or TLS inspection"
fi
"$root/render-squid-conf.sh" --bind 0.0.0.0:3128 --src 172.30.208.0/24 --allow-file "$root/allowlist" >/dev/null 2>&1 && fail "wide bind was accepted"
"$root/render-squid-conf.sh" --bind 172.30.140.2:3128 --src 172.30.140.0/24 --allow-file "$root/allowlist" \
  --fixture-name idle.fixture --fixture-dst 172.30.141.10/32 > "$work/stage.conf"
grep -q 'acl fixture_port port 8443' "$work/stage.conf" || fail "fixture port missing"
grep -q 'http_access allow CONNECT fixture_name fixture_dst fixture_port' "$work/stage.conf" || fail "fixture allow missing"

echo "== mapped uid"
printf '%s\n' 'dockremap:200000:65536' > "$work/subuid"
uid=$("$root/stage-perms.sh" --print --subuid "$work/subuid" --remap-user dockremap --container-uid 10001)
[ "$uid" = "210001" ] || fail "mapped uid was $uid"
"$root/stage-perms.sh" --print --subuid "$work/subuid" --remap-user dockremap --container-uid 0 >/dev/null 2>&1 && fail "uid 0 was accepted"

echo "== harness does not clean up"
for forbidden in 'compose down' 'docker rm' '--rm' 'rm -rf' 'nft flush' 'iptables-restore' 'systemctl' 'trap '; do
  if grep -n -F -e "$forbidden" "$root/host-stage.sh" >/dev/null; then
    fail "host-stage.sh contains $forbidden"
  fi
done
if grep -n 'rollback' "$root/host-stage.sh" >/dev/null; then
  fail "host-stage.sh calls rollback"
fi

echo "== plan avoids a collision"
cat > "$work/inventory" <<'EOF'
bridge br-vvr-sabcdefa
bridge br-vvr-app
subnet 172.30.208.0/24
subnet 172.18.0.0/16
port 3000
project valentinvera-reviewer
table reviewer_egress
EOF
"$root/host-stage.sh" plan --inventory "$work/inventory" --suffix abcdef --plan "$work/collide.plan" --stage-dir "$work" >/dev/null 2>"$work/collide.err" && fail "colliding suffix was planned"
grep -q 'could not allocate' "$work/collide.err" || fail "collision did not explain itself"
: > "$work/empty-inventory"
"$root/host-stage.sh" plan --inventory "$work/empty-inventory" --suffix abcdef --plan "$work/ok.plan" --stage-dir "$work" >/dev/null
grep -q '^PROJECT=vvrstabcdef$' "$work/ok.plan" || fail "project was not unique"
grep -q '^TABLE=reviewer_egress_sabcdef$' "$work/ok.plan" || fail "table was not unique"
grep -q '^APP_BRIDGE=br-vvr-sabcdefa$' "$work/ok.plan" || fail "bridge was not unique"
grep -q '^PORT=3000$' "$work/ok.plan" && fail "plan used port 3000"
"$root/host-stage.sh" preflight --inventory "$work/empty-inventory" --plan "$work/ok.plan" >/dev/null
"$root/host-stage.sh" preflight --inventory "$work/inventory" --plan "$work/ok.plan" >/dev/null 2>"$work/preflight.err" && fail "preflight replaced an existing bridge"
grep -q 'refusing to replace' "$work/preflight.err" || fail "preflight did not refuse"

echo "== nft install does not replace"
mkdir -p "$work/bin" "$work/lock"
cat > "$work/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_LOG"
if [ "$1" = list ] && [ ! -f "$NFT_EXISTS" ]; then
  exit 1
fi
exit 0
EOF
cat > "$work/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$work/bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = ps ]; then
  if [ -f "$DOCKER_PS" ]; then
    cat "$DOCKER_PS"
  fi
  exit 0
fi
exit 0
EOF
chmod 0755 "$work/bin/nft" "$work/bin/ip" "$work/bin/docker"
NFT_LOG="$work/nft.log"
NFT_EXISTS="$work/nft.exists"
DOCKER_PS="$work/docker.ps"
export NFT_LOG NFT_EXISTS DOCKER_PS
export EGRESS_NFT="$work/bin/nft"
export EGRESS_IP="$work/bin/ip"
export EGRESS_DOCKER="$work/bin/docker"
export EGRESS_LOCK_DIR="$work/lock"
: > "$NFT_LOG"
"$root/host-rules.sh" install \
  --table reviewer_egress_sabcdef \
  --app-bridge br-vvr-sabcdefa \
  --egress-bridge br-vvr-sabcdefe \
  --proxy-ip 172.30.143.2 \
  --app-network vvrstabcdefa \
  --egress-network vvrstabcdefe >/dev/null
if grep -q 'delete table' "$NFT_LOG"; then
  fail "install deleted an nft table"
fi
grep -q '^-f ' "$NFT_LOG" || fail "install did not load rules"
touch "$NFT_EXISTS"
: > "$NFT_LOG"
"$root/host-rules.sh" install \
  --table reviewer_egress_sabcdef \
  --app-bridge br-vvr-sabcdefa \
  --egress-bridge br-vvr-sabcdefe \
  --proxy-ip 172.30.143.2 >/dev/null 2>"$work/replace.err" && fail "second install replaced the table"
grep -q 'refusing to replace' "$work/replace.err" || fail "replace refusal missing"
if grep -q 'delete table' "$NFT_LOG"; then
  fail "refused install still deleted the table"
fi
"$root/host-rules.sh" rollback \
  --table reviewer_egress_sabcdef \
  --app-bridge br-vvr-sabcdefa \
  --egress-bridge br-vvr-sabcdefe \
  --proxy-ip 172.30.143.2 >/dev/null 2>"$work/rollback.err" && fail "rollback ran without confirmation"
printf '%s\n' 'fixture vvrstabcdefa' > "$DOCKER_PS"
"$root/host-rules.sh" rollback --confirm-stopped \
  --table reviewer_egress_sabcdef \
  --app-bridge br-vvr-sabcdefa \
  --egress-bridge br-vvr-sabcdefe \
  --proxy-ip 172.30.143.2 \
  --app-network vvrstabcdefa \
  --egress-network vvrstabcdefe >/dev/null 2>"$work/running.err" && fail "rollback removed rules while a container was running"
grep -q 'refusing rollback while staged containers are running' "$work/running.err" || fail "running-container refusal missing"
: > "$NFT_LOG"
: > "$DOCKER_PS"
"$root/host-rules.sh" rollback --confirm-stopped \
  --table reviewer_egress_sabcdef \
  --app-bridge br-vvr-sabcdefa \
  --egress-bridge br-vvr-sabcdefe \
  --proxy-ip 172.30.143.2 \
  --app-network vvrstabcdefa \
  --egress-network vvrstabcdefe >/dev/null
grep -q '^delete table inet reviewer_egress_sabcdef$' "$NFT_LOG" || fail "explicit rollback did not name only its table"

echo "== compose render"
mkdir -p "$work/empty" "$work/fixture" "$work/client" "$work/delay"
printf '0\n' > "$work/delay/ms"
: > "$work/fixture/srv.crt"
: > "$work/fixture/srv.key"
: > "$work/client/ca.crt"
: > "$work/squid.conf"
cp "$root/testdata/fixture.js" "$root/testdata/client.js" "$root/testdata/health.js" "$work/"
cat > "$work/env" <<EOF
EGRESS_PROJECT_NAME=vvrstabcdef
EGRESS_IMAGE_TAG=sabcdef
REVIEWER_BIND_PORT=20375
REVIEWER_IMAGE=oven/bun:1.4.4
REVIEWER_DATA_DIR=$work/empty
REVIEWER_BACKUP_DIR=$work/empty
REVIEWER_SECRETS_DIR=$work/empty
APP_SUBNET=172.30.143.0/24
APP_GATEWAY=172.30.143.1
PROXY_IP=172.30.143.2
APP_NETWORK_NAME=vvrstabcdefa
EGRESS_NETWORK_NAME=vvrstabcdefe
APP_BRIDGE=br-vvr-sabcdefa
EGRESS_BRIDGE=br-vvr-sabcdefe
EGRESS_SUBNET=172.30.144.0/24
EGRESS_GATEWAY=172.30.144.1
TEST_CONF=$work/squid.conf
TEST_DIR=$work
FIXTURE_DIR=$work/fixture
CLIENT_CA=$work/client/ca.crt
FIXTURE_IP=172.30.144.10
IDLE_MS=310000
EOF
sudo docker compose --env-file "$work/env" -f "$root/compose.yml" -f "$root/compose.test.yml" config > "$work/render.yml"
grep -q 'internal: true' "$work/render.yml" || fail "rendered network is not internal"
grep -q 'host_ip: 127.0.0.1' "$work/render.yml" || fail "loopback publish missing"
grep -q 'published: "20375"' "$work/render.yml" || fail "stage port missing"
if grep -q 'NET_BIND_SERVICE\|network_mode: host\|docker.sock\|user: "0:0"\|user: 0:0' "$work/render.yml"; then
  fail "rendered compose weakens the fixture"
fi
grep -q 'user: 10001:10001' "$work/render.yml" || fail "fixture user missing"
grep -q 'no-new-privileges:true' "$work/render.yml" || fail "nnp missing"
grep -q 'read_only: true' "$work/render.yml" || fail "read only missing"
echo "static checks passed; live transport was not run"
echo "work directory retained at $keep"
