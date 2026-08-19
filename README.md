# router-docker-client

Workload-side integration kit for [router-docker](https://github.com/qwreey/router-docker)
— the small pieces a container needs to actually sit behind a router-docker instance as its
network boundary. See `CLAUDE.md` for the full design and exact usage snippets.

- `netinit/` — sidecar that keeps a target container's default route pointed at router.
- `netfilter-fix/` — host-level netfilter fix so router's egress design isn't blocked by
  Docker Engine's own `DOCKER-INTERNAL` hardening.
- `netshare/` — shared shell functions the above (and any similar entrypoint script) use.

Consumed via Docker/Compose's native remote-git support (`build.context`/`ADD` with a git
URL), not a submodule — see [code-docker](https://github.com/qwreey/code-docker)'s own
`docker-compose.yml` for a working example.
