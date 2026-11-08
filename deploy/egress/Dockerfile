# Small CONNECT proxy. Alpine 3.22.1 and Squid 6.12 are pinned.
# No TLS inspection. The allowlist is baked into the image.
FROM alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1

RUN apk add --no-cache 'squid=6.12-r0' \
    && mkdir -p /var/run/squid /var/log/squid /tmp \
    && chown -R squid:squid /var/run/squid /var/log/squid /tmp

COPY render-squid-conf.sh /usr/local/bin/render-squid-conf.sh
COPY proxy-entrypoint.sh /usr/local/bin/proxy-entrypoint.sh
COPY allowlist /etc/egress/allowlist

RUN chmod 0555 /usr/local/bin/render-squid-conf.sh /usr/local/bin/proxy-entrypoint.sh \
    && chmod 0444 /etc/egress/allowlist

USER squid

ENTRYPOINT ["/usr/local/bin/proxy-entrypoint.sh"]
