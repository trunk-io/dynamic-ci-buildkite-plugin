#!/usr/bin/env bash
# Did what ran agree with what the filter said should run?
#
# This is the assertion that survives the recommendation service gaining history.
# For every keyed step it tests an EXCLUSIVE OR:
#
#     the step recorded that it ran   XOR   the filter marked it skipped
#
# Both real bugs are caught — a step marked skipped that ran anyway, and a step
# that ran nothing and was never marked — while staying completely agnostic about
# WHETHER anything was skipped. Today nothing is, because a new pipeline has no
# history. The day that changes, this file does not.
set -uo pipefail

readonly KEYED_STEPS=(alpha beta gamma)

failures=0
pass() { echo "  ✔ $1"; }
fail() {
    echo "  ✘ $1" >&2
    failures=$((failures + 1))
}

echo "--- :inbox_tray: fetching the filtered pipeline"
buildkite-agent artifact download "smoke-out/after.json" . || {
    echo "could not download the filtered pipeline; nothing can be checked." >&2
    exit 1
}

# The plugin checkout is not on this step (no plugins: block here), so use a jq
# from the repository checkout. Same bytes — both are this commit.
readonly JQ="./vendor/jq-linux-amd64"

ran() {
    [[ "$(buildkite-agent meta-data get "smoke-ran-$1" --default missing)" == "ok" ]]
}

marked_skipped() {
    # shellcheck disable=SC2016  # $key is a jq --arg binding
    "${JQ}" -e --arg key "smoke-sample-$1" '
        [ .. | objects | select(.key? == $key) ]
        | any(.skip? | type == "string")
    ' smoke-out/after.json >/dev/null 2>&1
}

echo "--- :mag: what ran vs what was marked"
for name in "${KEYED_STEPS[@]}"; do
    if ran "${name}"; then
        if marked_skipped "${name}"; then
            fail "${name}: marked skipped, but it ran anyway"
        else
            pass "${name}: not marked, and it ran"
        fi
    else
        if marked_skipped "${name}"; then
            pass "${name}: marked skipped, and it did not run"
        else
            fail "${name}: never ran, and was never marked skipped"
        fi
    fi
done

# Unconditional, and the point of having an unkeyed step at all: the plugin is
# never permitted to skip a step it was not given a key for. No plan can reach
# this one, so no plan is an excuse for it not running.
if ran unkeyed; then
    pass "the unkeyed step ran, as it must"
else
    fail "the unkeyed step did not run — the plugin skipped a step with no key"
fi

if [[ ${failures} -ne 0 ]]; then
    echo "${failures} assertion(s) failed." >&2
    exit 1
fi
echo "what ran and what was marked agree"
