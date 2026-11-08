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
for script in render-squid-conf.sh proxy-entrypoint.sh app-entrypoint.sh ingress-entrypoint.sh host-rules.sh stage-perms.sh host-stage.sh pack-bundle.sh; do
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
grep -q '^INGRESS_BRIDGE=br-vvr-sabcdefi$' "$work/ok.plan" || fail "ingress bridge missing"
grep -q '^PUBLISH_BRIDGE=br-vvr-sabcdefp$' "$work/ok.plan" || fail "publish bridge missing"
grep -q '^INGRESS_UPSTREAM_IP=172.30.145.10$' "$work/ok.plan" || fail "ingress upstream missing"
grep -q '^PUBLISH_SUBNET=172.30.146.0/24$' "$work/ok.plan" || fail "publish subnet missing"
grep -q '^PORT=3000$' "$work/ok.plan" && fail "plan used port 3000"
grep -q '^PORT=20831$' "$work/ok.plan" && fail "plan reused the retained port"
"$root/host-stage.sh" plan --inventory "$work/empty-inventory" --suffix a41b73 --plan "$work/retained.plan" --stage-dir "$work" >/dev/null 2>"$work/retained.err" && fail "retained stage was planned"
grep -q 'refusing retained stage' "$work/retained.err" || fail "retained stage refusal missing"
"$root/host-stage.sh" preflight --inventory "$work/empty-inventory" --plan "$work/ok.plan" >/dev/null
"$root/host-stage.sh" preflight --inventory "$work/inventory" --plan "$work/ok.plan" >/dev/null 2>"$work/preflight.err" && fail "preflight replaced an existing bridge"
grep -q 'refusing to replace' "$work/preflight.err" || fail "preflight did not refuse"

echo "== nft install does not replace"
mkdir -p "$work/bin" "$work/lock"
cat > "$work/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_LOG"
if [ "$1" = "-c" ] && [ "$2" = "-f" ]; then
  cat "$3" >> "$NFT_LOG"
  exit 0
fi
if [ "$1" = "-f" ]; then
  cat "$2" >> "$NFT_LOG"
  exit 0
fi
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
rules_args="--table reviewer_egress_sabcdef --app-bridge br-vvr-sabcdefa --egress-bridge br-vvr-sabcdefe --ingress-bridge br-vvr-sabcdefi --publish-bridge br-vvr-sabcdefp --proxy-ip 172.30.143.2 --ingress-relay 172.30.145.2 --ingress-upstream 172.30.145.10 --ingress-port 8080 --app-network vvrstabcdefa --egress-network vvrstabcdefe --ingress-network vvrstabcdefi --publish-network vvrstabcdefp"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args >/dev/null
if grep -q 'delete table' "$NFT_LOG"; then
  fail "install deleted an nft table"
fi
grep -q '^-f ' "$NFT_LOG" || fail "install did not load rules"
python3 - "$NFT_LOG" <<'PY' || fail "rendered rules do not cover the ingress bridge"
import sys
text = open(sys.argv[1]).read()
start = text.find("table inet ")
if start < 0:
    raise SystemExit("no inet table")
rules = text[start:]
if "hook output" in rules or "flush" in rules:
    raise SystemExit("rules touch output or flush")
if rules.count("policy accept") < 4:
    raise SystemExit("a chain is not policy accept")
ingress = "br-vvr-sabcdefi"
required = [
    f'iifname "{ingress}" meta nfproto ipv6 counter drop',
    f'iifname "{ingress}" ct state established,related counter accept',
    'iifname "{0}" ip saddr 172.30.145.2 ip daddr 172.30.145.10 tcp dport 8080 ct state new counter accept'.format(ingress),
    f'iifname "{ingress}" counter drop',
    f'meta ibrname "{ingress}" ether type ip6 counter drop',
    f'meta ibrname "{ingress}" ether type ip ip saddr 172.30.145.2 ip daddr 172.30.145.10 tcp dport 8080 counter accept',
    f'meta ibrname "{ingress}" ether type ip ip saddr 172.30.145.10 tcp sport 8080 ip daddr 172.30.145.2 counter accept',
    f'meta ibrname "{ingress}" ether type ip counter drop',
    'iifname "br-vvr-sabcdefa" ip daddr 172.30.143.2 tcp dport 3128 counter accept',
    'iifname "br-vvr-sabcdefp" counter drop',
    "table bridge reviewer_egress_sabcdef",
]
for line in required:
    if line not in rules:
        raise SystemExit("missing: " + line)
# The app must not be given a new session to the relay. A reply keeps source port 8080.
forbidden = 'ip saddr 172.30.145.10 ip daddr 172.30.145.2 tcp dport 8080'
if forbidden in rules:
    raise SystemExit("app to relay new session is accepted")
if 'iifname "br-vvr-sabcdefp" tcp dport' in rules:
    raise SystemExit("publish bridge allows a new destination")
# Ingress input drops before any accept of that interface in the input chain.
input_chain = rules.split("chain forward", 1)[0]
input_lines = [line.strip() for line in input_chain.splitlines() if ingress in line and "counter" in line]
if not input_lines or any("accept" in line for line in input_lines):
    raise SystemExit("ingress input accepts traffic: " + repr(input_lines))
if not any(line.endswith("counter drop") for line in input_lines):
    raise SystemExit("ingress input has no drop")
forward = rules.split("chain forward", 1)[1].split("table bridge", 1)[0]
established = forward.find('iifname "%s" ct state established,related counter accept' % ingress)
allowed = forward.find("tcp dport 8080 ct state new counter accept")
dropped = forward.rfind('iifname "%s" counter drop' % ingress)
if not (0 <= established < allowed < dropped):
    raise SystemExit("ingress forward does not drop after the one allowed flow")
PY
: > "$NFT_LOG"
"$root/host-rules.sh" install \
  --table reviewer_egress_sabcdef \
  --app-bridge br-vvr-sabcdefa \
  --egress-bridge br-vvr-sabcdefe \
  --publish-bridge br-vvr-sabcdefp \
  --proxy-ip 172.30.143.2 \
  --ingress-relay 172.30.145.2 \
  --ingress-upstream 172.30.145.10 \
  --ingress-port 8080 >/dev/null 2>"$work/missing-ingress.err" && fail "install without the ingress bridge was accepted"
grep -q 'ingress bridge, publish bridge, relay, upstream, and port are required' "$work/missing-ingress.err" || fail "missing ingress bridge was not refused"
if grep -q '^-f ' "$NFT_LOG"; then
  fail "missing ingress bridge still rendered nft"
fi
touch "$NFT_EXISTS"
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args >/dev/null 2>"$work/replace.err" && fail "second install replaced the table"
grep -q 'refusing to replace' "$work/replace.err" || fail "replace refusal missing"
if grep -q 'delete table' "$NFT_LOG"; then
  fail "refused install still deleted the table"
fi
# shellcheck disable=SC2086
"$root/host-rules.sh" rollback $rules_args >/dev/null 2>"$work/rollback.err" && fail "rollback ran without confirmation"
printf '%s\n' 'fixture vvrstabcdefa' > "$DOCKER_PS"
# shellcheck disable=SC2086
"$root/host-rules.sh" rollback --confirm-stopped $rules_args >/dev/null 2>"$work/running.err" && fail "rollback removed rules while a container was running"
grep -q 'refusing rollback while staged containers are running' "$work/running.err" || fail "running-container refusal missing"
: > "$NFT_LOG"
: > "$DOCKER_PS"
# shellcheck disable=SC2086
"$root/host-rules.sh" rollback --confirm-stopped $rules_args >/dev/null
grep -q '^delete table inet reviewer_egress_sabcdef$' "$NFT_LOG" || fail "explicit rollback did not delete the inet table"
grep -q '^delete table bridge reviewer_egress_sabcdef$' "$NFT_LOG" || fail "explicit rollback did not delete the bridge table"
[ "$(grep -c '^delete table ' "$NFT_LOG")" -eq 2 ] || fail "rollback deleted something other than its two tables"

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
INGRESS_NETWORK_NAME=vvrstabcdefi
INGRESS_BRIDGE=br-vvr-sabcdefi
INGRESS_SUBNET=172.30.145.0/24
INGRESS_GATEWAY=172.30.145.1
INGRESS_RELAY_IP=172.30.145.2
INGRESS_UPSTREAM_IP=172.30.145.10
INGRESS_LISTEN_PORT=8080
PUBLISH_NETWORK_NAME=vvrstabcdefp
PUBLISH_BRIDGE=br-vvr-sabcdefp
PUBLISH_SUBNET=172.30.146.0/24
PUBLISH_GATEWAY=172.30.146.1
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
grep -q "user: \"65534:65534\"" "$work/render.yml" || grep -q 'user: 65534:65534' "$work/render.yml" || fail "ingress user missing"
grep -q 'no-new-privileges:true' "$work/render.yml" || fail "nnp missing"
grep -q 'read_only: true' "$work/render.yml" || fail "read only missing"
grep -q 'enable_ip_masquerade: "false"' "$work/render.yml" || fail "publish network masquerades"
sudo docker compose --env-file "$work/env" -f "$root/compose.yml" -f "$root/compose.test.yml" config --format json > "$work/render.json"
python3 - "$work/render.json" <<'PY' || fail "rendered ingress topology is wrong"
import json, sys
cfg = json.load(open(sys.argv[1]))
client = cfg["services"]["client"]
ingress = cfg["services"]["ingress"]
assert "ports" not in client or not client["ports"], client.get("ports")
assert set(client["networks"]) == {"app", "ingress"}, client["networks"]
assert client["networks"]["ingress"]["ipv4_address"] == "172.30.145.10"
ports = ingress["ports"]
assert len(ports) == 1, ports
assert ports[0]["host_ip"] == "127.0.0.1"
assert str(ports[0]["published"]) == "20375"
assert int(ports[0]["target"]) == 8080
assert set(ingress["networks"]) == {"ingress", "publish"}, ingress["networks"]
nets = cfg["networks"]
assert nets["app"]["internal"] is True
assert nets["ingress"]["internal"] is True
assert nets["publish"].get("internal") is not True
assert nets["egress"].get("internal") is not True
assert nets["publish"]["driver_opts"]["com.docker.network.bridge.enable_ip_masquerade"] == "false"
assert "egress" not in client["networks"]
assert "publish" not in client["networks"]
assert "app" not in ingress["networks"]
assert "egress" not in ingress["networks"]
PY
sed 's/^INGRESS_LISTEN_PORT=8080/INGRESS_LISTEN_PORT=3000/' "$work/env" > "$work/prod.env"
sudo docker compose --profile app --env-file "$work/prod.env" -f "$root/compose.yml" config --format json > "$work/prod.json"
python3 - "$work/prod.json" <<'PY' || fail "production ingress topology is wrong"
import json, sys
cfg = json.load(open(sys.argv[1]))
app = cfg["services"]["app"]
ingress = cfg["services"]["ingress"]
assert "ports" not in app or not app["ports"], app.get("ports")
assert set(app["networks"]) == {"app", "ingress"}
assert app["networks"]["ingress"]["ipv4_address"] == "172.30.145.10"
assert "publish" not in app["networks"] and "egress" not in app["networks"]
assert cfg["networks"]["app"]["internal"] is True
assert cfg["networks"]["ingress"]["internal"] is True
assert cfg["networks"]["publish"].get("internal") is not True
ports = ingress["ports"]
assert ports[0]["host_ip"] == "127.0.0.1"
assert int(ports[0]["target"]) == 3000
assert set(ingress["networks"]) == {"ingress", "publish"}
PY

echo "== ingress relay"
cat > "$work/socat" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$SOCAT_ARGS"
exit 0
EOF
chmod 0755 "$work/socat"
SOCAT_ARGS="$work/socat.args" PATH="$work:$PATH" \
  INGRESS_LISTEN_PORT=8080 INGRESS_UPSTREAM=172.30.145.10:8080 \
  "$root/ingress-entrypoint.sh"
grep -q 'TCP-LISTEN:8080,bind=0.0.0.0,reuseaddr,fork,max-children=16' "$work/socat.args" || fail "listen socket was not one port"
grep -q 'TCP:172.30.145.10:8080' "$work/socat.args" || fail "upstream was not the single address"
INGRESS_LISTEN_PORT=8080 INGRESS_UPSTREAM=10.1.1.1:8080 "$root/ingress-entrypoint.sh" >/dev/null 2>"$work/relay.err" && fail "relay accepted an upstream outside the ingress address"
grep -q '172.30.<octet>.10' "$work/relay.err" || fail "relay refusal missing"
INGRESS_LISTEN_PORT=8080 INGRESS_UPSTREAM=idle.fixture:8080 "$root/ingress-entrypoint.sh" >/dev/null 2>"$work/relay-name.err" && fail "relay accepted a hostname"
INGRESS_LISTEN_PORT=80 INGRESS_UPSTREAM=172.30.145.10:80 "$root/ingress-entrypoint.sh" >/dev/null 2>&1 && fail "relay accepted a privileged port"
"$root/ingress-entrypoint.sh" extra >/dev/null 2>&1 && fail "relay accepted arguments"

echo "== canonical bundle"
"$root/pack-bundle.sh" "$work/bundle"
extracted="$work/extracted"
mkdir -p "$extracted"
tar -xf "$work/bundle/egress-checkpoint.tar" -C "$extracted"
bundle="$extracted/egress-checkpoint"
test -x "$bundle/deploy/egress/host-stage.sh" || fail "extracted host-stage.sh is not executable"
[ "$(stat -c '%a' "$bundle/deploy/egress/host-stage.sh")" = "755" ] || fail "extracted host-stage.sh mode is not 755"
[ "$(stat -c '%a' "$bundle/deploy/egress/test-static.sh")" = "755" ] || fail "extracted test-static.sh mode is not 755"
( cd "$bundle" && sha256sum -c SHA256SUMS >/dev/null ) || fail "checksum manifest does not match the extracted files"
[ "$(tr -d '[:space:]' < "$bundle/SOURCE_COMMIT")" = "$(git -C "$root/../.." rev-parse HEAD)" ] || fail "SOURCE_COMMIT does not match HEAD"
sh -n "$bundle/deploy/egress/host-stage.sh"

stub="$work/stubs"
mkdir -p "$stub"
cat > "$stub/docker-ok" <<'EOF'
#!/bin/sh
if [ "$1" = "ps" ]; then
  printf '%s\n' 'valentinvera-reviewer-app-1 valentinvera-reviewer'
  printf '%s\n' 'lonely-container'
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then
  printf '%s\n' bridge
  printf '%s\n' host
  printf '%s\n' none
  printf '%s\n' emptyipam
  printf '%s\n' ipv6net
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then
  case "$3" in
    host|none) printf '%s\n' null; exit 0 ;;
    emptyipam) printf '%s\n' '[]'; exit 0 ;;
    bridge) printf '%s\n' '[{"Subnet":"172.17.0.0/16","IPRange":"","Gateway":"172.17.0.1"}]'; exit 0 ;;
    ipv6net) printf '%s\n' '[{"Subnet":"172.30.200.0/24"},{"Subnet":"fd00:dead:beef::/64"}]'; exit 0 ;;
  esac
  echo "unexpected network $3" >&2
  exit 1
fi
echo "unexpected docker $*" >&2
exit 1
EOF
cat > "$stub/docker-fail" <<'EOF'
#!/bin/sh
if [ "$1" = "ps" ]; then
  printf '%s\n' 'lonely-container'
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "ls" ]; then
  printf '%s\n' bridge
  printf '%s\n' broken
  exit 0
fi
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then
  case "$3" in
    bridge) printf '%s\n' '[{"Subnet":"172.17.0.0/16","Gateway":"172.17.0.1"}]'; exit 0 ;;
    broken) echo 'Error response from daemon: denied' >&2; exit 1 ;;
  esac
fi
echo "unexpected docker $*" >&2
exit 1
EOF
printf '%s\n' '2: br-f5d584fd553b: <BROADCAST,UP>' > "$stub/ip-out"
cat > "$stub/ip" <<'EOF'
#!/bin/sh
cat "$STUB_DIR/ip-out"
exit 0
EOF
cat > "$stub/ss" <<'EOF'
#!/bin/sh
printf '%s\n' 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*'
exit 0
EOF
cat > "$stub/nft" <<'EOF'
#!/bin/sh
printf '%s\n' 'table inet filter'
exit 0
EOF
chmod 0755 "$stub/docker-ok" "$stub/docker-fail" "$stub/ip" "$stub/ss" "$stub/nft"

stage_sh="$bundle/deploy/egress/host-stage.sh"
STUB_DIR="$stub" EGRESS_DOCKER="$stub/docker-ok" EGRESS_IP="$stub/ip" EGRESS_SS="$stub/ss" EGRESS_NFT="$stub/nft" \
  "$stage_sh" collect --inventory "$work/stock.inv"
grep -q '^network host$' "$work/stock.inv" || fail "host network missing from inventory"
grep -q '^network none$' "$work/stock.inv" || fail "none network missing from inventory"
grep -q '^network emptyipam$' "$work/stock.inv" || fail "empty IPAM network missing from inventory"
grep -q '^subnet 172.17.0.0/16$' "$work/stock.inv" || fail "bridge IPv4 subnet missing"
grep -q '^subnet 172.30.200.0/24$' "$work/stock.inv" || fail "IPv6 network IPv4 subnet missing"
grep -q '^subnet fd00:dead:beef::/64$' "$work/stock.inv" || fail "IPv6 subnet missing"
grep -q '^container lonely-container$' "$work/stock.inv" || fail "container without a project label was dropped"
grep -q '^project valentinvera-reviewer$' "$work/stock.inv" || fail "compose project missing"
grep -q '^bridge br-f5d584fd553b$' "$work/stock.inv" || fail "bridge link missing"
grep -q '^port 3000$' "$work/stock.inv" || fail "listener port missing"
if grep -q '^subnet null$\|^subnet $\|^subnet$' "$work/stock.inv"; then
  fail "empty IPAM was recorded as a subnet"
fi
awk '
  $1 == "network" && ($2 == "host" || $2 == "none" || $2 == "emptyipam") { pending = $2; next }
  pending && $1 == "subnet" { print pending; exit 1 }
  { pending = "" }
' "$work/stock.inv" || fail "a network without IPAM gained a subnet"

"$stage_sh" plan --inventory "$work/stock.inv" --suffix abcdef --plan "$work/stock.plan" --stage-dir "$work/stage"
grep -q '^PROJECT=vvrstabcdef$' "$work/stock.plan" || fail "plan ignored a normal inventory"
"$stage_sh" preflight --inventory "$work/stock.inv" --plan "$work/stock.plan" > "$work/preflight.out"
grep -q 'preflight clear' "$work/preflight.out" || fail "preflight rejected a normal inventory"
cp "$work/stock.inv" "$work/collide.inv"
printf '%s\n' 'subnet 172.30.143.0/24' >> "$work/collide.inv"
"$stage_sh" plan --inventory "$work/collide.inv" --suffix abcdef --plan "$work/collide.plan" --stage-dir "$work/stage" \
  >/dev/null 2>"$work/collide.err" && fail "colliding subnet was accepted"
grep -q 'could not allocate' "$work/collide.err" || fail "collision refusal missing"
printf '%s\n' 'bridge br-vvr-sabcdefa' >> "$work/stock.inv"
"$stage_sh" preflight --inventory "$work/stock.inv" --plan "$work/stock.plan" \
  >/dev/null 2>"$work/bridge-collide.err" && fail "colliding bridge was accepted"
grep -q 'refusing to replace an existing stage resource' "$work/bridge-collide.err" || fail "bridge collision refusal missing"

STUB_DIR="$stub" EGRESS_DOCKER="$stub/docker-fail" EGRESS_IP="$stub/ip" EGRESS_SS="$stub/ss" EGRESS_NFT="$stub/nft" \
  "$stage_sh" collect --inventory "$work/fail.inv" >/dev/null 2>"$work/inspect.err" && fail "inspect failure was ignored"
grep -q 'FAIL: docker network inspect broken' "$work/inspect.err" || fail "inspect failure did not name the network"
grep -q 'Error response from daemon: denied' "$work/inspect.err" || fail "inspect stderr was swallowed"
grep -q '== partial inventory' "$work/inspect.err" || fail "partial inventory was not printed"
grep -q '^subnet 172.17.0.0/16$' "$work/inspect.err" || fail "partial inventory omitted the earlier subnet"
grep -q '^network broken$' "$work/inspect.err" || fail "partial inventory omitted the failed network"
if grep -q 'subnet' "$work/fail.inv" && grep -q 'broken' "$work/fail.inv"; then
  if awk '$1 == "network" && $2 == "broken" { pending = 1; next } pending && $1 == "subnet" { exit 1 } { pending = 0 }' "$work/fail.inv"; then
    :
  else
    fail "failed inspect invented a subnet"
  fi
fi

echo "static checks passed; live transport was not run"
echo "work directory retained at $keep"
