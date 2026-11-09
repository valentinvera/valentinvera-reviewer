#!/bin/sh
# Start Squid from the baked allowlist. Bind and source must be one of the
# three reviewed subnets (production, CI, staging).
set -eu

bind="${PROXY_BIND:-172.30.208.2:3128}"
src="${PROXY_SRC:-172.30.208.0/24}"

/usr/local/bin/render-squid-conf.sh \
  --bind "$bind" \
  --src "$src" \
  --allow-file /etc/egress/allowlist \
  > /tmp/squid.conf

exec squid -N -f /tmp/squid.conf
