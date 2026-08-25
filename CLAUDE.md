# router-docker-client

The workload-side integration kit for
[router-docker](https://github.com/qwreey/router-docker) — anything a project needs to
actually sit behind a router-docker instance as its network boundary, as opposed to
router-docker itself (the boundary container). Split out of
[code-docker](https://github.com/qwreey/code-docker), router-docker's first real consumer,
since none of this is code-docker-specific — the env vars this repo's tools originally used
(`NETFILTER_FIX_INTERNAL_NETWORK`/`NETFILTER_FIX_EXTRA_INTERNAL_NETWORKS`, now deprecated, see
below) are named after the tool itself rather than that origin, though the default network
name they reference (`code-docker-internal`) still nods to it as the first consumer.

## What's here

- `netinit/` — sidecar that keeps a target container's default route pointed at router
  (`network_mode: service:<target>`, `NET_ADMIN`). Portable and engine-agnostic — the right
  choice for anything that isn't Docker Compose (e.g. a Kubernetes sidecar). Has a real
  limitation around target-container recreates; see that directory's own `CLAUDE.md`.
- `netinit-docker/` — host-side, label-driven agent, Docker-only by construction. Formerly
  `netfilter-fix/` (`fix.sh` renamed to `netinit-docker.sh`); it kept its original job and
  gained a second one, both reconciled from the Docker API on every cycle:
  1. **DOCKER-USER forward exemptions** — the original `netfilter-fix` job. Docker Engine
     29.x's `DOCKER-INTERNAL` hardening blocks router's own FORWARD traffic into
     `internal: true` networks at the host netfilter level, which `NET_ADMIN` inside
     router's own netns cannot reach.
  2. **Default routes** — the same job `netinit/` does, but without a per-target sidecar:
     this process `nsenter`s into a target container's network namespace *from the host*
     (using its own `CAP_NET_ADMIN`/`CAP_SYS_ADMIN` against the `SandboxKey` netns handle
     Docker already publishes under `/var/run/docker/netns`), so the target container
     itself needs zero capabilities of its own. It exists specifically to sidestep
     `netinit/`'s container-ID pinning problem — see "netinit-docker wiring" below and
     `netinit/CLAUDE.md`'s limitations section.

  `netinit-docker` does **not** replace `netinit/` — a non-Docker engine still needs the
  portable sidecar, and `netinit-docker` is Docker-only by construction (it talks to the
  Docker API and `/var/run/docker/netns` directly). No dependency on `netshare/`.
- `netshare/` — the shared POSIX `sh` functions `netinit/` (and code-docker's own
  bootstrap/dind sidecar) use: `wait_until`, `apply_default_route`, `apply_nameserver`.
  `netinit-docker/` does not use it — it isn't a per-target entrypoint script and has its
  own reconcile-loop shape instead.

## How consumers pull this in

**Not a git submodule.** Every consumer fetches directly at build time via Docker/Compose's
native remote-git support — no local checkout, no submodule bookkeeping, no bump-commit
needed anywhere when this repo changes:

- As a whole service's build context (for `netinit`/`netinit-docker`, each with their own
  `Dockerfile`):
  ```yaml
  build:
    context: https://github.com/qwreey/router-docker-client.git#main:netinit
  ```
- As a single subdirectory pulled into an existing image (for `netshare/`, from inside
  someone else's own Dockerfile):
  ```dockerfile
  ADD https://github.com/qwreey/router-docker-client.git#main:netshare /netshare
  ```

Both use a **floating `#main` ref**, not a pinned commit/tag — deliberately, since pinning
would just move the "who has to remember to bump this" burden from a submodule pointer to a
URL string in every consumer, defeating the point. The real trade-off: every build needs
network access to GitHub (even a no-op rebuild re-resolves the ref — BuildKit does cache
the clone per machine/ref, so this mostly costs cold/CI/fresh-clone builds, not every single
local iteration), and a broken push here immediately affects every consumer's next build.
Given how small and low-risk this code is, that's judged an acceptable trade — but it's a
real one, not a free lunch.

Note BuildKit's git-context/`ADD` support does a **full clone** of this repo, not a sparse
checkout of just the requested subdirectory ([moby/buildkit#2116](https://github.com/moby/buildkit/pull/2116))
— this repo is kept small and free of anything unrelated (no docs bloat, no unrelated
tooling) specifically so that full clone stays cheap for every consumer, every build.

## netinit-docker wiring

`netinit-docker.sh` is a host-side agent, not a per-target sidecar, so it's deployed once per
Docker host (or once per `internal: true` network boundary) rather than once per workload.
Required compose wiring, all of it load-bearing:

```yaml
services:
  netinit-docker:
    network_mode: host
    cap_add: [NET_ADMIN, SYS_ADMIN]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/run/docker/netns:/var/run/docker/netns:ro,rslave
```

- `network_mode: host` + `NET_ADMIN`/`SYS_ADMIN` — needed to `nsenter --net=<sandbox>` into
  another container's netns at all (`SYS_ADMIN` for the namespace switch itself, `NET_ADMIN`
  for the route/nft changes once inside) and to run `nft` against the host's own
  `DOCKER-USER` chain for the forward-exemption job.
- The read-only `docker.sock` mount is how it discovers labelled networks/containers and
  reads each target's `SandboxKey`.
- The `/var/run/docker/netns` mount **must** carry `rslave` propagation, not the default
  `rprivate`. Each entry Docker creates under that directory (one per running container's
  netns) is itself a bind mount. With `rprivate` propagation, only netns handles that already
  existed *when the volume was created* are visible inside the agent's own mount namespace —
  any container started *after* the agent shows up as an empty 0-byte file at that path, and
  `nsenter --net=<that path>` fails with `setns(): can't reassociate to namespace 'net':
  Invalid argument`. `rslave` makes new bind-mount events on the host side propagate into the
  agent's mount namespace as they happen, so containers created after the agent starts are
  still reachable. Mount it at the identical path (`/var/run/docker/netns`, not some other
  in-container path) so the `SandboxKey` string the Docker API returns can be used verbatim
  without path-rewriting.

**`netinit.gateway` only accepts a container name, never an IP literal** — `netinit-docker.sh`
actively rejects anything shaped like an address (see `is_ip_literal` in the script). This
isn't an oversight: if a raw IP were accepted, one compose `labels:` line on any network could
point a workload's default route at an arbitrary address — including a LAN gateway — handing
the very workloads this design is meant to fence in a path onto the host's own network
(RFC1918/`192.168.*` and friends). Requiring a container name means the gateway must itself be
something this same `netinit.provider` already manages.

**Clients must still wait for their own default route in their own entrypoint** (a read-only
`ip route show default` poll — no capability required for that read). The agent can only ever
act *after* a container has already started (it discovers containers via the Docker API, it
doesn't hook container creation), so there is necessarily a window between "container is
running" and "container has an egress policy." Skipping the wait means a workload can make
outbound connections during that window under whatever default route it happened to start
with (typically none, but not guaranteed). See `netinit/netinit-entrypoint.sh` and
code-docker's own `script/entrypoint.sh` for the pattern.

**`netinit-docker` cannot manage a target's `/etc/resolv.conf`.** `nsenter --net=` only
switches the network namespace, not the mount namespace, so there is no way to write into the
target's filesystem from there. Reaching it would require `pid: host` plus `SYS_PTRACE` (to
enter the target's mount namespace via `/proc/<pid>/root` or `nsenter --mount=`), which this
design deliberately does not take on — it would meaningfully widen what a host-level compromise
of this agent could do to every container on the host, for a job (DNS) that the in-container
path already handles fine. DNS setup stays the target's own responsibility (e.g. `netshare`'s
`apply_nameserver`, run from inside the target's own entrypoint).

## Ground rules

- Keep this repo small. If something doesn't need to be fetched by every consumer of
  `netinit`/`netinit-docker`/`netshare`, it doesn't belong here — that's the whole reason
  this isn't just a subdirectory of router-docker itself.
- `netinit/Dockerfile` fetches `netshare/` from this same repo via `ADD` rather than a
  local `COPY`, since Compose builds it with a `netinit`-scoped git context (see the
  Dockerfile's own comment) — don't "simplify" that back to a local `COPY`, it won't
  resolve.
