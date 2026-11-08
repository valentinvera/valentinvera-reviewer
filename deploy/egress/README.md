# App-only egress

The review worker is intended to open HTTPS only to `api.github.com:443` and
`opencode.ai:443`. A small Squid process would accept CONNECT tunnels for those
exact names. The app network is internal. Host rules for the two app bridges
are meant to run before Docker, UFW and Tailscale rules, and they do not change
any other project or the host OUTPUT chain.

Nothing here has been proven on the production host. A cloud VM running Docker
29.1.3 without user namespaces did not deliver Ethernet frames between two
containers on the app bridge: the client sent SYNs to the proxy MAC, nftables
drop counters did not move, and the proxy veth received nothing. The host
could open TCP to Squid on the same address. A single-homed container on that
bridge also received nothing. Published ports on that internal network stayed
unset. GitHub, OpenCode, the long quiet tunnel, and containment were not
reached. Do not activate this on production from that result.

This directory does not deploy the production host. Apply it only after
`deploy/egress/test-egress.sh` passes on the separate staging project.

## What is enforced

- The app container sets DNS to `127.0.0.1`. Docker 29 still writes its stub
  resolver, `127.0.0.11`, into `resolv.conf`, and forwards that stub only to
  the configured upstream. The entrypoint refuses any other nameserver or
  upstream, and it refuses to start if `example.com` resolves. The stub then
  has nowhere to send a lookup. The proxy keeps normal Docker DNS so it can
  resolve the two allowed names.
- The app network is `internal: true`. The entrypoint also refuses to start
  if a direct TCP handshake to `1.1.1.1:443` succeeds. That check is present
  so a routable network fails closed. It was not the thing that blocked the
  cloud VM: frames never arrived on the next container.
- With `EGRESS_REQUIRED=1`, the entrypoint refuses a missing proxy URL, a
  different proxy URL, or any `NO_PROXY` value. It accepts only the production,
  CI and staging proxy URLs.
- Squid allows CONNECT to port 443 for the two names. It refuses IP literals,
  other ports, other names, and destinations in private, loopback, link-local,
  CGNAT, metadata and documentation ranges. It does not decrypt TLS and it does
  not log URL paths.
- `read_timeout` is 35 minutes. The deployed model deadline is 10 minutes when
  `AI_TIMEOUT_MS` is unset, and the application cap is 30 minutes.
- The host table `inet reviewer_egress` accepts established replies from the
  app bridge, allows a new connection only to the proxy on port 3128, then
  drops other new traffic from that bridge. From the egress bridge it drops
  IPv6, bogons and anything that is not TCP 443.

## Limits that remain

- A request that is allowed to `api.github.com` or `opencode.ai` can still send
  data to those APIs. This filter does not read the review body.
- `opencode.ai` is behind Cloudflare. A CONNECT proxy that does not decrypt TLS
  cannot tell a real OpenCode response from another site reached with the same
  SNI.
- `proxy: false` in process code cannot leave the internal network, but it also
  cannot use the proxy. That fails closed only while the app network stays
  internal and the host rules stay installed.
- The image entrypoint does nothing when `EGRESS_REQUIRED` is unset, so an
  older compose file still boots. Enforcement starts when this compose file and
  the host unit are both in use.

## Staging

Use a separate Compose project, a different loopback port, and empty
directories. Do not mount production data, backups or secrets.

```sh
docker compose --env-file deploy/egress/staging.env.example \
  -f deploy/egress/compose.yml up -d proxy
```

Fill `REVIEWER_IMAGE` and three empty directories before starting the `app`
profile. Suggested host values:

| Setting       | Staging                   | CI                   | Production              |
| ------------- | ------------------------- | -------------------- | ----------------------- |
| Project       | `reviewer-egress-staging` | `reviewer-egress-ci` | `valentinvera-reviewer` |
| Loopback port | `13100`                   | `13111`              | `3000`                  |
| App subnet    | `172.30.210.0/24`         | `172.30.209.0/24`    | `172.30.208.0/24`       |
| Proxy         | `172.30.210.2`            | `172.30.209.2`       | `172.30.208.2`          |
| App bridge    | `br-vvr-stga`             | `br-vvr-cia`         | `br-vvr-app`            |
| Egress bridge | `br-vvr-stge`             | `br-vvr-cie`         | `br-vvr-egress`         |
| nft table     | `reviewer_egress_staging` | `reviewer_egress_ci` | `reviewer_egress`       |

`deploy/egress/test-egress.sh` builds the proxy and then requires TCP from the
app container to the proxy and a published loopback health check before any
allow, deny, or idle assertion. On the cloud VM those two checks failed, so
the script stopped. It never uses the production bridge names. A passing run
would hold a local TLS tunnel with no bytes for at least 310 seconds and
install only the CI table.

## Host activation

Do this after staging has passed. Do not flush filter tables, restart Docker,
restart Tailscale, or recreate the running app until its queue has been drained
on purpose.

1. Build and tag the proxy image from `deploy/egress`.
2. Copy `host-rules.sh` to `/usr/local/sbin/valentinvera-reviewer-egress` and
   the systemd unit to `/etc/systemd/system/`.
3. `systemctl daemon-reload` and enable the unit. The unit has no `ExecStop`.
   Stopping it does not remove rules while the app is running.
4. Before the first install, arm a one-shot rollback that a reboot cannot
   cancel by itself:

   ```sh
   sudo systemd-run --on-active=20min --unit=reviewer-egress-rollback \
     /usr/local/sbin/valentinvera-reviewer-egress rollback
   ```

   Cancel that timer with `systemctl stop reviewer-egress-rollback.timer` only
   after `status` is healthy and the app can reach both allowed hosts.

5. Install the rules once the new bridges exist:

   ```sh
   sudo valentinvera-reviewer-egress install \
     --app-bridge br-vvr-app --egress-bridge br-vvr-egress
   sudo valentinvera-reviewer-egress status \
     --app-bridge br-vvr-app --egress-bridge br-vvr-egress
   ```

6. Recreate the app with `deploy/egress/compose.yml` and
   `production.env.example`, still on `127.0.0.1:3000`, with the existing data,
   backup and secret directories. Keep the backup mount writable. The backup
   timer and the wrapper script stay as they are.

`nftables.service` is disabled on the host and `netfilter-persistent` is not
installed. Do not enable either. This unit loads only `inet reviewer_egress`.
Docker and Tailscale rewrites do not delete a separate nft table. A reboot
does, unless the unit is enabled. Run `install` again after a Tailscale or
Docker restart if `status` fails.

Rollback is `valentinvera-reviewer-egress rollback`. It deletes that one table.
It does not run `nft flush ruleset` or `iptables-restore`.

## Proxy image

The proxy image is Alpine 3.22.1 with Squid 6.12-r0, both pinned in the
Dockerfile. The process runs as uid 31, drops every capability, and has no
secret, backup, data or Docker socket mount. Squid sees the CONNECT hostname
and the resolved address. It does not see the TLS payload.
