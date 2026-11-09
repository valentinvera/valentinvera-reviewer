#!/bin/sh
# Update the production reviewer image without dropping egress.
# The host compose file and production.env stay in place. This script does
# not delete networks, nft tables, backups, or the proxy and relay.
set -eu

app_dir="${APP_DIR:-/srv/apps/valentinvera-reviewer}"
rules="${EGRESS_RULES:-/usr/local/sbin/valentinvera-reviewer-egress}"
docker_cmd="${EGRESS_DOCKER:-docker}"
ready_dir="${EGRESS_READY_DIR:-/run/valentinvera-reviewer-egress}"
curl_cmd="${EGRESS_CURL:-curl}"
health_attempts="${EGRESS_HEALTH_ATTEMPTS:-30}"
health_sleep="${EGRESS_HEALTH_SLEEP:-2}"

# authorized_keys ForceCommand runs this script. The client command is
# SSH_ORIGINAL_COMMAND, not argv: "valentinvera-reviewer <sha>". The token
# is one line on stdin. A direct "deploy-app <sha>" still uses argv.
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
  # shellcheck disable=SC2086
  set -- ${SSH_ORIGINAL_COMMAND}
  if [ "${1:-}" != "valentinvera-reviewer" ] || [ $# -ne 2 ]; then
    echo "refusing command: ${SSH_ORIGINAL_COMMAND}" >&2
    exit 1
  fi
  sha=$2
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    IFS= read -r GITHUB_TOKEN || true
  fi
elif [ $# -eq 1 ]; then
  sha=$1
else
  echo "usage: deploy-app.sh GIT_SHA" >&2
  exit 1
fi
printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{7,40}$' || {
  echo "refusing image sha $sha" >&2
  exit 1
}

image="ghcr.io/valentinvera/valentinvera-reviewer:${sha}"
env_file="$app_dir/production.env"
deploy_env="$app_dir/.deploy.env"
compose_file="$app_dir/compose.yml"

[ -f "$env_file" ] || {
  echo "production.env is missing; refusing to write an image-only env" >&2
  exit 1
}
[ -f "$compose_file" ] || {
  echo "compose.yml is missing" >&2
  exit 1
}
grep -q 'EGRESS_REQUIRED' "$compose_file" || {
  echo "compose.yml is not the egress compose" >&2
  exit 1
}
grep -q '/run/egress-ready' "$compose_file" || {
  echo "compose.yml does not require the egress readiness mount" >&2
  exit 1
}
grep -q 'proxy:' "$compose_file" && grep -q 'ingress:' "$compose_file" || {
  echo "compose.yml has no proxy or relay" >&2
  exit 1
}

env_get() {
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$env_file"
}

for key in EGRESS_PROJECT_NAME EGRESS_IMAGE_TAG REVIEWER_IMAGE REVIEWER_BIND_PORT REVIEWER_DATA_DIR REVIEWER_BACKUP_DIR REVIEWER_SECRETS_DIR PROXY_IP APP_BRIDGE EGRESS_BRIDGE INGRESS_BRIDGE PUBLISH_BRIDGE INGRESS_RELAY_IP INGRESS_UPSTREAM_IP INGRESS_LISTEN_PORT; do
  if [ -z "$(env_get "$key")" ]; then
    echo "production.env is missing $key" >&2
    exit 1
  fi
done

previous_image=$(env_get REVIEWER_IMAGE)
[ -n "$previous_image" ] || {
  echo "production.env has no REVIEWER_IMAGE" >&2
  exit 1
}

write_image() {
  next=$1
  dir=$(dirname "$env_file")
  tmp=$(mktemp "$dir/.production.env.XXXXXX")
  awk -F= -v image="$next" '
    $1 == "REVIEWER_IMAGE" { print "REVIEWER_IMAGE=" image; next }
    { print }
  ' "$env_file" > "$tmp"
  if ! grep -q "^REVIEWER_IMAGE=${next}$" "$tmp" || ! grep -q '^REVIEWER_BACKUP_DIR=' "$tmp"; then
    echo "refusing to replace production.env with an incomplete file" >&2
    rm -f "$tmp"
    exit 1
  fi
  chmod --reference="$env_file" "$tmp"
  deploy_tmp=$(mktemp "$dir/.deploy.env.XXXXXX")
  cp "$tmp" "$deploy_tmp"
  chmod --reference="$env_file" "$deploy_tmp"
  mv "$deploy_tmp" "$deploy_env"
  mv "$tmp" "$env_file"
}

compose() {
  "$docker_cmd" compose --env-file "$env_file" -f "$compose_file" "$@"
}

restore_previous() {
  echo "restoring ${previous_image}" >&2
  write_image "$previous_image"
  compose --profile app up -d app || echo "restore of the previous image failed" >&2
  exit 1
}

if [ -n "${GITHUB_TOKEN:-}" ]; then
  printf '%s\n' "$GITHUB_TOKEN" | "$docker_cmd" login ghcr.io -u "${GITHUB_ACTOR:-deploy}" --password-stdin
fi

"$docker_cmd" pull "$image"

"$rules" install --before-bridges \
  --table reviewer_egress \
  --app-bridge "$(env_get APP_BRIDGE)" \
  --egress-bridge "$(env_get EGRESS_BRIDGE)" \
  --ingress-bridge "$(env_get INGRESS_BRIDGE)" \
  --publish-bridge "$(env_get PUBLISH_BRIDGE)" \
  --proxy-ip "$(env_get PROXY_IP)" \
  --ingress-relay "$(env_get INGRESS_RELAY_IP)" \
  --ingress-upstream "$(env_get INGRESS_UPSTREAM_IP)" \
  --ingress-port "$(env_get INGRESS_LISTEN_PORT)"

if [ "$(tr -d '[:space:]' < "$ready_dir/ready")" != "reviewer_egress" ]; then
  echo "egress rules are not ready; not starting the app" >&2
  exit 1
fi

compose up -d proxy ingress
write_image "$image"
if ! compose --profile app up -d app; then
  restore_previous
fi
port=$(env_get REVIEWER_BIND_PORT)
attempt=0
while [ "$attempt" -lt "$health_attempts" ]; do
  if [ ! -f "$ready_dir/ready" ] || [ "$(tr -d '[:space:]' < "$ready_dir/ready")" != "reviewer_egress" ]; then
    echo "egress rules are not ready; rolling back" >&2
    restore_previous
  fi
  if "$curl_cmd" -fsS --max-time 5 "http://127.0.0.1:${port}/health"; then
    echo "deployed ${image}"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep "$health_sleep"
done
echo "health check failed after ${health_attempts} attempts" >&2
restore_previous
