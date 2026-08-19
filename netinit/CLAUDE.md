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

## Ground rules

- Before running `docker compose build`/`up`/`restart` against a live consumer's container,
  confirm it's actually safe - someone else may be iterating on it.
