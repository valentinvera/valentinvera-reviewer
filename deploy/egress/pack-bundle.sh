#!/bin/sh
# Pack the egress tree and keep the executable modes declared in git.
# Usage: pack-bundle.sh DEST_DIR
# Writes DEST_DIR/egress-checkpoint.tar and DEST_DIR/egress-checkpoint.tar.sha256.
# The destination is left in place. This script does not start containers.
set -eu

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: pack-bundle.sh DEST_DIR" >&2
  exit 1
fi

dest=$1
repo=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$repo"
stage="$dest/pack-src"
mkdir -p "$stage/egress-checkpoint"

paths=$(git ls-files -- deploy/egress .github/workflows/egress.yml Dockerfile)
if [ -z "$paths" ]; then
  echo "git ls-files returned no egress paths" >&2
  exit 1
fi

while IFS= read -r path; do
  if [ -z "$path" ]; then
    continue
  fi
  mkdir -p "$stage/egress-checkpoint/$(dirname "$path")"
  cp -- "$path" "$stage/egress-checkpoint/$path"
  mode=$(git ls-files -s -- "$path" | awk '{ print $1; exit }')
  case "$mode" in
    100755) chmod 0755 "$stage/egress-checkpoint/$path" ;;
    100644) chmod 0644 "$stage/egress-checkpoint/$path" ;;
    *)
      echo "unexpected git mode ${mode:-missing} for $path" >&2
      exit 1
      ;;
  esac
done <<EOF
$paths
EOF

git rev-parse HEAD > "$stage/egress-checkpoint/SOURCE_COMMIT"
(
  cd "$stage/egress-checkpoint"
  : > SHA256SUMS
  while IFS= read -r path; do
    if [ -n "$path" ]; then
      sha256sum -- "$path" >> SHA256SUMS
    fi
  done <<EOF
$paths
SOURCE_COMMIT
EOF
)

tar -C "$stage" -cf "$dest/egress-checkpoint.tar" egress-checkpoint
sha256sum -- "$dest/egress-checkpoint.tar" | awk '{ print $1 }' > "$dest/egress-checkpoint.tar.sha256"

entries=$(git ls-files -s -- deploy/egress .github/workflows/egress.yml Dockerfile)
while IFS= read -r entry; do
  if [ -z "$entry" ]; then
    continue
  fi
  mode=$(printf '%s\n' "$entry" | awk '{ print $1 }')
  path=$(printf '%s\n' "$entry" | awk '{ print $4 }')
  if [ "$mode" != "100755" ]; then
    continue
  fi
  listed=$(tar -tvf "$dest/egress-checkpoint.tar" "egress-checkpoint/$path" | awk '{ print $1 }')
  if [ "$listed" != "-rwxr-xr-x" ]; then
    echo "bundle lost the execute bit on $path ($listed)" >&2
    exit 1
  fi
done <<EOF
$entries
EOF
