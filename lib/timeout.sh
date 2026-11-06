#!/usr/bin/env bash
# `with_timeout <seconds> <command...>`: runs the command, killing it with TERM
# once <seconds> have passed. The exit status is the command's, or 124 when it
# was killed.
#
# `timeout` is GNU coreutils and is not on a stock macOS agent, so `gtimeout`
# (Homebrew coreutils) is tried next, and a watchdog after that.

with_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}" "$@"
        return
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}" "$@"
        return
    fi
    local fired status
    fired="$(mktemp)" || return 1
    # Explicitly: a background command's stdin is otherwise /dev/null.
    "$@" <&0 &
    local pid=$!
    # The watchdog's output goes nowhere: it would otherwise hold the caller's
    # pipe or `$(...)` open, and the reader would wait out its whole sleep.
    (sleep "${secs}" && echo fired >"${fired}" && kill -TERM "${pid}") \
        >/dev/null 2>&1 &
    local watchdog=$!
    wait "${pid}"
    status=$?
    kill "${watchdog}" >/dev/null 2>&1
    wait "${watchdog}" 2>/dev/null
    if [[ -s ${fired} ]]; then
        status=124
    fi
    rm -f "${fired}"
    return "${status}"
}
