#!/bin/sh
set -u

# apply_default_route is shared with any other consumer of this repo's
# netshare/ (e.g. code-dind-style entrypoints) - see wait-until.sh's own
# header comment in netshare/ for how it's fetched.
. /netshare/apply-route.sh

trap 'exit 0' TERM INT

if [ "${NETGATE_ENABLED:-true}" = "false" ]; then
	echo "netinit: NETGATE_ENABLED=false, idling without touching routes"
	while true; do sleep 3600; done
fi

router_hostname="${ROUTER_HOSTNAME:-router}"

while true; do
	# This container only shares its target's netns (network_mode:
	# service:<target>) - if the target restarts (not just a process
	# inside it), Docker tears down and recreates its network sandbox,
	# orphaning this container in the old, now-interfaceless namespace
	# (moby/moby#50326 - confirmed to happen in practice). Only `lo`
	# surviving means exactly that - no amount of retrying `ip route
	# replace` fixes it from inside a dead netns, so exit non-zero and let
	# `restart: unless-stopped` recreate this container instead, which
	# rejoins whatever netns the target currently owns.
	if ! ip -o link show 2>/dev/null | grep -qv '^[0-9]*: lo:'; then
		echo >&2 "netinit: only loopback visible - the target's netns was likely recreated out from under us, exiting so restart: unless-stopped rejoins it"
		exit 1
	fi

	# router not resolving (not deployed yet, or NETGATE_ENABLED false on
	# router's own side) must never be treated as fatal here - a crash
	# would tear down the target's own netns setup for no benefit, since
	# this container only patches its routing table, it doesn't own the
	# netns.
	apply_default_route "$router_hostname"

	sleep 5
done
