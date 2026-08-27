# router-docker-client

Workload-side integration kit for [router-docker](https://github.com/qwreey/router-docker)
— the small pieces a container needs to actually sit behind a router-docker instance as its
network boundary. See `CLAUDE.md` for the full design and exact usage snippets.

- `netinit/` — sidecar that keeps a target container's default route pointed at router
  (portable, engine-agnostic; the right choice outside Docker, e.g. a Kubernetes sidecar).
- `netinit-docker/` — host-side, label-driven agent, Docker-only by construction. Does the
  same default-route job as `netinit/` but by `nsenter`-ing into a container's network
  namespace from the host, so the target itself needs zero capabilities; also still installs
  the `DOCKER-USER` forward exemptions that used to live in `netfilter-fix/` (that directory
  was renamed into this one, since both jobs are reconciled from the same Docker API loop).
- `dns-local/` — a local, strict-order DNS forwarder for a container on an `internal: true`
  network. Docker's embedded DNS resolves same-network names there but answers everything
  else with an immediate, definitive SERVFAIL, and listing it alongside router as two
  `nameserver` lines only works for resolvers that retry past that (glibc does, `dig` and
  Node don't). This makes the failover happen once, correctly, inside dnsmasq.
- `netshare/` — shared shell functions the above (and any similar entrypoint script) use.

Consumed via Docker/Compose's native remote-git support (`build.context`/`ADD` with a git
URL), not a submodule — see [code-docker](https://github.com/qwreey/code-docker)'s own
`docker-compose.yml` for a working example.
