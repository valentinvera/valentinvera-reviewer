# CONNECT proxy. Alpine 3.22.8 amd64, Squid 6.12-r0.
# No TLS inspection. The allowlist is baked into the image.
# The base digest is the amd64 image manifest. apk add of Squid alone does
# not upgrade packages already in that image, so every pinned package is
# named here. zlib 1.4-r0 is newer than the copy inside this base.
FROM alpine:3.22.8@sha256:9db2934886712d877c932e07249c75a59e6ca27adfbccc05261987a17bef2d63

RUN apk add --no-cache \
      'busybox=1.37.0-r20' \
      'busybox-binsh=1.37.0-r20' \
      'ssl_client=1.37.0-r20' \
      'musl=1.2.5-r13' \
      'musl-utils=1.2.5-r13' \
      'libcrypto3=3.5.9-r0' \
      'libssl3=3.5.9-r0' \
      'zlib=1.4-r0' \
      'acl-libs=2.3.2-r1' \
      'popt=1.19-r4' \
      'logrotate=3.21.0-r1' \
      'libcap2=2.78-r0' \
      'libgcc=14.2.0-r6' \
      'libstdc++=14.2.0-r6' \
      'squid=6.12-r0' \
    && apk list -I | grep -qx 'busybox-1.37.0-r20 .*' \
    && apk list -I | grep -qx 'libssl3-3.5.9-r0 .*' \
    && apk list -I | grep -qx 'libcrypto3-3.5.9-r0 .*' \
    && apk list -I | grep -qx 'musl-1.2.5-r13 .*' \
    && apk list -I | grep -qx 'zlib-1.4-r0 .*' \
    && apk list -I | grep -qx 'squid-6.12-r0 .*' \
    && squid -v | grep -q 'Version 6.12' \
    && mkdir -p /var/run/squid /var/log/squid /tmp \
    && chown -R squid:squid /var/run/squid /var/log/squid /tmp

COPY render-squid-conf.sh /usr/local/bin/render-squid-conf.sh
COPY proxy-entrypoint.sh /usr/local/bin/proxy-entrypoint.sh
COPY allowlist /etc/egress/allowlist

RUN chmod 0555 /usr/local/bin/render-squid-conf.sh /usr/local/bin/proxy-entrypoint.sh \
    && chmod 0444 /etc/egress/allowlist

USER squid

ENTRYPOINT ["/usr/local/bin/proxy-entrypoint.sh"]
