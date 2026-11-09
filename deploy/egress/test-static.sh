#!/bin/sh
# Static checks for the host staging harness.
# Does not start containers, install nft rules, or delete resources.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck source=dns-reply.sh
. "$root/dns-reply.sh"
work=$(mktemp -d)
keep="$work"
echo "static work directory left at $keep"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "== syntax"
for script in render-squid-conf.sh proxy-entrypoint.sh app-entrypoint.sh ingress-entrypoint.sh host-rules.sh stage-perms.sh host-stage.sh stage-route.sh pack-bundle.sh dns-reply.sh deploy-app.sh test-boot-deploy.sh; do
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
proxy_from=$(awk '/^FROM / { print; exit }' "$root/Dockerfile")
relay_from=$(awk '/^FROM / { print; exit }' "$root/Dockerfile.ingress")
[ "$proxy_from" = "$relay_from" ] || fail "proxy and relay base digests differ"
printf '%s\n' "$proxy_from" | grep -q 'alpine:3.22.8@sha256:9db2934886712d877c932e07249c75a59e6ca27adfbccc05261987a17bef2d63' || fail "proxy base is not the pinned Alpine 3.22.8 manifest"
if grep -q '4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' "$root/Dockerfile" "$root/Dockerfile.ingress"; then
  fail "an image still uses the July 2025 Alpine digest"
fi
grep -q "squid=6.12-r0" "$root/Dockerfile" || fail "squid is not pinned"
grep -q "socat=1.8.1.3-r0" "$root/Dockerfile.ingress" || fail "socat is not pinned"
grep -q "zlib=1.4-r0" "$root/Dockerfile" || fail "zlib is not pinned in the proxy image"
grep -q "zlib=1.4-r0" "$root/Dockerfile.ingress" || fail "zlib is not pinned in the relay image"
grep -q "libssl3=3.5.9-r0" "$root/Dockerfile" || fail "libssl3 is not pinned in the proxy image"
grep -q "libssl3=3.5.9-r0" "$root/Dockerfile.ingress" || fail "libssl3 is not pinned in the relay image"
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
"$root/host-stage.sh" plan --inventory "$work/empty-inventory" --suffix e7b421 --plan "$work/retained-e7.plan" --stage-dir "$work" >/dev/null 2>"$work/retained-e7.err" && fail "retained e7b421 stage was planned"
grep -q 'refusing retained stage' "$work/retained-e7.err" || fail "retained e7b421 refusal missing"
grep -q '^PORT=20129$' "$work/ok.plan" && fail "plan reused the retained e7b421 port"
"$root/host-stage.sh" plan --inventory "$work/empty-inventory" --suffix b83c52 --plan "$work/retained-b8.plan" --stage-dir "$work" >/dev/null 2>"$work/retained-b8.err" && fail "retained b83c52 stage was planned"
grep -q 'refusing retained stage' "$work/retained-b8.err" || fail "retained b83c52 refusal missing"
grep -q '^PORT=20566$' "$work/ok.plan" && fail "plan reused the retained b83c52 port"
"$root/host-stage.sh" plan --inventory "$work/empty-inventory" --suffix 7fa384 --plan "$work/retained-7f.plan" --stage-dir "$work" >/dev/null 2>"$work/retained-7f.err" && fail "retained 7fa384 stage was planned"
grep -q 'refusing retained stage' "$work/retained-7f.err" || fail "retained 7fa384 refusal missing"
grep -q '^PORT=20332$' "$work/ok.plan" && fail "plan reused the retained 7fa384 port"
"$root/host-stage.sh" plan --inventory "$work/empty-inventory" --suffix 4dc812 --plan "$work/retained-4d.plan" --stage-dir "$work" >/dev/null 2>"$work/retained-4d.err" && fail "retained 4dc812 stage was planned"
grep -q 'refusing retained stage' "$work/retained-4d.err" || fail "retained 4dc812 refusal missing"
grep -q '^PORT=20790$' "$work/ok.plan" && fail "plan reused the retained 4dc812 port"
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
    f'meta ibrname "{ingress}" ether type ip ct state established,related counter accept',
    f'meta ibrname "{ingress}" ether type ip ip saddr 172.30.145.2 ip daddr 172.30.145.10 tcp dport 8080 counter accept',
    f'meta ibrname "{ingress}" ether type ip counter drop',
    'iifname "br-vvr-sabcdefa" ip daddr 172.30.143.2 tcp dport 3128 counter accept',
    'iifname "br-vvr-sabcdefp" counter drop',
    "table bridge reviewer_egress_sabcdef",
]
for line in required:
    if line not in rules:
        raise SystemExit("missing: " + line)
# The app must not be given a new session to the relay.
forbidden = 'ip saddr 172.30.145.10 ip daddr 172.30.145.2 tcp dport 8080'
if forbidden in rules:
    raise SystemExit("app to relay new session is accepted")
if "tcp sport" in rules:
    raise SystemExit("a source port is accepted")
if "8443" in rules:
    raise SystemExit("rules without a fixture flag include port 8443")
if "dport 53" in rules:
    raise SystemExit("rules without a dns sink accept port 53")
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
bridge = rules.split("table bridge reviewer_egress_sabcdef {", 1)[1]
if "table inet " in bridge:
    bridge = bridge.split("table inet ", 1)[0]
bforward = bridge.split("chain forward", 1)[1]
bestablished = bforward.find('meta ibrname "%s" ether type ip ct state established,related counter accept' % ingress)
ballowed = bforward.find("ip saddr 172.30.145.2 ip daddr 172.30.145.10 tcp dport 8080")
bdropped = bforward.rfind('meta ibrname "%s" ether type ip counter drop' % ingress)
if not (0 <= bestablished < ballowed < bdropped):
    raise SystemExit("bridge ingress forward does not drop after the one allowed flow")
binput = bridge.split("chain forward", 1)[0]
binput_lines = [line.strip() for line in binput.splitlines() if ingress in line and "counter" in line]
if any("accept" in line for line in binput_lines):
    raise SystemExit("bridge ingress input accepts traffic: " + repr(binput_lines))
egress = "br-vvr-sabcdefe"
inet_input = rules.split("chain forward", 1)[0]
inet_forward = rules.split("chain forward", 1)[1].split("table bridge ", 1)[0]
if "tcp dport 443" in inet_input:
    raise SystemExit("inet input accepts tcp 443, which is host-local delivery")
if "gateway-l2-to-routing" in inet_input or "gateway-l2-to-routing" in inet_forward or "gateway-l2-to-routing" in bforward:
    raise SystemExit("gateway frame accept is outside bridge input")
gateway = 'meta ibrname "%s" ether type ip tcp dport 443 counter accept comment "gateway-l2-to-routing"' % egress
if gateway not in binput:
    raise SystemExit("egress bridge input does not hand tcp 443 frames to routing")
if 'meta ibrname "%s" ether type ip counter drop' % egress not in binput:
    raise SystemExit("egress bridge input keeps other new ipv4")
ipv6_drop = binput.find('meta ibrname "%s" ether type ip6 counter drop' % egress)
established_bridge = binput.find('meta ibrname "%s" ether type ip ct state established,related counter accept' % egress)
gateway_at = binput.find(gateway)
other_drop = binput.find('meta ibrname "%s" ether type ip counter drop' % egress)
if not (0 <= ipv6_drop < established_bridge < gateway_at < other_drop):
    raise SystemExit("egress bridge input order is not ipv6 drop, established, gateway tcp 443, other ipv4 drop")
app = "br-vvr-sabcdefa"
app_lines = [line.strip() for line in binput.splitlines() if app in line and "counter" in line]
if not any(line.endswith("counter drop") for line in app_lines):
    raise SystemExit("app bridge input does not drop new ipv4")
if any("gateway-l2-to-routing" in line or "tcp dport 443" in line for line in app_lines):
    raise SystemExit("app bridge input accepts routed egress")
established = inet_forward.find('iifname "%s" ct state established,related counter accept' % egress)
bogon = inet_forward.find('iifname "%s" ip daddr @bogon4 counter drop' % egress)
routed = inet_forward.find('iifname "%s" tcp dport 443 counter accept' % egress)
forward_drop = inet_forward.find('iifname "%s" counter drop' % egress)
if not (0 <= established < bogon < routed < forward_drop):
    raise SystemExit("routed egress is not established, bogon drop, tcp 443, then drop")
host_lines = [line.strip() for line in inet_input.splitlines() if egress in line and "counter" in line]
if not any(line.endswith("counter drop") for line in host_lines):
    raise SystemExit("inet input does not drop host-local egress delivery")
if any("tcp dport" in line for line in host_lines):
    raise SystemExit("inet input allows a destination port from the egress bridge")
PY
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args --fixture-ip 172.30.144.10 --fixture-port 8443 >/dev/null
grep -q 'ip daddr 172.30.144.10 tcp dport 8443 counter accept' "$NFT_LOG" || fail "stage fixture exception missing"
if grep -q 'tcp sport' "$NFT_LOG"; then
  fail "fixture rules accept a source port"
fi
: > "$NFT_LOG"
"$root/host-rules.sh" install \
  --table reviewer_egress \
  --app-bridge br-vvr-app \
  --egress-bridge br-vvr-egress \
  --ingress-bridge br-vvr-ingress \
  --publish-bridge br-vvr-publish \
  --proxy-ip 172.30.208.2 \
  --ingress-relay 172.30.219.2 \
  --ingress-upstream 172.30.219.10 \
  --ingress-port 3000 \
  --fixture-ip 172.30.144.10 \
  --fixture-port 8443 >/dev/null 2>"$work/fixture-prod.err" && fail "production table accepted a fixture"
grep -q 'refusing fixture exception outside a stage table' "$work/fixture-prod.err" || fail "fixture refusal missing"
if grep -q '^-f ' "$NFT_LOG"; then
  fail "refused fixture still rendered nft"
fi
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args --fixture-ip 172.30.144.10 --fixture-port 443 >/dev/null 2>"$work/fixture-port.err" && fail "fixture port 443 was accepted"
grep -q 'refusing fixture port' "$work/fixture-port.err" || fail "fixture port refusal missing"
if grep -q '8443\|fixture-ip\|dns-sink\|dport 53' "$root/valentinvera-reviewer-egress.service"; then
  fail "production unit includes a stage exception"
fi
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args --dns-sink 172.30.143.9 >/dev/null
python3 - "$NFT_LOG" <<'PY' || fail "stage dns sink exception is not exact"
import sys
text = open(sys.argv[1]).read()
start = text.find("\ntable inet ")
second = text.find("\ntable inet ", start + 1)
rules = text[start:] if second < 0 else text[start:second]
inet, bridge_table = rules.split("table bridge", 1)
forwards = {
    "inet": inet.split("chain forward", 1)[1],
    "bridge": bridge_table.split("chain forward", 1)[1],
}
prefixes = {
    "inet": 'iifname "br-vvr-sabcdefa"',
    "bridge": 'meta ibrname "br-vvr-sabcdefa" ether type ip',
}
for family, forward in forwards.items():
    prefix = prefixes[family]
    udp = forward.find(prefix + " ip daddr 172.30.143.9 udp dport 53 counter accept")
    tcp = forward.find(prefix + " ip daddr 172.30.143.9 tcp dport 53 counter accept")
    proxy = forward.find(prefix + " ip daddr 172.30.143.2 tcp dport 3128 counter accept")
    drop = forward.find(prefix + " counter drop")
    if not (0 <= proxy < udp < tcp < drop):
        raise SystemExit(family + " dns exception is not between the proxy accept and the app drop")
for other in ("br-vvr-sabcdefe", "br-vvr-sabcdefi", "br-vvr-sabcdefp"):
    if "ip daddr 172.30.143.9" in "\n".join(line for line in rules.splitlines() if other in line):
        raise SystemExit("dns sink exception is not limited to the app bridge")
if rules.count("udp dport 53") != 2 or rules.count("tcp dport 53") != 2:
    raise SystemExit("dns port 53 is not exactly one inet and one bridge pair")
PY
: > "$NFT_LOG"
"$root/host-rules.sh" install \
  --table reviewer_egress \
  --app-bridge br-vvr-app \
  --egress-bridge br-vvr-egress \
  --ingress-bridge br-vvr-ingress \
  --publish-bridge br-vvr-publish \
  --proxy-ip 172.30.208.2 \
  --ingress-relay 172.30.219.2 \
  --ingress-upstream 172.30.219.10 \
  --ingress-port 3000 \
  --dns-sink 172.30.208.9 >/dev/null 2>"$work/dns-prod.err" && fail "production table accepted a dns sink"
grep -q 'refusing dns sink exception outside a stage table' "$work/dns-prod.err" || fail "dns sink refusal missing"
if grep -q '^-f ' "$NFT_LOG"; then
  fail "refused dns sink still rendered nft"
fi
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args --dns-sink 172.30.143.8 >/dev/null 2>"$work/dns-host.err" && fail "a non-sink address was accepted"
grep -q 'refusing dns sink' "$work/dns-host.err" || fail "wrong sink address was not refused"
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install $rules_args --dns-sink 172.30.144.9 >/dev/null 2>"$work/dns-octet.err" && fail "a sink on another subnet was accepted"
grep -q 'refusing dns sink' "$work/dns-octet.err" || fail "cross-subnet sink was not refused"
if ! grep -q 'quiet tunnel after nft' "$root/host-stage.sh"; then
  fail "quiet tunnel is not repeated after nft"
fi
quiet_line=$(awk '/quiet tunnel after nft/ { print NR; exit }' "$root/host-stage.sh")
case_line=$(awk '/record_case / { print NR; exit }' "$root/host-stage.sh")
[ -n "$quiet_line" ] && [ -n "$case_line" ] && [ "$quiet_line" -lt "$case_line" ] || fail "a negative case is recorded before the post-rule quiet tunnel"
if grep -q 'stage_fail "could not bind' "$root/host-stage.sh"; then
  fail "a bind miss still aborts before the remaining cases"
fi
if grep -q 'proxy-false "https://api.github.com/' "$root/host-stage.sh"; then
  fail "direct fetch still depends on GitHub DNS"
fi
if grep -n -E 'nsenter[[:space:]]+-t|nsenter[[:space:]]+--target' "$root/host-stage.sh" "$root/stage-route.sh" >/dev/null; then
  fail "a namespace is entered by pid"
fi
if grep -n 'nsenter' "$root/host-stage.sh" >/dev/null; then
  fail "host-stage enters a namespace itself"
fi
if grep -n 'allow-fixture-prefix' "$root/host-stage.sh" >/dev/null; then
  fail "the host harness enables the fixture namespace prefix"
fi
if grep -F -q "grep -q '^403 ' \"\$stage_dir/last.out\"" "$root/host-stage.sh"; then
  fail "redirect still requires a 403 status line on stdout"
fi
grep -q 'Proxy refused to open a tunnel' "$root/host-stage.sh" || fail "redirect does not check the proxy 403"
grep -q '403' "$root/host-stage.sh" || fail "redirect does not keep the 403 cause"
redir_err="$work/redir.err"
printf '%s\n' '302 Found' > "$work/redir.out"
printf '%s\n' 'error: Proxy refused to open a tunnel: 403 Forbidden' > "$redir_err"
grep -q '403' "$redir_err" || fail "sample proxy rejection has no 403"
grep -q 'Proxy refused to open a tunnel' "$redir_err" || fail "sample proxy rejection has no cause"
if grep -q '^403 ' "$work/redir.out"; then
  fail "sample stdout was treated as the proxy status"
fi
stop_lines=$(awk '/compose --env-file/ && / stop$/ { print }' "$root/host-stage.sh")
[ -n "$stop_lines" ] || fail "project stop is missing"
[ "$(grep -c 'stop_project_containers' "$root/host-stage.sh")" -ge 3 ] || fail "failure and stop do not share the project stop"
printf '%s\n' "$stop_lines" | while IFS= read -r line; do
  printf '%s\n' "$line" | grep -q -- '--profile oracle' || {
    echo "FAIL: a project stop omits the oracle profile: $line" >&2
    exit 1
  }
  printf '%s\n' "$line" | grep -q -- '--env-file' || {
    echo "FAIL: a project stop has no env file: $line" >&2
    exit 1
  }
done
if grep -q 'docker stop' "$root/host-stage.sh"; then
  fail "stop uses an unscoped docker stop"
fi
if awk '/stop proxy/ { print }' "$root/host-stage.sh" | grep -q -- '--profile oracle'; then
  fail "stopping the proxy also selects the oracle profile"
fi
grep -q 'stage-route.sh' "$root/host-stage.sh" || fail "the stage route helper is not used"
grep -q -- '--net=/proc/self/fd/' "$root/stage-route.sh" || fail "the route helper does not enter a pinned descriptor"
for label in sport8080-proof sport8080-relay direct-tcp-proxy443 proxy-false-fixture dns-stub-canary dns-udp-127.0.0.11 dns-tcp-sink dns-udp-external dns-host-gateway host-local-443 udp-quic-443 private-10 metadata-link-local cgnat-tailscale-range ipv6-disabled redirect cold-neighbor post-rule-opencode proxy-down relay-egress; do
  grep -q "$label" "$root/host-stage.sh" || fail "missing case $label"
done
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
cp "$root/testdata/fixture.js" "$root/testdata/client.js" "$root/testdata/health.js" "$root/testdata/dns-sink.js" "$work/"
mkdir -p "$work/dns"
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
DNS_SINK_IP=172.30.143.9
NEIGHBOR_IP=172.30.143.8
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
for name in ("app", "egress", "ingress", "publish"):
    assert nets[name]["enable_ipv6"] is False, name
assert client["dns"] == ["172.30.143.9"], client.get("dns")
sink = cfg["services"]["dns"]
assert sink["networks"]["app"]["ipv4_address"] == "172.30.143.9"
assert sink["user"] == "10001:10001"
assert "cap_add" not in sink
assert sink["sysctls"]["net.ipv4.ip_unprivileged_port_start"] == "0"
assert set(sink["networks"]) == {"app"}
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
assert app["dns"] == ["127.0.0.1"], app.get("dns")
assert "dns" not in cfg["services"]
mounts = app.get("volumes") or []
ready = False
for item in mounts:
    if isinstance(item, dict) and item.get("source") == "/run/valentinvera-reviewer-egress" and item.get("target") == "/run/egress-ready" and item.get("read_only") is True:
        ready = True
    if isinstance(item, str) and item.startswith("/run/valentinvera-reviewer-egress:/run/egress-ready") and item.endswith(":ro"):
        ready = True
assert ready, mounts
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

echo "== boot order and deploy"
"$root/test-boot-deploy.sh"

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

echo "== fixture idle deadline"
grep -q 'idleTimeout: 0' "$root/testdata/fixture.js" || fail "fixture still uses Bun's 10s idle default"
if grep -q 'idleTimeout: 10' "$root/testdata/fixture.js"; then
  fail "fixture sets the 10s idle deadline"
fi
grep -q 'timeout: false' "$root/testdata/client.js" || fail "client idle fetch enables Bun's socket idle timer"
grep -q 'idleMs + 30_000' "$root/testdata/client.js" || fail "client idle abort is not above the quiet interval"
command -v bun >/dev/null 2>&1 || fail "bun is required to prove the fixture stays quiet past 10s"
command -v openssl >/dev/null 2>&1 || fail "openssl is required for the fixture certificate"
idle_dir="$work/idle-fixture"
mkdir -p "$idle_dir"
openssl req -x509 -newkey rsa:2048 -keyout "$idle_dir/srv.key" -out "$idle_dir/srv.crt" -days 1 -nodes -subj /CN=idle.fixture >/dev/null 2>&1
printf '12000\n' > "$idle_dir/delay-ms"
idle_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cat > "$idle_dir/fetch.js" <<'EOF'
const response = await fetch(Bun.argv[2], {
  signal: AbortSignal.timeout(20_000),
  timeout: false,
  tls: { rejectUnauthorized: false },
})
process.stdout.write(await response.text())
EOF
FIXTURE_CERT="$idle_dir/srv.crt" FIXTURE_KEY="$idle_dir/srv.key" FIXTURE_DELAY="$idle_dir/delay-ms" FIXTURE_PORT="$idle_port" \
  bun "$root/testdata/fixture.js" >"$idle_dir/server.log" 2>&1 &
idle_pid=$!
ready=0
n=0
while [ "$n" -lt 50 ]; do
  if FIXTURE_PORT="$idle_port" bun -e 'const r = await fetch("https://127.0.0.1:" + process.env.FIXTURE_PORT + "/", { tls: { rejectUnauthorized: false }, signal: AbortSignal.timeout(1000) }); process.exit((await r.text()) === "ok" ? 0 : 1)' >/dev/null 2>&1; then
    ready=1
    break
  fi
  n=$((n + 1))
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  kill "$idle_pid" 2>/dev/null || true
  wait "$idle_pid" 2>/dev/null || true
  cat "$idle_dir/server.log" >&2 || true
  fail "fixture did not accept a connection"
fi
idle_start=$(date +%s)
if ! bun "$idle_dir/fetch.js" "https://127.0.0.1:${idle_port}/slow" >"$idle_dir/body" 2>"$idle_dir/fetch.err"; then
  kill "$idle_pid" 2>/dev/null || true
  wait "$idle_pid" 2>/dev/null || true
  cat "$idle_dir/server.log" "$idle_dir/fetch.err" >&2 || true
  fail "fixture quiet request failed"
fi
idle_elapsed=$(( $(date +%s) - idle_start ))
kill "$idle_pid" 2>/dev/null || true
wait "$idle_pid" 2>/dev/null || true
grep -q 'slow-ok' "$idle_dir/body" || fail "fixture quiet body was not slow-ok"
if [ "$idle_elapsed" -le 10 ]; then
  fail "fixture quiet request ended in ${idle_elapsed}s, which does not beat the 10s default"
fi
if grep -q 'timed out a request after 10 seconds' "$idle_dir/server.log"; then
  fail "fixture logged Bun's 10s idle timeout"
fi
echo "fixture stayed quiet ${idle_elapsed}s; the 310s host proof was not run"

echo "== listen port can be released and bound"
hold_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
hold_dir="$work/hold"
mkdir -p "$hold_dir"
: > "$hold_dir/control"
HEALTH_PORT="$hold_port" HEALTH_BIND=127.0.0.1 HEALTH_CONTROL="$hold_dir/control" HEALTH_STATE="$hold_dir/state" \
  bun "$root/testdata/health.js" >"$hold_dir/health.log" 2>&1 &
hold_pid=$!
n=0
while [ "$n" -lt 50 ]; do
  if grep -q '^listening' "$hold_dir/state" 2>/dev/null; then
    break
  fi
  n=$((n + 1))
  sleep 0.1
done
grep -q '^listening' "$hold_dir/state" || {
  kill "$hold_pid" 2>/dev/null || true
  wait "$hold_pid" 2>/dev/null || true
  fail "health listener did not start"
}
bun "$root/testdata/client.js" bind-proof "$hold_port" 127.0.0.1 >"$hold_dir/busy.out" 2>"$hold_dir/busy.err" && fail "bind succeeded while the health listener held the port"
grep -q 'EADDRINUSE' "$hold_dir/busy.err" || {
  kill "$hold_pid" 2>/dev/null || true
  wait "$hold_pid" 2>/dev/null || true
  fail "occupied listen port was not reported as EADDRINUSE"
}
printf 'release\n' > "$hold_dir/control"
n=0
while [ "$n" -lt 50 ]; do
  if grep -q '^released' "$hold_dir/state" 2>/dev/null; then
    break
  fi
  n=$((n + 1))
  sleep 0.1
done
grep -q '^released' "$hold_dir/state" || {
  kill "$hold_pid" 2>/dev/null || true
  wait "$hold_pid" 2>/dev/null || true
  fail "health listener did not release the port"
}
bun "$root/testdata/client.js" bind-proof "$hold_port" 127.0.0.1 >"$hold_dir/proof.out" 2>"$hold_dir/proof.err" || {
  kill "$hold_pid" 2>/dev/null || true
  wait "$hold_pid" 2>/dev/null || true
  cat "$hold_dir/proof.err" >&2 || true
  fail "source port could not handshake after the listener released it"
}
grep -q "connected 127.0.0.1:${hold_port}" "$hold_dir/proof.out" || fail "proof handshake did not use the released port"
printf 'listen\n' > "$hold_dir/control"
n=0
while [ "$n" -lt 50 ]; do
  if grep -q '^listening' "$hold_dir/state" 2>/dev/null; then
    break
  fi
  n=$((n + 1))
  sleep 0.1
done
curl -fsS "http://127.0.0.1:${hold_port}/" | grep -q ok || {
  kill "$hold_pid" 2>/dev/null || true
  wait "$hold_pid" 2>/dev/null || true
  fail "health listener did not answer after it was restored"
}
kill "$hold_pid" 2>/dev/null || true
wait "$hold_pid" 2>/dev/null || true
echo "listen port conflict is visible, and the same port can bind after release"

echo "== route-ip waits until the socket is connected"
bun -e '
import dgram from "node:dgram"
let threw = false
for (let i = 0; i < 5 && !threw; i += 1) {
  const sock = dgram.createSocket("udp4")
  try {
    sock.connect(9, "127.0.0.1")
    sock.address()
  } catch (error) {
    threw = error.code === "EBADF"
  }
  sock.close()
}
process.exit(threw ? 0 : 2)
' || fail "immediate getsockname did not fail with EBADF"
route_ip=$(bun "$root/testdata/client.js" route-ip 127.0.0.1 9 | tr -d "[:space:]")
[ "$route_ip" = "127.0.0.1" ] || fail "route-ip returned ${route_ip}"
echo "route-ip returned 127.0.0.1 after connect"

echo "== dns reply fields"
if grep -nE 'grep (-q )?['"'"'\"]ANSWER' "$root/host-stage.sh"; then
  fail "a DNS assertion still searches for the letters ANSWER"
fi
grep -F -q '[ "$dns_rcode" = 0 ] && [ "$dns_answers" = 1 ] && [ "$dns_addr" = 192.0.2.55 ]' "$root/host-stage.sh" || fail "canary is not an exact NOERROR answer"
grep -F -q '[ "$dns_rcode" = 5 ] && [ "$dns_answers" = 0 ]' "$root/host-stage.sh" || fail "direct denial is not an exact REFUSED"
grep -F -q '[ "$dns_rcode" = 2 ] && [ "$dns_answers" = 0 ]' "$root/host-stage.sh" || fail "stub denial is not an exact SERVFAIL"
parsed=$(parse_dns_reply 'rcode=0 answers=1 a=192.0.2.55') || fail "canary reply did not parse"
[ "$(printf '%s\n' "$parsed" | awk 'NR==1 { print; exit }')" = 0 ] || fail "canary rcode was not 0"
[ "$(printf '%s\n' "$parsed" | awk 'NR==2 { print; exit }')" = 1 ] || fail "canary answer count was not 1"
[ "$(printf '%s\n' "$parsed" | awk 'NR==3 { print; exit }')" = 192.0.2.55 ] || fail "canary address was not 192.0.2.55"
parsed=$(parse_dns_reply 'rcode=5 answers=0 a=') || fail "REFUSED reply did not parse"
[ "$(printf '%s\n' "$parsed" | awk 'NR==1 { print; exit }')" = 5 ] || fail "REFUSED rcode was not 5"
[ "$(printf '%s\n' "$parsed" | awk 'NR==2 { print; exit }')" = 0 ] || fail "REFUSED still had answers"
[ -z "$(printf '%s\n' "$parsed" | awk 'NR==3 { print; exit }')" ] || fail "REFUSED still had an address"
parsed=$(parse_dns_reply 'rcode=2 answers=0 a=') || fail "SERVFAIL reply did not parse"
[ "$(printf '%s\n' "$parsed" | awk 'NR==1 { print; exit }')" = 2 ] || fail "SERVFAIL rcode was not 2"
[ "$(printf '%s\n' "$parsed" | awk 'NR==2 { print; exit }')" = 0 ] || fail "SERVFAIL still had answers"
if parse_dns_reply 'NOANSWER rcode=5' >/dev/null 2>&1; then
  fail "NOANSWER was parsed as a reply"
fi
if parse_dns_reply 'NOANSWERrcode=2' >/dev/null 2>&1; then
  fail "a stripped NOANSWER was parsed as a reply"
fi
if parse_dns_reply 'ANSWER 192.0.2.55 rcode=0' >/dev/null 2>&1; then
  fail "the old ANSWER line was parsed as a reply"
fi
printf '%s\n' 'NOANSWER rcode=5' | grep -q 'ANSWER' || fail "the regression sample no longer contains the old substring"
printf '%s\n' canary.stage.test example.com canary.stage.test > "$work/queries"
[ "$(dns_query_count "$work/queries" canary.stage.test)" = 2 ] || fail "canary log count was not exact"
[ "$(dns_query_count "$work/queries" example.com)" = 1 ] || fail "denied-name log count was not exact"
[ "$(dns_query_count "$work/missing-queries" example.com)" = 0 ] || fail "a missing log was not zero"
echo "dns fields reject NOANSWER and count each question"

echo "== dns sink refuses arbitrary names"
dns_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
dns_log="$work/dns-queries"
: > "$dns_log"
DNS_PORT="$dns_port" DNS_LOG="$dns_log" CANARY_IP=192.0.2.55 bun "$root/testdata/dns-sink.js" >"$work/dns-sink.log" 2>&1 &
dns_pid=$!
n=0
canary=""
while [ "$n" -lt 50 ]; do
  canary=$(bun "$root/testdata/client.js" dns-udp 127.0.0.1 canary.stage.test "$dns_port" 2>/dev/null || true)
  parse_dns_reply "$canary" >"$work/dns-canary.txt" 2>/dev/null && [ "$(awk 'NR==1' "$work/dns-canary.txt")" = 0 ] && [ "$(awk 'NR==2' "$work/dns-canary.txt")" = 1 ] && [ "$(awk 'NR==3' "$work/dns-canary.txt")" = 192.0.2.55 ] && break
  n=$((n + 1))
  sleep 0.1
done
parse_dns_reply "$canary" >"$work/dns-canary.txt" 2>/dev/null && [ "$(awk 'NR==1' "$work/dns-canary.txt")" = 0 ] && [ "$(awk 'NR==3' "$work/dns-canary.txt")" = 192.0.2.55 ] || {
  kill "$dns_pid" 2>/dev/null || true
  wait "$dns_pid" 2>/dev/null || true
  fail "canary was not answered by the stage sink"
}
refused=$(bun "$root/testdata/client.js" dns-udp 127.0.0.1 example.com "$dns_port" 2>/dev/null || true)
tcp_refused=$(bun "$root/testdata/client.js" dns-tcp 127.0.0.1 example.com "$dns_port" 2>/dev/null || true)
kill "$dns_pid" 2>/dev/null || true
wait "$dns_pid" 2>/dev/null || true
parse_dns_reply "$refused" >"$work/dns-udp-refused.txt" || fail "udp example.com was not a DNS reply: $refused"
[ "$(awk 'NR==1' "$work/dns-udp-refused.txt")" = 5 ] && [ "$(awk 'NR==2' "$work/dns-udp-refused.txt")" = 0 ] && [ -z "$(awk 'NR==3' "$work/dns-udp-refused.txt")" ] || fail "udp example.com was not REFUSED with no answers: $refused"
parse_dns_reply "$tcp_refused" >"$work/dns-tcp-refused.txt" || fail "tcp example.com was not a DNS reply: $tcp_refused"
[ "$(awk 'NR==1' "$work/dns-tcp-refused.txt")" = 5 ] && [ "$(awk 'NR==2' "$work/dns-tcp-refused.txt")" = 0 ] && [ -z "$(awk 'NR==3' "$work/dns-tcp-refused.txt")" ] || fail "tcp example.com was not REFUSED with no answers: $tcp_refused"
grep -F -q -x canary.stage.test "$dns_log" || fail "canary query was not logged"
grep -F -q -x example.com "$dns_log" || fail "example.com query was not logged"
echo "dns sink answered the canary and refused example.com"

echo "== pinned stage route"
"$root/test-stage-route.sh" "$root"

echo "static checks passed; live transport was not run"
echo "work directory retained at $keep"
