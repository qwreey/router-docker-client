# netinit - a tiny sidecar for any container that wants to sit behind a router-docker
# instance without owning the network capability itself: shares the target container's
# network namespace at runtime (Compose's `network_mode: service:<target>`) and
# repeatedly points its default route at router, using the NET_ADMIN this sidecar has but
# the target container itself never needs to get. See this repo's own README.md, and
# code-docker's CLAUDE.md ("router" section) for a worked example of wiring this in.
FROM alpine:latest
RUN apk add --no-cache iproute2
ADD https://github.com/qwreey/router-docker-client.git#main:netshare /netshare
COPY netinit-entrypoint.sh /netinit-entrypoint.sh
ENTRYPOINT ["/netinit-entrypoint.sh"]
