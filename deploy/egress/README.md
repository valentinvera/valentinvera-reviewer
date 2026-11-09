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

This directory does not deploy the production host. The static checks do not
show that the network controls work.

## What is enforced

- The app container sets DNS to `127.0.0.1`. Docker 29 still writes its stub
  resolver, `127.0.0.11`, into `resolv.conf`, and forwards that stub only to
  the configured upstream. The entrypoint refuses any other nameserver or
  upstream, and it refuses to start if `example.com` resolves. The stub then
  has nowhere to send a lookup. The proxy keeps normal Docker DNS so it can
  resolve the two allowed names.
- The app network is `internal: true`. The entrypoint also refuses to start
  if a direct TCP handshake to `1.1.1.1:443` succeeds. That check is present
  so a routable network fails closed. On the hosting Docker 29.9.2 the
  same-bridge TCP check did succeed. The cloud VM bridge failure is a
  different machine and was not rerun.
- With `EGRESS_REQUIRED=1`, the entrypoint refuses a missing proxy URL, a
  different proxy URL, or any `NO_PROXY` value. It accepts only the production,
  CI and staging proxy URLs.
- Squid allows CONNECT to port 443 for the two names. It refuses IP literals,
  other ports, other names, and destinations in private, loopback, link-local,
  CGNAT, metadata and documentation ranges. It does not decrypt TLS and it does
  not log URL paths.
- `read_timeout` is 35 minutes. The deployed model deadline is 10 minutes when
  `AI_TIMEOUT_MS` is unset, and the application cap is 30 minutes.
- `internal: true` removes the default route. It does not stop a packet on
  that bridge from reaching the host gateway, a link-local address, or another
  container on the same bridge. Those paths are covered only after the scoped
  nft tables are installed. The tables are `inet` and `bridge`, both named for
  the stage, at priority -150, which is before the priority-0 filter chains
  Docker and Tailscale use. There is no OUTPUT chain and no flush. Traffic
  that does not arrive on one of the four stage bridges is left to the later
  chains.

| Bridge  | To the host                                                                                       | New flow that stays allowed                                                                                   | Reply                      | Everything else on that bridge                                                                 |
| ------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------- |
| App     | IPv6 dropped; established IPv4 kept; other IPv4 dropped                                           | TCP to the proxy on port 3128. A stage table also accepts UDP and TCP port 53 to that stage's sink `.9` only. | established conntrack only | dropped, including IPv6 and a new flow whose source port is 3128                               |
| Ingress | IPv4 and IPv6 dropped, including an established session from the host                             | TCP from the relay `.2` to the app `.10` on the one listen port                                               | established conntrack only | dropped, including a new session from the app to the relay and a new flow from the listen port |
| Publish | IPv6 dropped; established IPv4 kept; other new IPv4 dropped                                       | none                                                                                                          | established conntrack only | dropped, including IPv6 and a new flow whose source port is the listen port                    |
| Egress  | inet INPUT drops host-local IPv4 except an established session. Bridge INPUT is a different hook. | Routed TCP 443 only after the bogon drop. Same-bridge TCP 443, and a stage fixture on 8443 before that drop.  | established conntrack only | other new IPv4 and IPv6 dropped. No source-port accept.                                        |

A source port does not prove an established reply. The bridge rules accept
`ct state established,related` and the directional new flows above. They do
not accept a new flow because it comes from port 3128, port 443, or the listen
port. Production install does not pass the fixture address or the DNS sink,
so port 8443 and the sink's port 53 are not allowed there. The fixture
address is inside `172.16.0.0/12`, and the stage exception is placed before
the bogon drop so the quiet oracle can still reach it after the rules are
installed. The stage DNS sink is a container on the app bridge. Without an
exception, that bridge drops the client's lookup before it arrives. The stage
table accepts only the sink address `172.30.<octet>.9` on UDP and TCP port 53.
The sink runs as uid 10001 and sets `net.ipv4.ip_unprivileged_port_start=0`
in its own network namespace so it can bind port 53. It does not add
`NET_BIND_SERVICE`. A failed bind exits. The production app's only configured
resolver remains `127.0.0.1`.

A direct query to the sink is the sink's own answer: the canary is NOERROR
with `192.0.2.55`, and any other name is REFUSED (rcode 5) with no answer
records. A query to the stage client's Docker stub at `127.0.0.11` is a
different reply. Docker 29's embedded resolver (`forwardExtDNS`) returns an
upstream NOERROR answer unchanged, so the canary through the stub is
`192.0.2.55` and the sink logs that question. The same function treats an
upstream REFUSED as a reason to try the next server. The stage client has
only the sink, so the stub discards that REFUSED and answers SERVFAIL
(rcode 2) with no records. The question still reached the sink. SERVFAIL
from the stub is that Docker behavior, not a second policy and not a
successful answer.

Bridge INPUT and inet INPUT are not the same decision. Bridge INPUT sees a
frame whose Ethernet destination is that bridge. On the egress bridge, the
proxy's route to the public internet uses the gateway MAC, so a new TCP port
443 frame hits bridge INPUT before the host decides whether to route it.
Accepting that frame there is not permission to deliver it to a host service
and it is not permission to skip the bogon check. inet INPUT still drops a
packet the route lookup delivers to the host, including port 443. inet FORWARD
still drops bogons, then accepts TCP 443, then drops every other packet
forwarded from that bridge. App, ingress, and publish bridge INPUT do not
accept this routed exception. One host run recorded 9 IPv4 drops in egress
bridge INPUT and zero packets on both port 443 forward rules while GitHub
timed out. Those counters are compatible with this gate. They do not identify
the nine frames, and this text is not a claim that the next run will pass.

The previous static check grepped the publish-bridge drop and the
`--ingress-network` rollback filter. It did not require the ingress bridge to
appear in the rendered rules, so the second app interface was uncovered. The
check now parses the ruleset.

## Limits that remain

- These rules are absent until `install` succeeds. A reboot removes them.
  The harness does not install or enable the systemd unit. Starting the app
  before the rules exist is not fail-closed, and that boot path has not been
  tested. This is not a production-ready control.
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

The names in the table above are examples. The host harness does not reuse a
name, subnet, bridge, port, or nft table that already exists, including those
examples and the production bridge `br-f5d584fd553b`.

`deploy/egress/test-egress.sh` only runs secret-free static checks. It does
not start containers. The host command is:

```sh
sudo deploy/egress/host-stage.sh run --stage-dir /var/tmp/vvr-stage-manual
```

Use an empty stage directory. The harness allocates a project `vvrst` plus six
hex digits, bridges `br-vvr-s<suffix>a`, `e`, `i` and `p`, four free
`172.30.0.0/16` /24s outside the examples above, and a loopback port in
20000-20899. It will not reuse the retained `a41b73`, `e7b421`, `b83c52`, `7fa384`, or `4dc812` stages. It renders Compose
and refuses the result if the app network is
not internal or if a capability, the host network, or the Docker socket
appears. It does not mount production data, backups, or secrets.

It stops before creating those resources when any planned name is already
present. Built-in networks such as `host` and `none` have no IPAM config.
That is recorded as a network with no subnet. A failed `docker network
inspect` stops the run and prints the inventory collected so far. On a later
failure the harness runs `docker compose stop` and prints the
inventory. It does not run `docker compose down`, `docker rm`, `docker run
--rm`, or nft rollback. Stopped containers, networks, the stage directory, and
any nft table that was installed stay on the host. `host-stage.sh stop --plan
<stage>/plan` stops containers and leaves the nft table in place. Rollback is
a separate `host-rules.sh rollback --confirm-stopped` after those containers
are stopped, and it refuses while one is still running.

Worst case is about 30 minutes: up to 10 minutes to build the proxy image, two
310 second quiet TLS fixtures, and the shorter HTTPS checks. The same quiet
request runs before the rules and again after them. A success before the rules
is not the post-rule result. If the app cannot open TCP to the proxy, or the
published port does not answer, the harness stops there. That path does not
call GitHub or OpenCode and does not install nft. The quiet fixture is not
shortened below 310 seconds.

After the rules are installed, loopback and the allowed GitHub path are checked,
and the 310 second quiet tunnel runs again before any negative case. A miss in
one negative case is recorded and the others still run. A completed handshake
on a flow that should be denied stops the run immediately. The result is not
success while any required case is failed or not exercised.

The source-port checks bind port 3128 on the address the client uses toward the
proxy, and port 8080 on the ingress address the health listener uses. The
address is read only after the datagram socket finishes connecting. The health
listener is asked to release port 8080 and is restored afterward; loopback
health has to answer again. Source port 8080 must first complete a handshake
to a listener on that same address. `stage-route.sh` opens the stage client's
Docker netns file, checks the container id, compose project, service, name,
running state, and cgroup, and refuses the host namespace, the caller's
namespace, and any sandbox shared with another container. It enters only that
pinned descriptor. It does not pass a process id to `nsenter`. The route is
one /32 for the fixture address via the proxy, so the numeric TCP and the
`proxy: false` TLS fetch are real packets. They count only when the app-bridge
drop moves. The proxied fixture request has to return 200 first, with the
fixture name as SNI on the direct attempt. DNS failure is a separate case.

The production app's only configured stub forwarder is `127.0.0.1`. The stage
client's only forwarder is a resolver on the app network. That resolver
answers `canary.stage.test` and refuses every other name, and it records the
question. A SERVFAIL with no record is not a pass. UDP and TCP port 53 toward
`192.0.2.1`, and UDP port 53 toward the app gateway, are separate drop checks.
The proxy keeps the host resolver so the allowed HTTPS names still resolve.
The host resolver is not changed.

IPv6 is checked by inspecting the four stage networks and their containers. A
pass means IPv6 is disabled. It is not a runtime filter proof. The redirect
case keeps the 302 and the proxy 403. OpenCode is requested again after the
rules. A new stage container is the cold neighbor: its ARP entry must be
absent, then present, and the TCP attempt must hit the drop counter. No host
or production neighbor table is flushed. Stopping the proxy is a 15 second
observation, and the allowed GitHub path has to work again after it starts.

These rows are not a production deployment. They do not prove boot, deploy, or
startup before the tables exist. The Squid and socat images are not scanned.
An allowed API request can still carry data out. A counter that does not move
is not exercised, and any case that is not `PASS` makes the harness exit
nonzero.

Docker programs a published port on the container's default-gateway network.
An internal-only container has no gateway, so Docker 29.9.2 accepted the
requested mapping and left `NetworkSettings.Ports` null. That is what the
host observed for `127.0.0.1:20831`. The app stays on internal networks only.
A separate socat process is the loopback publisher. It joins one internal
network with the app and one ordinary network that exists so Docker has a
gateway to publish `127.0.0.1`. It listens on one unprivileged port and
connects only to `172.30.<octet>.10` on that same port. It is not attached to
the proxy network. Its publish network has masquerade disabled. Once the
scoped nft table is installed, new packets from that publish bridge are
dropped and established replies are kept. The host has run this relay, and
loopback health passed once after the tables were installed. The post-rule
GitHub request on that run timed out. The second quiet tunnel and the
source-port checks have not passed. The cloud VM bridge failure was not
rerun and is not evidence about this host.

The relay image uses the same Alpine digest as the proxy and `socat=1.8.1.3-r0`.
It runs as uid 65534, read-only, with every capability
dropped. It has no secret, data, backup, or Docker socket mount. A compromised
relay can still try to use the publish-network route until those nft rules
exist, and it can open TCP to the single app address it is given. It cannot
see the proxy allowlist path because it is not on that network. Allowed-API
exfiltration from the app remains.

Commands the harness uses and does not install: `timeout`, `flock`, `nft`,
`openssl`, `docker`, `ss`, `ip`, `awk`, `curl`, and `od`.

## Host activation

Not authorized. `host-stage.sh` does not install the systemd unit, does not
copy files to `/usr/local/sbin`, and does not recreate the production app.
The steps below stay here so a later activation is not improvised. Do not
flush filter tables, restart Docker, restart Tailscale, or recreate the
running app until its queue has been drained on purpose.

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
     --app-bridge br-vvr-app --egress-bridge br-vvr-egress \
     --ingress-bridge br-vvr-ingress --publish-bridge br-vvr-publish \
     --ingress-relay 172.30.219.2 --ingress-upstream 172.30.219.10 \
     --ingress-port 3000
   sudo valentinvera-reviewer-egress status \
     --app-bridge br-vvr-app --egress-bridge br-vvr-egress \
     --ingress-bridge br-vvr-ingress --publish-bridge br-vvr-publish \
     --ingress-relay 172.30.219.2 --ingress-upstream 172.30.219.10 \
     --ingress-port 3000
   ```

6. Recreate the app with `deploy/egress/compose.yml` and
   `production.env.example`, still published on `127.0.0.1:3000` by the
   ingress relay, with the existing data, backup and secret directories. Keep
   the backup mount writable. The backup timer and the wrapper script stay as
   they are. This step is not authorized.

`nftables.service` is disabled on the host and `netfilter-persistent` is not
installed. Do not enable either. This unit loads `inet reviewer_egress` and
`bridge reviewer_egress`.
Docker and Tailscale rewrites do not delete a separate nft table. A reboot
does, unless the unit is enabled. Run `install` again after a Tailscale or
Docker restart if `status` fails.

Rollback is `host-rules.sh rollback --confirm-stopped` for one named table.
It refuses while a container is still running on the staged networks, and it
does not run `nft flush ruleset` or `iptables-restore`. `install` refuses when
that table already exists instead of deleting it first. The lock wait is 15
seconds.

## Proxy image

The proxy and relay images use Alpine 3.22.8 amd64
`sha256:9db2934886712d877c932e07249c75a59e6ca27adfbccc05261987a17bef2d63`,
Squid 6.12-r0, and socat 1.8.1.3-r0. OpenSSL, musl, BusyBox, and zlib are
pinned as well. `apk add` of Squid or socat does not upgrade packages already
in the base, so those pins are explicit. A cloud package scan is not a runtime
or production proof, and it does not mark either image safe. The process is
intended to run as uid 31, drop every capability,
and mount no secret, backup, data, or Docker socket. Squid would see the
CONNECT hostname and the resolved address, not the TLS payload. The staging
fixture listens on 8443 without an added capability. That exception is only in
a generated test config and, for a stage table, in the rendered nft rules.
The committed `squid.conf` still allows port 443 only. Bun's server idle
timer cannot be set above 255 seconds, so the fixture disables its own idle
timer. The client abort stays at the quiet interval plus 30 seconds, and the
harness timeout stays at the quiet interval plus 40 seconds. Squid
`read_timeout` stays 35 minutes. `AI_TIMEOUT_MS` is unchanged.
