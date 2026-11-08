#!/bin/sh
# Optional fail-closed check for the reviewed egress network.
# Unset EGRESS_REQUIRED keeps the previous direct-network behavior.
set -eu

if [ "${EGRESS_REQUIRED:-}" = "1" ]; then
  proxy="${EGRESS_PROXY_URL:-http://172.30.208.2:3128}"
  case "$proxy" in
    http://172.30.208.2:3128|http://172.30.209.2:3128|http://172.30.210.2:3128) ;;
    *)
      echo "EGRESS_PROXY_URL is not one of the reviewed proxy URLs" >&2
      exit 1
      ;;
  esac

  if [ "${HTTPS_PROXY:-}" != "$proxy" ] || [ "${HTTP_PROXY:-}" != "$proxy" ] || [ "${ALL_PROXY:-}" != "$proxy" ]; then
    echo "HTTPS_PROXY, HTTP_PROXY and ALL_PROXY must equal EGRESS_PROXY_URL" >&2
    exit 1
  fi

  if [ -n "${NO_PROXY:-}${no_proxy:-}" ]; then
    echo "NO_PROXY would bypass the egress proxy" >&2
    exit 1
  fi

  # Docker keeps its stub resolver at 127.0.0.11 and writes that address into
  # resolv.conf. The stub is harmless only when its upstream is loopback, so
  # a public lookup must fail before the process starts.
  nameservers=$(awk '/^nameserver[[:space:]]/ { print $2 }' /etc/resolv.conf 2>/dev/null || true)
  if [ -z "$nameservers" ]; then
    echo "resolv.conf has no nameserver" >&2
    exit 1
  fi
  for ns in $nameservers; do
    case "$ns" in
      127.0.0.1|127.0.0.11) ;;
      *)
        echo "nameserver $ns is not the loopback stub" >&2
        exit 1
        ;;
    esac
  done
  if grep -q 'ExtServers:' /etc/resolv.conf 2>/dev/null; then
    if ! grep -q 'ExtServers: \[127.0.0.1\]' /etc/resolv.conf; then
      echo "Docker DNS upstream is not 127.0.0.1" >&2
      exit 1
    fi
  fi
  if bun -e 'const found = await Bun.dns.lookup("example.com"); if (found) process.exit(0)'; then
    echo "public DNS resolved example.com; refusing to start" >&2
    exit 1
  fi

  # A missing host table leaves this network routable, because Docker 29 does
  # not publish ports on an internal network. Refuse to start if a direct TCP
  # handshake to a public address succeeds.
  if bun -e 'let opened = false; const timer = setTimeout(() => process.exit(1), 3000); try { await Bun.connect({ hostname: "1.1.1.1", port: 443, socket: { open(socket) { opened = true; socket.end(); }, data() {}, close() {}, error() {}, connectError() { clearTimeout(timer); process.exit(1); } } }); } catch { clearTimeout(timer); process.exit(1); } await Bun.sleep(2500); clearTimeout(timer); process.exit(opened ? 0 : 1);'; then
    echo "direct TCP to 1.1.1.1:443 succeeded; host egress rules are not enforcing" >&2
    exit 1
  fi
fi

exec "$@"
