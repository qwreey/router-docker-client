#!/bin/sh
# netinit-docker - host-side, label-driven network agent for containers sitting behind a
# router-docker instance. Two jobs, both reconciled from the Docker API on every cycle:
#
#   1. default routes - point each opted-in container's default route at the gateway
#      container its network declares. Replaces the per-target `netinit` sidecar
#      (`network_mode: service:<target>`) for Docker deployments, WITHOUT giving the
#      target container any capability of its own: this process enters the target's
#      network namespace from the host side (nsenter into the SandboxKey Docker already
#      publishes under /var/run/docker/netns) using its own CAP_SYS_ADMIN/CAP_NET_ADMIN.
#      The target keeps zero capabilities, so it still cannot rewrite its own egress
#      policy - that separation is the entire point of this design.
#
#      Why this exists at all, rather than just keeping the sidecar: `network_mode:
#      service:<target>` pins the sidecar to the target's *container ID* at create time.
#      A target *recreate* (new ID) leaves the sidecar permanently unable to start
#      ("joining network namespace of container: No such container: <old-id>") while
#      `restart: unless-stopped` retries a dead ID forever - and the failure is silent,
#      since the target itself stays Up with no default route. This agent holds no such
#      reference: it re-resolves every container's SandboxKey each cycle (which Docker
#      changes on every restart anyway), so that whole class of breakage is gone.
#
#      `netinit/` is NOT replaced by this and stays in the repo - it is the portable,
#      engine-agnostic variant (k8s sidecar etc.). This one is Docker-only by
#      construction. See that directory's own CLAUDE.md for its limitations.
#
#   2. DOCKER-USER forward exemptions - what this script did when it was called
#      `netfilter-fix`. Docker Engine 29.x's DOCKER-INTERNAL hardening blocks router's own
#      FORWARD traffic into `internal: true` networks at the host netfilter level, which
#      NET_ADMIN inside router's own netns cannot reach. Networks opt in via a label now
#      instead of the old env list (see "Configuration" below).
#
# Configuration is by LABEL, not by env list, so a sibling project's own compose overlay
# describes its own requirements instead of the consuming project having to maintain a
# list of them:
#
#   networks:
#     code-docker-internal:
#       labels:
#         netinit.provider:       "myprefix-netinit-docker"   # which agent owns this
#         netinit.gateway:        "myprefix-code-docker-router"
#         netinit.exempt-forward: "true"
#   services:
#     some-workload:
#       labels:
#         netinit.provider:       "myprefix-netinit-docker"   # opt in, that's all
#
# A container's default route goes out whichever of its provider-labelled networks
# declares `netinit.gateway`; a network without that label is never routed through (so a
# VNC-only or otherwise isolated network can carry `exempt-forward` without becoming an
# egress path). If two of a container's networks both declare a gateway the situation is
# ambiguous and this script does NOTHING for that container except log loudly - it will
# not guess which boundary was intended.
#
# `netinit.gateway` takes a CONTAINER NAME only; a bare IP literal is rejected. This is
# deliberate and is not an oversight: accepting arbitrary gateway addresses would turn
# this into a general-purpose routing tool, and one compose line could then point a
# workload at a LAN gateway - handing the very agents this is meant to fence in a path to
# 192.168.*/RFC1918. The gateway must be a container the same provider manages.
#
# Clients are still expected to WAIT for their default route before starting any
# workload (a read-only `ip route show default` poll in their own entrypoint - no
# capability needed). This agent necessarily acts *after* a container has started, so
# without that wait there is a window in which a workload runs with no egress policy in
# place. See router-docker's docs and code-docker's script/entrypoint.sh for the pattern.

set -eu

PROVIDER_ID="${NETINIT_DOCKER_PROVIDER_ID:-netinit-docker}"
INTERVAL="${NETINIT_DOCKER_INTERVAL:-2}"
# Behavioural opt-out for the ROUTE half only. A deployment that has turned its egress
# boundary off wants no default routes planted (there is nothing to point them at), but it
# still wants the DOCKER-USER exemption half, which never depended on the boundary being
# enabled - so this gates route planting alone rather than idling the whole process. The
# sidecar this replaced honoured the consuming project's own NETGATE_ENABLED; the name is
# namespaced to this tool instead, and the consumer maps its own variable onto it (see
# code-docker's docker-compose.yml).
ROUTES_ENABLED="${NETINIT_DOCKER_ENABLED:-true}"
DOCKER_SOCK=/var/run/docker.sock
RUNDIR=/run/netinit-docker
# The nft comment this instance stamps on the rules it owns. Scoped by provider id, NOT a
# constant: PREFIX multi-instance deployments put two of these agents on one host sharing
# a single DOCKER-USER chain, and with a constant tag each one's shutdown cleanup
# (remove_all_own_rules) and stale-rule sweep would delete the OTHER instance's
# exemptions - verified the hard way on 2026-08-25, where a second instance exiting wiped
# the running one's rules until its next reconcile put them back.
#
# Rules carrying the bare pre-2026-08-25 tag (no ":<provider>" suffix) are deliberately
# left alone: they belong to an old netfilter-fix container, which removes them itself on
# SIGTERM. Only a hard kill of that old container would strand one.
COMMENT_TAG="netfilter_fix_internal_forward_fix:${PROVIDER_ID}"

LABEL_PROVIDER="netinit.provider"
LABEL_GATEWAY="netinit.gateway"
LABEL_EXEMPT="netinit.exempt-forward"

# State carried between cycles purely so steady-state operation is silent - every message
# this script prints should mean something actually changed.
last_routes=""
last_warn=""

log()  { echo "netinit-docker: $*"; }
warn() { echo >&2 "netinit-docker: $*"; }

# Deduplicated warning - the reconcile loop runs every couple of seconds and a
# misconfiguration is usually persistent; without this a single bad label would produce
# thousands of identical lines and bury everything else.
warn_once() {
	case "$last_warn" in
		*"|$1|"*) return 0 ;;
	esac
	last_warn="${last_warn}|$1|"
	warn "$2"
}

docker_api() {
	curl -sf --unix-socket "$DOCKER_SOCK" "http://localhost$1" 2>/dev/null
}

# curl -G so the filters JSON gets URL-encoded properly rather than hand-escaped.
docker_api_filtered() {
	curl -sf --unix-socket "$DOCKER_SOCK" -G \
		--data-urlencode "filters=$2" \
		"http://localhost$1" 2>/dev/null
}

is_ip_literal() {
	# IPv4 dotted-quad or anything with a colon (IPv6) - good enough to reject the
	# "just put an address here" shape without pulling in a real parser.
	case "$1" in
		*:*) return 0 ;;
		*[!0-9.]*) return 1 ;;
		*.*.*.*) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# DOCKER-USER forward exemptions (the original netfilter-fix job)
# ---------------------------------------------------------------------------

list_own_rules() {
	nft -a list chain ip filter DOCKER-USER 2>/dev/null | grep -F "comment \"${COMMENT_TAG}\"" || true
}

ensure_rule() {
	bridge="$1"
	list_own_rules | grep -q "iifname \"${bridge}\"" && return 0
	nft insert rule ip filter DOCKER-USER iifname "$bridge" accept comment "\"${COMMENT_TAG}\""
	log "installed DOCKER-USER exemption for ${bridge}"
}

delete_by_handle() {
	handle="$1"
	[ -n "$handle" ] && nft delete rule ip filter DOCKER-USER handle "$handle" 2>/dev/null || true
}

is_live_bridge() {
	needle="$1"
	for b in $live_bridges; do
		[ "$b" = "$needle" ] && return 0
	done
	return 1
}

cleanup_stale_rules() {
	live_bridges="$1"
	list_own_rules | while IFS= read -r line; do
		iface="$(printf '%s\n' "$line" | sed -n 's/.*iifname "\([^"]*\)".*/\1/p')"
		handle="$(printf '%s\n' "$line" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')"
		is_live_bridge "$iface" && continue
		delete_by_handle "$handle"
	done
}

remove_all_own_rules() {
	list_own_rules | while IFS= read -r line; do
		handle="$(printf '%s\n' "$line" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')"
		delete_by_handle "$handle"
	done
}

# ---------------------------------------------------------------------------
# Route reconciliation
# ---------------------------------------------------------------------------

# Find the interface inside a netns that carries a given address. Docker does NOT
# guarantee "network X is always eth0" - a multi-network container's interface order is
# not stable across recreates - so the interface is identified by the address Docker
# reports for that network, never by name.
iface_for_addr() {
	sandbox="$1"; addr="$2"
	nsenter --net="$sandbox" ip -o -4 addr show 2>/dev/null \
		| awk -v a="$addr" '$4 ~ "^"a"/" { print $2; exit }'
}

current_default_via() {
	sandbox="$1"
	nsenter --net="$sandbox" ip -o -4 route show default 2>/dev/null \
		| awk '{ for (i=1;i<=NF;i++) if ($i == "via") { print $(i+1); exit } }'
}

apply_route() {
	cid="$1"; cname="$2"; sandbox="$3"; target_ip="$4"; gw_ip="$5"

	if [ ! -e "$sandbox" ]; then
		warn_once "sandbox-$cid" "container '${cname}' has no netns handle at ${sandbox} yet - is /var/run/docker/netns mounted with rslave? (a bind mount without slave propagation shows the handle as an empty file and setns fails)"
		return 0
	fi

	iface="$(iface_for_addr "$sandbox" "$target_ip")"
	if [ -z "$iface" ]; then
		warn_once "iface-$cid-$target_ip" "container '${cname}': no interface carrying ${target_ip} inside its netns - skipping"
		return 0
	fi

	if [ "$(current_default_via "$sandbox")" = "$gw_ip" ]; then
		return 0
	fi

	if nsenter --net="$sandbox" ip route replace default via "$gw_ip" dev "$iface" 2>/dev/null; then
		log "container '${cname}': default route -> ${gw_ip} dev ${iface}"
	else
		warn_once "route-$cid-$gw_ip" "container '${cname}': failed to set default route via ${gw_ip} dev ${iface}"
	fi
}

# ---------------------------------------------------------------------------
# One reconcile pass
# ---------------------------------------------------------------------------

reconcile() {
	provider_filter="{\"label\":[\"${LABEL_PROVIDER}=${PROVIDER_ID}\"]}"

	networks_json="$(docker_api_filtered /networks "$provider_filter" || true)"
	if [ -z "$networks_json" ] || [ "$networks_json" = "null" ]; then
		warn_once "api" "cannot reach the Docker API at ${DOCKER_SOCK} - nothing to do this cycle"
		return 0
	fi

	# --- gateway map: "<network name>\t<gateway container name>" -------------
	gw_decls="$(printf '%s' "$networks_json" | jq -r --arg gw "$LABEL_GATEWAY" '
		.[] | select(.Labels[$gw] // "" | length > 0) | "\(.Name)\t\(.Labels[$gw])"')"

	# Resolve each declared gateway container to its address ON THAT NETWORK. A
	# gateway is only ever a container name; see this file's header for why an IP
	# literal is refused rather than accepted as a convenience.
	gw_map=""
	printf '%s\n' "$gw_decls" > "$RUNDIR/gw_decls"
	while IFS="$(printf '\t')" read -r net gwname; do
		[ -n "${net:-}" ] || continue
		if is_ip_literal "$gwname"; then
			warn_once "gwip-$net" "network '${net}': ${LABEL_GATEWAY}='${gwname}' looks like a raw IP - only a container name managed by this provider is accepted, ignoring this network"
			continue
		fi
		gw_ip="$(docker_api "/networks/${net}" \
			| jq -r --arg n "$gwname" '.Containers // {} | to_entries[] | select(.value.Name == $n) | .value.IPv4Address' \
			| head -1 | cut -d/ -f1)"
		if [ -z "$gw_ip" ] || [ "$gw_ip" = "null" ]; then
			warn_once "gwmiss-$net-$gwname" "network '${net}': gateway container '${gwname}' is not attached to it (yet) - no route will be set through this network"
			continue
		fi
		printf '%s\t%s\n' "$net" "$gw_ip"
	done < "$RUNDIR/gw_decls" > "$RUNDIR/gw_map"
	gw_map="$(cat "$RUNDIR/gw_map" 2>/dev/null || true)"

	# --- DOCKER-USER exemptions --------------------------------------------
	exempt_nets="$(printf '%s' "$networks_json" | jq -r --arg ex "$LABEL_EXEMPT" '
		.[] | select(.Labels[$ex] == "true") | .Id')"

	# Deprecated env path, kept for one release cycle. Consumers pull this repo through
	# Docker's remote-git build context on a floating ref, and Docker CACHES that fetch -
	# a rename here has silently failed to reach a consumer before (CODE_DOCKER_* ->
	# NETFILTER_FIX_*), with the old default quietly masking it. So the env list keeps
	# working, and taking that path is announced rather than assumed.
	legacy_nets="${NETFILTER_FIX_INTERNAL_NETWORK:-} ${NETFILTER_FIX_EXTRA_INTERNAL_NETWORKS:-}"
	for net in $legacy_nets; do
		[ -n "$net" ] || continue
		warn_once "legacy-$net" "network '${net}' came from the deprecated NETFILTER_FIX_* env vars - move it to a '${LABEL_EXEMPT}: \"true\"' label on the network itself (and rebuild with --no-cache; Docker caches this repo's remote-git context)"
		net_id="$(docker_api "/networks/${net}" | jq -r '.Id // empty')"
		[ -n "$net_id" ] && exempt_nets="$exempt_nets
$net_id"
	done

	live_bridges=""
	for net_id in $exempt_nets; do
		[ -n "$net_id" ] || continue
		bridge="$(printf 'br-%.12s' "$net_id")"
		if ip link show "$bridge" >/dev/null 2>&1; then
			ensure_rule "$bridge"
			live_bridges="$live_bridges $bridge"
		fi
	done
	[ -n "$live_bridges" ] && cleanup_stale_rules "$live_bridges"

	# --- routes -------------------------------------------------------------
	if [ "$ROUTES_ENABLED" = "false" ]; then
		warn_once "routes-disabled" "NETINIT_DOCKER_ENABLED=false - not planting any default routes (DOCKER-USER exemptions above are still maintained)"
		return 0
	fi
	[ -n "$gw_map" ] || return 0

	targets="$(docker_api_filtered /containers/json "$provider_filter" || true)"
	[ -n "$targets" ] && [ "$targets" != "null" ] || return 0

	rm -f "$RUNDIR/seen_routes"
	printf '%s' "$targets" | jq -r '.[] | .Id as $id | (.Names[0] // $id | ltrimstr("/")) as $name
		| .NetworkSettings.Networks // {} | to_entries[]
		| "\($id)\t\($name)\t\(.key)\t\(.value.IPAddress)"' | while IFS="$(printf '\t')" read -r cid cname net addr; do
		[ -n "${addr:-}" ] || continue
		gw_ip="$(printf '%s\n' "$gw_map" | awk -F"\t" -v n="$net" '$1 == n { print $2; exit }')"
		[ -n "$gw_ip" ] || continue
		printf '%s\t%s\t%s\t%s\n' "$cid" "$cname" "$addr" "$gw_ip"
	done > "$RUNDIR/route_plan"

	# A container attached to two gateway-declaring networks is ambiguous: refuse to
	# pick one. Doing nothing is the safe failure here - a wrong default route is a
	# silently wrong security boundary, whereas no route is loud (the client's own
	# entrypoint wait blocks and says so).
	dupes="$(cut -f1 "$RUNDIR/route_plan" 2>/dev/null | sort | uniq -d || true)"

	while IFS="$(printf '\t')" read -r cid cname addr gw_ip; do
		[ -n "${cid:-}" ] || continue
		if printf '%s\n' "$dupes" | grep -qx "$cid"; then
			warn_once "ambig-$cid" "container '${cname}' is attached to more than one network declaring ${LABEL_GATEWAY} - refusing to guess which is the intended boundary, leaving its routes alone"
			continue
		fi
		sandbox="$(docker_api "/containers/${cid}/json" | jq -r '.NetworkSettings.SandboxKey // empty')"
		[ -n "$sandbox" ] || continue
		apply_route "$cid" "$cname" "$sandbox" "$addr" "$gw_ip"
		printf '%s\n' "$cname" >> "$RUNDIR/seen_routes"
	done < "$RUNDIR/route_plan"

	# Sorted, because the Docker API does not promise a stable order across calls and an
	# unsorted comparison would reprint the "managing" line every time two containers
	# happened to swap places - this line is supposed to mean the managed set actually
	# changed.
	seen_routes="$(sort -u "$RUNDIR/seen_routes" 2>/dev/null | tr '\n' ' ')"
	rm -f "$RUNDIR/seen_routes"

	if [ "$seen_routes" != "$last_routes" ]; then
		log "managing default routes for: ${seen_routes:-<none>}"
		last_routes="$seen_routes"
	fi
}

mkdir -p "$RUNDIR"

trap 'log "shutting down, removing DOCKER-USER exemption(s)"; remove_all_own_rules; exit 0' TERM INT

log "starting - provider id '${PROVIDER_ID}', reconcile every ${INTERVAL}s"
while true; do
	reconcile || warn "reconcile pass failed, retrying"
	sleep "$INTERVAL" &
	wait $!
done
