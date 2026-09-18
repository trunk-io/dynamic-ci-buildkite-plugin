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

# As in run.sh: the first argument is a STABLE name, the second optional detail.
# Flaky Tests keys a test on its name, so variable text must not appear in one.
readonly OUT="${PWD}/smoke-out"
failures=0
JUNIT_CASES=""
CASE_STARTED="$(date +%s.%N)"

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

record() {
    local name="$1" outcome="$2" detail="$3" body="" now elapsed
    now="$(date +%s.%N)"
    elapsed="$(awk -v a="${CASE_STARTED}" -v b="${now}" 'BEGIN { printf "%.3f", b - a }')"
    CASE_STARTED="${now}"
    if [[ ${outcome} == fail ]]; then
        body="<failure message=\"$(xml_escape "${detail}")\"/>"
    fi
    JUNIT_CASES="${JUNIT_CASES}    <testcase classname=\"smoke.verdict\" name=\"$(xml_escape "${name}")\" time=\"${elapsed}\">${body}</testcase>
"
}

pass() {
    echo "  ✔ $1${2:+ — $2}"
    record "$1" pass ""
}

fail() {
    echo "  ✘ $1${2:+ — $2}" >&2
    failures=$((failures + 1))
    record "$1" fail "${2-}"
}

write_junit() {
    local total
    total="$(grep -c "<testcase" <<<"${JUNIT_CASES}")"
    mkdir -p "${OUT}"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuites>"
        echo "  <testsuite name=\"dynamic-ci-buildkite-plugin smoke verdict\" tests=\"${total}\" failures=\"${failures}\">"
        printf '%s' "${JUNIT_CASES}"
        echo "  </testsuite>"
        echo "</testsuites>"
    } >"${OUT}/junit-verdict.xml"
}
trap write_junit EXIT

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
            fail "${name} ran xor was marked skipped" "marked skipped, but it ran anyway"
        else
            pass "${name} ran xor was marked skipped" "not marked, and it ran"
        fi
    else
        if marked_skipped "${name}"; then
            pass "${name} ran xor was marked skipped" "marked skipped, and it did not run"
        else
            fail "${name} ran xor was marked skipped" "never ran, and was never marked skipped"
        fi
    fi
done

# Unconditional, and the point of having an unkeyed step at all: the plugin is
# never permitted to skip a step it was not given a key for. No plan can reach
# this one, so no plan is an excuse for it not running.
if ran unkeyed; then
    pass "the unkeyed step always runs"
else
    fail "the unkeyed step always runs" "it did not run — the plugin skipped a step with no key"
fi

if [[ ${failures} -ne 0 ]]; then
    echo "${failures} assertion(s) failed." >&2
    exit 1
fi
echo "what ran and what was marked agree"
