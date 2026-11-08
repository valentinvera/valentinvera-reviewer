#!/bin/sh
# Forward one TCP port to one IPv4 address. There is no hostname and no second target.
set -eu

if [ $# -ne 0 ]; then
  echo "ingress relay takes no arguments" >&2
  exit 1
fi

listen=${INGRESS_LISTEN_PORT:?set INGRESS_LISTEN_PORT}
upstream=${INGRESS_UPSTREAM:?set INGRESS_UPSTREAM}

case "$listen" in
  ''|*[!0-9]*)
    echo "listen port must be numeric" >&2
    exit 1
    ;;
esac
if [ "$listen" -lt 1024 ] || [ "$listen" -gt 65535 ]; then
  echo "listen port must be unprivileged" >&2
  exit 1
fi

case "$upstream" in
  *.*.*.*:*) ;;
  *)
    echo "upstream must be one IPv4 and port" >&2
    exit 1
    ;;
esac

ip=${upstream%:*}
port=${upstream##*:}
case "$ip" in
  *:*)
    echo "upstream must be one IPv4 and port" >&2
    exit 1
    ;;
esac
if [ "$port" != "$listen" ]; then
  echo "upstream port must match the listen port" >&2
  exit 1
fi

printf '%s\n' "$ip" | awk -F. 'BEGIN { ok=0 }
  NF==4 && $1==172 && $2==30 && $4==10 && $3 ~ /^[1-9][0-9]*$/ && $3+0>=128 && $3+0<=251 { ok=1 }
  END { exit ok ? 0 : 1 }' || {
  echo "upstream must be the single address 172.30.<octet>.10" >&2
  exit 1
}

exec socat \
  "TCP-LISTEN:${listen},bind=0.0.0.0,reuseaddr,fork,max-children=16" \
  "TCP:${ip}:${port}"
