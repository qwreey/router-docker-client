# wait_until <description> <timeout-seconds> <interval-seconds> <test-command...>
#
# Generic poll-until-timeout helper, meant to be sourced (`.`, not exec'd)
# into a script that has its own `set -e`/trap conventions.
#
# Polls <test-command> every <interval>s until it exits 0, up to <timeout>s
# total. Returns 0 once it succeeds, 1 on timeout - never exits the calling
# script itself, so callers decide what a timeout means (fatal vs
# best-effort).
#
# <timeout> is real wall-clock time, and that is load-bearing: this used to
# count `_waited += interval` per iteration instead, which silently assumed
# the test command returns instantly. It doesn't always. `getent hosts <name>`
# against a resolv.conf whose fallback nameserver has gone away blocks for the
# full resolver timeout on every single attempt, so a nominal 60s wait became
# many minutes of a container that looked hung with one "waiting for..." line
# in its log and nothing after it (observed 2026-08-26 in code-docker's dind).
# Each attempt is additionally capped at the time left on the deadline (via
# `timeout`, when available), so one blocking call can't overshoot either.
# That cap means <test-command> must be a real command, not a shell function.
#
# Consumers fetch this directory directly via a Dockerfile `ADD
# https://github.com/qwreey/router-docker-client.git#main:netshare <dest>`
# (or the same URL as a Compose `build.context`) rather than vendoring a
# local copy - see this repo's own README.md.
wait_until() {
    _wu_desc="$1"; _wu_timeout="$2"; _wu_interval="$3"; shift 3
    _wu_deadline=$(( $(date +%s) + _wu_timeout ))
    echo "wait_until: waiting for $_wu_desc..."
    while ! _wu_attempt "$@"; do
        if [ "$(date +%s)" -ge "$_wu_deadline" ]; then
            echo >&2 "wait_until: timed out after ${_wu_timeout}s waiting for $_wu_desc"
            return 1
        fi
        sleep "$_wu_interval"
    done
    echo "wait_until: $_wu_desc ready"
    return 0
}

# Internal: run one attempt, bounded by whatever is left of the deadline.
# Falls back to an unbounded call where `timeout` isn't installed - the
# wall-clock check in the caller still terminates the loop then, just one
# blocking attempt later.
_wu_attempt() {
    _wu_left=$(( _wu_deadline - $(date +%s) ))
    [ "$_wu_left" -lt 1 ] && _wu_left=1
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_wu_left" "$@" >/dev/null 2>&1
    else
        "$@" >/dev/null 2>&1
    fi
}
