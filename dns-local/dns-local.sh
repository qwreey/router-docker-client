#!/bin/sh
set -u

# dns-local: a local, strict-order DNS forwarder for a container sitting on
# an `internal: true` Docker network behind router.
#
# ## The bug this exists for
#
# Docker's own embedded DNS (127.0.0.11) still resolves same-network names
# (compose service names, network aliases like `router`/`vnc-only`) on an
# `internal: true` network - but for anything it doesn't own it answers with
# an immediate (0ms), *definitive* SERVFAIL rather than a timeout, because
# it has no route to forward the query. So a container there needs both
# nameservers: 127.0.0.11 for local names and router for everything else.
#
# Listing them as two `nameserver` lines in /etc/resolv.conf does not work.
# That only helps clients whose resolver retries the next nameserver after a
# definitive SERVFAIL - glibc's own NSS stack does (`getent`), but `dig` and
# Node's runtime don't, and report the first server's SERVFAIL straight back
# to the caller. Reordering doesn't help either: router's dnsmasq doesn't
# know the local names, so a dig-class client would then fail on *those*
# instead, for the same reason in the other direction (NXDOMAIN).
#
# And with only 127.0.0.11 listed - which is what a container that does
# nothing at all gets - there is no external DNS whatsoever, for any client
# class. Measured on a live deployment (2026-08-27): 0/15 successful
# lookups of an external name from such a container, while the same query
# from a container running this script was 15/15.
#
# ## The fix
#
# Run dnsmasq in `--strict-order` mode as the *only* nameserver the
# container ever talks to. strict-order makes dnsmasq itself retry the next
# `--server=` entry on SERVFAIL (confirmed empirically against this exact
# 127.0.0.11-then-router setup), so the failover happens once, correctly,
# inside dnsmasq - every client downstream sees one nameserver and gets
# either a real answer or a real failure.
#
# Without `--strict-order` this is actively *worse* than doing nothing:
# dnsmasq's default "fastest responder wins" selection always picks
# 127.0.0.11 (no network hop) even when its answer is a bogus SERVFAIL.
# Also measured: 10/10 SERVFAIL without the flag, 10/10 success with it, on
# the same setup.
#
# ## History
#
# Written for code-docker (`config/dns-local/dns-local.default.sh`,
# 2026-08-10) and moved here 2026-08-27 once roblox-studio-docker turned
# out to have the same problem in a worse form (no fallback nameserver at
# all, so Roblox Studio couldn't resolve anything and failed at launch with
# "Temporary failure in name resolution"). It is not code-docker-specific -
# any container behind router that isn't `privileged` enough to manage its
# own routing needs exactly this - so it lives with the rest of the
# workload-side kit. code-docker-dind is the remaining known consumer
# (see that project's `.claude/backlog/dind-dns-servfail.md`); it isn't
# wired up yet because dockerd snapshots /etc/resolv.conf at its own
# startup, so ordering there needs its own pass.
#
# ## Configuration (all optional)
#
#   DNS_LOCAL_ENABLED    "false" idles without touching anything. Consumers
#                        that also run standalone (no router) should default
#                        this to false in their own wrapper.
#   ROUTER_HOSTNAME      the name router answers to on this network
#                        (default "router"). Re-resolved every 5s; dnsmasq
#                        is restarted if router's IP moved, since router's
#                        own IP isn't stable across recreates.
#   DNS_LOCAL_RUN_DIR    where to keep the pid file (default /run/dns-local).
#   NETSHARE_DIR         where this repo's netshare/ was installed. Only
#                        used for a nicer bounded startup wait; the retry
#                        loop below works without it.
#
# Meant to be run as a long-lived supervised program (supervisord, s6, ...),
# not forked and forgotten: it stays in the foreground for the upkeep loop.

if [ "${DNS_LOCAL_ENABLED:-true}" = "false" ]; then
    echo "dns-local: DNS_LOCAL_ENABLED=false, idling without starting a local resolver"
    while true; do sleep 3600; done
fi

ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-router}"
RUN_DIR="${DNS_LOCAL_RUN_DIR:-/run/dns-local}"
mkdir -p "$RUN_DIR"

# netshare's wait_until, if the consumer installed it. Checked in two
# places - an explicit NETSHARE_DIR, then a sibling directory (which is what
# a whole-repo copy looks like) - and simply skipped when absent, since the
# `until start_dnsmasq` loop below is what actually guarantees startup. The
# wait only exists to turn "silently retrying" into one clear log line.
_ns="${NETSHARE_DIR:-}"
[ -n "$_ns" ] || _ns="$(dirname "$0")/../netshare"
# shellcheck disable=SC1091
[ -r "$_ns/wait-until.sh" ] && . "$_ns/wait-until.sh"

DNSMASQ_PID=""
LAST_ROUTER_IP=""

# Restarting dnsmasq (rather than SIGHUP-reloading a --servers-file) on a
# router IP change is deliberately simple: this only happens when router
# itself gets recreated, a rare event, and a ~1s DNS blip during the swap
# is an acceptable trade for not depending on --servers-file's SIGHUP
# reload semantics, which weren't verified as part of this.
start_dnsmasq() {
    router_ip="$(getent hosts "$ROUTER_HOSTNAME" 2>/dev/null | awk '{ print $1; exit }')"
    [ -z "$router_ip" ] && return 1
    dnsmasq --no-daemon --no-resolv --strict-order \
        --listen-address=127.0.0.1 --bind-interfaces \
        --server=127.0.0.11 --server="$router_ip" \
        --pid-file="$RUN_DIR/dns-local.pid" &
    DNSMASQ_PID=$!
    LAST_ROUTER_IP="$router_ip"
}

trap 'kill "$DNSMASQ_PID" 2>/dev/null; exit 0' TERM INT

if command -v wait_until >/dev/null 2>&1; then
    wait_until "router's DNS forwarder" 60 2 getent hosts "$ROUTER_HOSTNAME" \
        || echo >&2 "dns-local: could not resolve '$ROUTER_HOSTNAME' after 60s - starting anyway, will keep retrying"
fi

until start_dnsmasq; do
    sleep 2
done

# A bind failure (port 53 already taken, etc) makes dnsmasq exit almost
# immediately - a short pause then checking it's still alive is a good
# enough proxy for "started cleanly" without needing a real query round-trip.
sleep 1
if kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    # Direct redirect (truncate-in-place), not tmp-file+mv - /etc/resolv.conf
    # is a bind-mounted file, and `mv` onto a bind-mount target fails with
    # "Resource busy" (same reason netshare/apply-nameserver.sh avoids it).
    printf 'nameserver 127.0.0.1\noptions ndots:0\n' > /etc/resolv.conf
    echo "dns-local: /etc/resolv.conf now points at the local resolver (router=$LAST_ROUTER_IP)"
else
    echo >&2 "dns-local: dnsmasq failed to start, leaving /etc/resolv.conf untouched"
fi

while true; do
    sleep 5
    router_ip="$(getent hosts "$ROUTER_HOSTNAME" 2>/dev/null | awk '{ print $1; exit }')"
    if [ -n "$router_ip" ] && [ "$router_ip" != "$LAST_ROUTER_IP" ]; then
        echo "dns-local: router IP changed ($LAST_ROUTER_IP -> $router_ip), restarting local resolver"
        kill "$DNSMASQ_PID" 2>/dev/null
        wait "$DNSMASQ_PID" 2>/dev/null
        start_dnsmasq
    fi
done
