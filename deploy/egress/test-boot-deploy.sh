#!/bin/sh
# Simulate boot order and a production deploy. No containers and no host nft.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
work=$(mktemp -d)
keep="$work"

fail() {
  echo "FAIL: $1" >&2
  echo "boot-deploy work directory left at $keep" >&2
  exit 1
}

unit="$root/valentinvera-reviewer-egress.service"
grep -q '^Before=docker.service$' "$unit" || fail "the unit does not run before docker"
grep -q '^WantedBy=docker.service$' "$unit" || fail "docker does not want the egress unit"
grep -q '^DefaultDependencies=no$' "$unit" || fail "the unit waits for the default docker dependency"
grep -q -- '--before-bridges' "$unit" || fail "the unit does not install name-keyed rules"
if grep -q -- '--if-bridges-present' "$unit"; then
  fail "the unit still succeeds when the bridges are absent"
fi
if grep -q '^ExecStop=' "$unit"; then
  fail "the unit removes rules when it stops"
fi
dropin="$root/docker.service.d.conf"
grep -q '^After=valentinvera-reviewer-egress.service$' "$dropin" || fail "docker is not ordered after the egress unit"
grep -q '^Requires=valentinvera-reviewer-egress.service$' "$dropin" || fail "docker can start when the egress unit fails"

prod_args="--table reviewer_egress --app-bridge br-vvr-app --egress-bridge br-vvr-egress --ingress-bridge br-vvr-ingress --publish-bridge br-vvr-publish --proxy-ip 172.30.208.2 --ingress-relay 172.30.219.2 --ingress-upstream 172.30.219.10 --ingress-port 3000"

mkdir -p "$work/bin" "$work/ready" "$work/lock"
cat > "$work/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_LOG"
if [ "$1" = "-c" ] && [ "$2" = "-f" ]; then
  exit 0
fi
if [ "$1" = "-f" ]; then
  cp "$2" "$NFT_RULES"
  exit 0
fi
if [ "$1" = list ]; then
  if [ -f "$NFT_RULES" ]; then
    cat "$NFT_RULES"
    exit 0
  fi
  exit 1
fi
exit 0
EOF
cat > "$work/bin/ip" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$work/bin/bun" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 0755 "$work/bin/nft" "$work/bin/ip" "$work/bin/bun"
NFT_LOG="$work/nft.log"
NFT_RULES="$work/nft.rules"
export NFT_LOG NFT_RULES
export EGRESS_NFT="$work/bin/nft"
export EGRESS_IP="$work/bin/ip"
export EGRESS_DOCKER="$work/bin/docker"
export EGRESS_LOCK_DIR="$work/lock"
export EGRESS_READY_DIR="$work/ready"
: > "$NFT_LOG"

# shellcheck disable=SC2086
"$root/host-rules.sh" install $prod_args >/dev/null 2>"$work/nobridge.err" && fail "install succeeded before the bridges existed"
grep -q 'required bridge is missing' "$work/nobridge.err" || fail "missing bridges were not a hard failure"
if grep -q '^-f ' "$NFT_LOG"; then
  fail "a missing bridge still loaded nft"
fi

: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install --before-bridges $prod_args >"$work/boot.out"
grep -q 'installed inet and bridge reviewer_egress' "$work/boot.out" || fail "name-keyed install did not load"
[ "$(grep -c '^-f ' "$NFT_LOG")" -eq 1 ] || fail "boot did not load the rules once"
[ "$(tr -d '[:space:]' < "$work/ready/ready")" = "reviewer_egress" ] || fail "boot did not mark the rules ready"

: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install --before-bridges $prod_args >"$work/restart.out"
grep -q 'already installed' "$work/restart.out" || fail "restart did not accept the existing tables"
if grep -q '^-f ' "$NFT_LOG"; then
  fail "restart reloaded the tables"
fi
[ "$(tr -d '[:space:]' < "$work/ready/ready")" = "reviewer_egress" ] || fail "restart cleared the readiness marker"

order="$work/order"
: > "$order"
ready_link="$work/egress-ready"
mkdir -p "$ready_link"
printf 'nameserver 127.0.0.1\n' > "$work/resolv.conf"
sed \
  -e 's#/run/egress-ready/ready#'"$ready_link/ready"'#' \
  -e 's#/etc/resolv.conf#'"$work/resolv.conf"'#' \
  "$root/app-entrypoint.sh" > "$work/entrypoint.sh"
chmod 0755 "$work/entrypoint.sh"
if PATH="$work/bin:$PATH" EGRESS_REQUIRED=1 "$work/entrypoint.sh" echo app-started >>"$order" 2>"$work/early.err"; then
  fail "the app started before the readiness marker"
fi
grep -q 'egress rules are not installed' "$work/early.err" || fail "early app start was not refused"
printf 'installed\n' >> "$order"
cp "$work/ready/ready" "$ready_link/ready"
PATH="$work/bin:$PATH" EGRESS_REQUIRED=1 HTTPS_PROXY=http://172.30.208.2:3128 HTTP_PROXY=http://172.30.208.2:3128 ALL_PROXY=http://172.30.208.2:3128 \
  "$work/entrypoint.sh" echo app-started >>"$order"
grep -q '^app-started$' "$order" || fail "the app did not start after the rules"
awk '
  $0 == "installed" { saw = 1 }
  $0 == "app-started" && !saw { exit 1 }
  END { if (!saw) exit 1 }
' "$order" || fail "the app started before the rules were installed"

saved=$(mktemp)
cp "$NFT_RULES" "$saved"
printf 'table inet reviewer_egress {}\n' > "$NFT_RULES"
: > "$NFT_LOG"
# shellcheck disable=SC2086
"$root/host-rules.sh" install --before-bridges $prod_args >/dev/null 2>"$work/diverge.err" && fail "a divergent table was replaced"
grep -q 'refusing to replace' "$work/diverge.err" || fail "divergent table was not refused"
if grep -q '^-f ' "$NFT_LOG"; then
  fail "a divergent table was rewritten"
fi
cp "$saved" "$NFT_RULES"
rm -f "$saved"

echo "== deploy keeps egress"
app="$work/app"
mkdir -p "$app/data" "$app/backups" "$app/secrets"
sed \
  -e "s#^##" \
  -e "s#^REVIEWER_DATA_DIR=.*#REVIEWER_DATA_DIR=$app/data#" \
  -e "s#^REVIEWER_BACKUP_DIR=.*#REVIEWER_BACKUP_DIR=$app/backups#" \
  -e "s#^REVIEWER_SECRETS_DIR=.*#REVIEWER_SECRETS_DIR=$app/secrets#" \
  "$root/production.env.example" > "$app/production.env"
grep -q '^REVIEWER_DATA_DIR=' "$app/production.env" || {
  printf '\nREVIEWER_DATA_DIR=%s\nREVIEWER_BACKUP_DIR=%s\nREVIEWER_SECRETS_DIR=%s\n' "$app/data" "$app/backups" "$app/secrets" >> "$app/production.env"
}
cp "$root/compose.yml" "$app/compose.yml"
old_image=$(awk -F= '$1=="REVIEWER_IMAGE"{print substr($0,index($0,"=")+1)}' "$app/production.env")
[ -n "$old_image" ] || fail "example env has no image"

cat > "$work/bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = login ] || [ "$1" = pull ]; then
  exit 0
fi
if [ "$1" = compose ]; then
  printf '%s\n' "$*" >> "$COMPOSE_LOG"
  exit 0
fi
exit 0
EOF
chmod 0755 "$work/bin/docker"
COMPOSE_LOG="$work/compose.log"
export COMPOSE_LOG
: > "$COMPOSE_LOG"
cat > "$work/bin/curl" <<'EOF'
#!/bin/sh
printf 'ok\n'
exit 0
EOF
chmod 0755 "$work/bin/curl"

APP_DIR="$app" EGRESS_RULES="$root/host-rules.sh" EGRESS_DOCKER="$work/bin/docker" EGRESS_CURL="$work/bin/curl" \
  EGRESS_READY_DIR="$work/ready" EGRESS_NFT="$work/bin/nft" EGRESS_IP="$work/bin/ip" EGRESS_LOCK_DIR="$work/lock" \
  "$root/deploy-app.sh" abcdef1 >"$work/deploy.out"
grep -q 'deployed ghcr.io/valentinvera/valentinvera-reviewer:abcdef1' "$work/deploy.out" || fail "deploy did not report the new image"
new_image=$(awk -F= '$1=="REVIEWER_IMAGE"{print substr($0,index($0,"=")+1)}' "$app/production.env")
[ "$new_image" = "ghcr.io/valentinvera/valentinvera-reviewer:abcdef1" ] || fail "production image was not updated"
cmp "$app/production.env" "$app/.deploy.env" || fail ".deploy.env is not the full production env"
grep -q "^REVIEWER_BACKUP_DIR=$app/backups$" "$app/.deploy.env" || fail "backup directory was dropped"
grep -q '^PROXY_IP=172.30.208.2$' "$app/.deploy.env" || fail "proxy address was dropped"
grep -q '^EGRESS_PROJECT_NAME=valentinvera-reviewer$' "$app/.deploy.env" || fail "compose project was dropped"
if grep -q '^IMAGE_TAG=' "$app/.deploy.env"; then
  fail "deploy wrote an IMAGE_TAG env"
fi
awk '
  / up -d proxy ingress$/ { proxy = NR }
  / --profile app up -d app$/ { app = NR }
  END { if (!(proxy > 0 && app > proxy)) exit 1 }
' "$COMPOSE_LOG" || fail "the app was started before the proxy and relay"
if grep -q ' down' "$COMPOSE_LOG"; then
  fail "deploy deleted the compose project"
fi

# ForceCommand: app name + sha, token on stdin. A few failed health checks retry.
cat > "$work/bin/curl" <<'EOF'
#!/bin/sh
n=0
if [ -f "$CURL_COUNT" ]; then
  n=$(cat "$CURL_COUNT")
fi
n=$((n + 1))
printf '%s\n' "$n" > "$CURL_COUNT"
if [ "$n" -lt 3 ]; then
  exit 1
fi
exit 0
EOF
chmod 0755 "$work/bin/curl"
CURL_COUNT="$work/curl.count"
export CURL_COUNT
: > "$COMPOSE_LOG"
printf '%s\n' 'token' | APP_DIR="$app" EGRESS_RULES="$root/host-rules.sh" EGRESS_DOCKER="$work/bin/docker" EGRESS_CURL="$work/bin/curl" \
  EGRESS_READY_DIR="$work/ready" EGRESS_NFT="$work/bin/nft" EGRESS_IP="$work/bin/ip" EGRESS_LOCK_DIR="$work/lock" \
  EGRESS_HEALTH_ATTEMPTS=5 EGRESS_HEALTH_SLEEP=0 \
  SSH_ORIGINAL_COMMAND='valentinvera-reviewer abcdef3' \
  "$root/deploy-app.sh" >"$work/ssh.out"
grep -q 'deployed ghcr.io/valentinvera/valentinvera-reviewer:abcdef3' "$work/ssh.out" || fail "force-command deploy did not report the image"
ssh_image=$(awk -F= '$1=="REVIEWER_IMAGE"{print substr($0,index($0,"=")+1)}' "$app/production.env")
[ "$ssh_image" = "ghcr.io/valentinvera/valentinvera-reviewer:abcdef3" ] || fail "force-command deploy did not keep the new image"
if SSH_ORIGINAL_COMMAND='other abcdef4' "$root/deploy-app.sh" >/dev/null 2>"$work/ssh-refuse.err"; then
  fail "a foreign command was accepted"
fi
grep -q 'refusing command' "$work/ssh-refuse.err" || fail "foreign command was not refused"

# A failed health check restores the previous image and does not leave the new one.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$work/bin/curl"
chmod 0755 "$work/bin/curl"
: > "$COMPOSE_LOG"
if APP_DIR="$app" EGRESS_RULES="$root/host-rules.sh" EGRESS_DOCKER="$work/bin/docker" EGRESS_CURL="$work/bin/curl" \
  EGRESS_READY_DIR="$work/ready" EGRESS_NFT="$work/bin/nft" EGRESS_IP="$work/bin/ip" EGRESS_LOCK_DIR="$work/lock" \
  EGRESS_HEALTH_ATTEMPTS=2 EGRESS_HEALTH_SLEEP=0 \
  "$root/deploy-app.sh" abcdef2 >"$work/rollback.out" 2>"$work/rollback.err"
then
  fail "a failed health check was treated as a deploy"
fi
restored=$(awk -F= '$1=="REVIEWER_IMAGE"{print substr($0,index($0,"=")+1)}' "$app/production.env")
[ "$restored" = "ghcr.io/valentinvera/valentinvera-reviewer:abcdef3" ] || fail "rollback did not restore the previous image: $restored"
cmp "$app/production.env" "$app/.deploy.env" || fail "rollback left .deploy.env different from production.env"
grep -q 'restoring ghcr.io/valentinvera/valentinvera-reviewer:abcdef3' "$work/rollback.err" || fail "rollback did not name the previous image"
grep -q "^REVIEWER_BACKUP_DIR=$app/backups$" "$app/production.env" || fail "rollback dropped the backup directory"

if grep -q 'scp ' "$root/../../.github/workflows/deploy.yml"; then
  fail "the deploy workflow still copies a script over ssh"
fi
grep -q 'valentinvera-reviewer ${GITHUB_SHA}' "$root/../../.github/workflows/deploy.yml" || fail "the deploy command is not the force-command app and sha"
grep -q 'echo "$GITHUB_TOKEN" | ssh' "$root/../../.github/workflows/deploy.yml" || fail "the deploy token is not on stdin"
grep -q 'StrictHostKeyChecking=yes' "$root/../../.github/workflows/deploy.yml" || fail "ssh host checking was removed"

echo "boot order and deploy simulation passed"
echo "work directory retained at $keep"
