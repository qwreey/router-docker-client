# router-docker-client

The workload-side integration kit for
[router-docker](https://github.com/qwreey/router-docker) — anything a project needs to
actually sit behind a router-docker instance as its network boundary, as opposed to
router-docker itself (the boundary container). Split out of
[code-docker](https://github.com/qwreey/code-docker), router-docker's first real consumer,
since none of this is code-docker-specific even though the env var names still show that
origin.

## What's here

- `netinit/` — sidecar that keeps a target container's default route pointed at router
  (`network_mode: service:<target>`, `NET_ADMIN`).
- `netfilter-fix/` — host-level fix for a Docker Engine 29.x hardening change that blocks
  router's own FORWARD traffic to an `internal: true` network at the netfilter level
  (`network_mode: host`, `NET_ADMIN`, read-only `docker.sock` mount). No dependency on
  `netshare/` at all.
- `netshare/` — the shared POSIX `sh` functions both of the above (and code-docker's own
  bootstrap/dind sidecar) use: `wait_until`, `apply_default_route`, `apply_nameserver`.

## How consumers pull this in

**Not a git submodule.** Every consumer fetches directly at build time via Docker/Compose's
native remote-git support — no local checkout, no submodule bookkeeping, no bump-commit
needed anywhere when this repo changes:

- As a whole service's build context (for `netinit`/`netfilter-fix`, each with their own
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

## Ground rules

- Keep this repo small. If something doesn't need to be fetched by every consumer of
  `netinit`/`netfilter-fix`/`netshare`, it doesn't belong here — that's the whole reason
  this isn't just a subdirectory of router-docker itself.
- `netinit/Dockerfile` fetches `netshare/` from this same repo via `ADD` rather than a
  local `COPY`, since Compose builds it with a `netinit`-scoped git context (see the
  Dockerfile's own comment) — don't "simplify" that back to a local `COPY`, it won't
  resolve.
