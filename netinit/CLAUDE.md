# netinit

Scoped guidance for anyone (human or agent) working under `netinit/`. A tiny sidecar that
shares a target container's network namespace (Compose's `network_mode: service:<target>`)
and repeatedly points its default route at `router` (a router-docker instance), using the
`NET_ADMIN` capability the target container itself deliberately never gets. See this repo's
own top-level `CLAUDE.md`/`README.md` for the overall design, and code-docker's own
`docker-compose.yml`/`CLAUDE.md` for a worked example of wiring this in as
`code-docker-netinit`.

## What's here

- `Dockerfile` - a minimal `alpine` image with `iproute2`. Fetches `netshare/` from this
  same repo via `ADD https://github.com/qwreey/router-docker-client.git#main:netshare` at
  build time (not a local `COPY`, since Compose builds this image with its own
  `netinit`-scoped git context - see this repo's top-level `README.md`).
- `netinit-entrypoint.sh` - the loop itself: resolves `ROUTER_HOSTNAME` (default `router`)
  every 5s and applies the default route to it via `apply_default_route` (from
  `netshare/`), defensively (never exits non-zero on `router` not resolving - see the
  script's own comments for why, and for the "target's netns got recreated out from under
  us" exit-and-let-`restart:`-recreate case).

Note the env var names (`NETGATE_ENABLED`, `ROUTER_HOSTNAME`) still reflect this loop's
origin as part of code-docker's own egress lockdown, not a fully generic sidecar contract -
a second consuming project currently just reuses the same two env var names rather than
this being parameterized per-consumer.

## Known limitation: container-ID pinning on target recreate

`network_mode: service:<target>` resolves `<target>` to a concrete container ID **at create
time** and bakes that ID into the sidecar's own container config - it is not re-resolved
later. When the target container is recreated (new image, changed compose config, `docker
compose up -d` picking up any diff - anything that produces a new container ID rather than
reusing the old one), the sidecar is left pointing at a container ID that no longer exists.
It then fails to start with something like `joining network namespace of container: No such
container: <old-id>`, and because it's `restart: unless-stopped`, Docker just keeps retrying
that same dead ID forever rather than re-resolving the name.

This fails **silently** from the target's own point of view: the target container itself
stays `Up` (it never depended on the sidecar to start), it just quietly has no default route
and therefore no egress through router at all. There is no crash, no obviously-unhealthy
state to alert on - the failure surfaces only as "this workload's outbound traffic doesn't
work" or as the sidecar's own container showing `Restarting` in `docker compose ps`, which is
easy to miss if nothing is watching for it.

Recovery is manual: `docker compose up -d --no-deps <target>-netinit` re-creates the sidecar
against the target's current (post-recreate) container ID.

**This is exactly the failure mode `netinit-docker/` (a sibling directory in this repo,
see this repo's own top-level `CLAUDE.md`'s "netinit-docker wiring" section -
`netinit-docker/` has no `CLAUDE.md` of its own) was built to eliminate for Docker
deployments** - it holds no per-target
container-ID reference at all; it re-resolves every target's `SandboxKey` from the Docker API
on every reconcile cycle (a value Docker itself changes on every container restart anyway), so
a target recreate is a non-event rather than a silent breakage. If your deployment is Docker
(Compose) and can tolerate a single host-level agent with `NET_ADMIN`/`SYS_ADMIN` plus a
read-only `docker.sock` mount, prefer `netinit-docker/` over this sidecar.

`netinit/` remains the right choice, and is not being deprecated, for anything
`netinit-docker/`'s Docker-only design can't reach - most notably non-Docker engines (e.g. a
Kubernetes sidecar container sharing a pod's network namespace), where there is no Docker API
or `/var/run/docker/netns` to talk to in the first place.

## Ground rules

- Before running `docker compose build`/`up`/`restart` against a live consumer's container,
  confirm it's actually safe - someone else may be iterating on it.
