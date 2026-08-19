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
# Consumers fetch this directory directly via a Dockerfile `ADD
# https://github.com/qwreey/router-docker-client.git#main:netshare <dest>`
# (or the same URL as a Compose `build.context`) rather than vendoring a
# local copy - see this repo's own README.md.
wait_until() {
    _wu_desc="$1"; _wu_timeout="$2"; _wu_interval="$3"; shift 3
    _wu_waited=0
    echo "wait_until: waiting for $_wu_desc..."
    while ! "$@" >/dev/null 2>&1; do
        _wu_waited=$((_wu_waited + _wu_interval))
        if [ "$_wu_waited" -ge "$_wu_timeout" ]; then
            echo >&2 "wait_until: timed out after ${_wu_timeout}s waiting for $_wu_desc"
            return 1
        fi
        sleep "$_wu_interval"
    done
    echo "wait_until: $_wu_desc ready"
    return 0
}
