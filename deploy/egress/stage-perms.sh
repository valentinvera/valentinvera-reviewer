#!/bin/sh
# Map a container uid through a subordinate-uid file. Does not change userns.
set -eu

mode="print"
subuid=""
remap_user=""
container_uid=""
path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --print) mode="print"; shift ;;
    --apply) mode="apply"; shift ;;
    --subuid) subuid="$2"; shift 2 ;;
    --remap-user) remap_user="$2"; shift 2 ;;
    --container-uid) container_uid="$2"; shift 2 ;;
    --path) path="$2"; shift 2 ;;
    --identity) remap_user=""; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$container_uid" in
  ''|*[!0-9]*) echo "container uid must be numeric" >&2; exit 1 ;;
esac
if [ "$container_uid" -eq 0 ] || [ "$container_uid" -gt 65535 ]; then
  echo "refusing container uid $container_uid" >&2
  exit 1
fi

if [ -z "$remap_user" ]; then
  host_uid="$container_uid"
else
  if [ -z "$subuid" ] || [ ! -f "$subuid" ]; then
    echo "subuid file is required when a remap user is set" >&2
    exit 1
  fi
  range=$(awk -F: -v user="$remap_user" '$1 == user { print $2 " " $3; exit }' "$subuid")
  if [ -z "$range" ]; then
    echo "remap user $remap_user is not in $subuid" >&2
    exit 1
  fi
  base=$(printf '%s\n' "$range" | awk '{ print $1 }')
  count=$(printf '%s\n' "$range" | awk '{ print $2 }')
  if [ "$container_uid" -ge "$count" ]; then
    echo "container uid $container_uid is outside the remap range" >&2
    exit 1
  fi
  host_uid=$((base + container_uid))
fi

if [ "$mode" = "print" ]; then
  printf '%s\n' "$host_uid"
  exit 0
fi

if [ -z "$path" ] || [ ! -e "$path" ]; then
  echo "path is required for --apply" >&2
  exit 1
fi
chown "$host_uid:$host_uid" "$path"
chmod 0400 "$path"
printf '%s\n' "$host_uid"
