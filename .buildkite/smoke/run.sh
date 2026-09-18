#!/usr/bin/env bash
# The smoke test: the plugin, running as a plugin, on a real agent, at the commit
# under test.
#
# Assertions are tiered by what they depend on, because that determines what a
# failure MEANS:
#
#   Tier 0  the plugin the agent resolved really is this commit's code
#   Tier 1  invariants that hold whatever the recommendation service says
#   Tier 2  the staging deployment answered at all
#   Tier 3  what the service decided — NEVER asserted, see below
#
# Tier 3 is the important omission. A pipeline with no history gets
# WORKFLOW_NOT_RECOGNIZED and nothing is skipped, which is correct. Asserting on
# the verdict would make this repository's CI fail whenever the SERVICE changed —
# exactly the coupling that giving the plugin its own repository was meant to end.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

readonly OUT="${PWD}/smoke-out"
readonly SAMPLE=".buildkite/smoke/sample.yml"
mkdir -p "${OUT}"

failures=0
pass() { echo "  ✔ $1"; }
fail() {
    echo "  ✘ $1" >&2
    failures=$((failures + 1))
}

# A fail-open is invisible in stdout: with no history the service skips nothing,
# so a successful round trip and a total outage produce the SAME pipeline. These
# are the only strings that tell the two apart. Every one is a `log` line in
# lib/filter-impl.sh.
readonly FAIL_OPEN_MARKERS=(
    "Dynamic CI is unavailable"
    "Dynamic CI has no usable jq"
    "Dynamic CI could not read the pipeline"
    "Dynamic CI returned a plan this version cannot read"
    "Dynamic CI could not apply its plan"
    "Dynamic CI found no step with a key"
    "Dynamic CI has no step left to consider"
)

saw_fail_open() {
    local file="$1" marker
    for marker in "${FAIL_OPEN_MARKERS[@]}"; do
        if grep -qF "${marker}" "${file}"; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Tier 0 — the plugin the agent resolved is this commit's code
# ---------------------------------------------------------------------------
echo "--- :mag: tier 0 — the plugin under test is this commit"

filter="$(command -v trunk-dynamic-ci-filter || true)"
if [[ -z ${filter} ]]; then
    echo "trunk-dynamic-ci-filter is not on PATH: the environment hook did not run." >&2
    echo "Nothing below can mean anything, so stopping here." >&2
    exit 1
fi
pass "the environment hook put trunk-dynamic-ci-filter on PATH"

plugin_dir="$(cd "$(dirname "${filter}")/.." && pwd)"
echo "  plugin checkout: ${plugin_dir}"

# Comparing bytes rather than parsing Buildkite's plugin-directory naming: this
# says "the agent is running this pull request's code" without depending on any
# convention we do not control.
for file in lib/filter-impl.sh lib/request-plan.sh vendor/SHA256SUMS plugin.yml; do
    if cmp -s "${plugin_dir}/${file}" "./${file}"; then
        pass "${file} matches the checkout byte for byte"
    else
        fail "${file} DIFFERS between the resolved plugin and this checkout"
    fi
done

jq_bin="${plugin_dir}/vendor/jq-linux-amd64"

# ---------------------------------------------------------------------------
# Tier 1 — invariants that hold whatever the service says
# ---------------------------------------------------------------------------
echo "--- :test_tube: tier 1 — invariants"

# 1. The baseline: the same render the filter performs internally.
if buildkite-agent pipeline upload --dry-run --format json --no-interpolation \
    <"${SAMPLE}" >"${OUT}/before.json" 2>"${OUT}/before.stderr"; then
    pass "the sample pipeline renders"
else
    echo "the sample pipeline does not render; the fixture is broken, not the plugin." >&2
    cat "${OUT}/before.stderr" >&2
    exit 1
fi

# 2. Run the filter, channels kept apart.
trunk-dynamic-ci-filter <"${SAMPLE}" >"${OUT}/after.json" 2>"${OUT}/filter.stderr"
filter_rc=$?
if [[ ${filter_rc} -eq 0 ]]; then
    pass "the filter exited 0"
else
    fail "the filter exited ${filter_rc}"
fi

# 3. Stdout is the pipeline and NOTHING else. Parsing is a stronger test than
#    grepping for log markers: one stray byte of logging breaks it, whatever that
#    byte happens to say.
if "${jq_bin}" -e 'type == "object"' <"${OUT}/after.json" >/dev/null 2>&1; then
    pass "stdout is a single JSON object and nothing else"
else
    fail "stdout is not parseable as a pipeline — something logged to stdout"
    head -c 400 "${OUT}/after.json" >&2
fi

# 4. THE CENTRAL INVARIANT. Strip every `skip` at every nesting level from both
#    documents; what is left must be identical. That says "the only thing the
#    filter may have changed is `skip:`" — step order, group nesting, unkeyed
#    steps, env, commands, everything — WITHOUT asserting whether anything was
#    skipped. It is the assertion that stays true once the service has history.
"${jq_bin}" -S 'walk(if type == "object" and has("skip") then del(.skip) else . end)' \
    <"${OUT}/before.json" >"${OUT}/before.stripped.json" 2>/dev/null
"${jq_bin}" -S 'walk(if type == "object" and has("skip") then del(.skip) else . end)' \
    <"${OUT}/after.json" >"${OUT}/after.stripped.json" 2>/dev/null
if cmp -s "${OUT}/before.stripped.json" "${OUT}/after.stripped.json"; then
    pass "the pipeline is untouched apart from skip:"
else
    fail "the filter changed something other than skip:"
    diff "${OUT}/before.stripped.json" "${OUT}/after.stripped.json" | head -40 >&2
fi

# 5. Any skip it did add is well-formed: on a keyed, non-trigger step, and within
#    Buildkite's 70-character limit for the field.
if "${jq_bin}" -e '
    [ .. | objects | select(has("skip") and (.skip | type == "string")) ]
    | all(
        (.skip | length > 0 and length <= 70)
        and (.key != null)
        and (.trigger == null)
      )
' <"${OUT}/after.json" >/dev/null 2>&1; then
    pass "every skip added is well-formed, keyed and within 70 chars"
else
    fail "a skip was added that is malformed, unkeyed, or on a trigger step"
fi

# 6. A real agent accepts the result — not merely a JSON parser.
if buildkite-agent pipeline upload --dry-run <"${OUT}/after.json" \
    >/dev/null 2>"${OUT}/after-dryrun.stderr"; then
    pass "buildkite-agent accepts the filtered pipeline"
else
    fail "buildkite-agent rejects the filtered pipeline"
    cat "${OUT}/after-dryrun.stderr" >&2
fi

# 7-8. Fail open, byte-exact, on the two failures a customer actually hits.
#      `emit_unchanged` replays the buffered input, so this compares against the
#      SOURCE file: comments, quoting and trailing newline included.
# Sets LAST_ELAPSED rather than echoing it: `pass` and `fail` write to the log,
# so a function that also returned a value on stdout could only be captured by
# redirecting away the very output that says what happened.
LAST_ELAPSED=0
assert_fails_open() {
    local label="$1" out="$2" err="$3"
    shift 3

    local started
    started="${SECONDS}"
    env "$@" trunk-dynamic-ci-filter <"${SAMPLE}" >"${out}" 2>"${err}"
    local rc=$?
    LAST_ELAPSED=$((SECONDS - started))

    if [[ ${rc} -ne 0 ]]; then
        fail "${label}: exited ${rc}, should fail open with 0"
        return 1
    fi
    if ! cmp -s "${SAMPLE}" "${out}"; then
        fail "${label}: output is not byte-identical to the input"
        return 1
    fi
    if ! saw_fail_open "${err}"; then
        fail "${label}: failed open silently, with no explanation on stderr"
        return 1
    fi
    pass "${label}: exit 0, byte-identical, explained on stderr (${LAST_ELAPSED}s)"
}

assert_fails_open "fail open on a rejected token" \
    "${OUT}/badtoken.out" "${OUT}/badtoken.stderr" \
    TRUNK_STAGING_ORG_API_TOKEN=not-a-real-token

# A REFUSED port, not a blackhole: refused costs ~3s where a blackhole costs the
# full curl timeout budget. The elapsed-time assertion is what would catch a
# regression that dropped the timeout — on the critical path of every customer
# build, an unbounded wait is the worst failure this plugin could have.
if assert_fails_open "fail open on an unreachable API" \
    "${OUT}/unreachable.out" "${OUT}/unreachable.stderr" \
    TRUNK_PUBLIC_API_ADDRESS=http://127.0.0.1:9; then
    if [[ ${LAST_ELAPSED} -lt 30 ]]; then
        pass "the unreachable API failed open in ${LAST_ELAPSED}s, under the 30s bound"
    else
        fail "the unreachable API took ${LAST_ELAPSED}s to fail open; the timeout has regressed"
    fi
fi

# 9. The wire contract, asserted rather than observed. `--print-body` exists for
#    this. The remote parse is the load-bearing part: if it disagrees with how
#    ingestion parses the same remote, the repository row never resolves and every
#    recommendation silently comes back empty.
body="$(
    TRUNK_DCI_JQ="${jq_bin}" \
        TRUNK_DCI_TOKEN_ENV=TRUNK_STAGING_ORG_API_TOKEN \
        "${plugin_dir}/lib/request-plan.sh" --print-body \
        '["smoke-sample-alpha","smoke-sample-beta","smoke-sample-gamma"]' 2>"${OUT}/body.stderr"
)"
printf '%s\n' "${body}" >"${OUT}/request-body.json"

# shellcheck disable=SC2016  # $commit/$org/$pipeline are jq --arg bindings
if "${jq_bin}" -e \
    --arg commit "${BUILDKITE_COMMIT}" \
    --arg org "${BUILDKITE_ORGANIZATION_SLUG}" \
    --arg pipeline "${BUILDKITE_PIPELINE_SLUG}" '
    .repo.host == "github.com"
    and .repo.owner == "trunk-io"
    and .repo.name == "dynamic-ci-buildkite-plugin"
    and .commitSha == $commit
    and .buildkiteOrganizationSlug == $org
    and .buildkitePipelineSlug == $pipeline
    and (.jobKeys | sort) == ["smoke-sample-alpha","smoke-sample-beta","smoke-sample-gamma"]
' <"${OUT}/request-body.json" >/dev/null 2>&1; then
    pass "the request body carries the right repo, commit, org, pipeline and keys"
else
    fail "the request body is wrong"
    cat "${OUT}/request-body.json" >&2
fi

# The pull-request fields are only meaningful on a pull-request build, and a
# build from the UI or the API carries none — asserting them unconditionally
# would make this fail for a reason that is not a defect.
if [[ ${BUILDKITE_PULL_REQUEST:-false} != "false" ]]; then
    # shellcheck disable=SC2016  # $pr is a jq --arg binding
    if "${jq_bin}" -e --arg pr "${BUILDKITE_PULL_REQUEST}" \
        '.prNumber == ($pr | tonumber) and .baseSha != null' \
        <"${OUT}/request-body.json" >/dev/null 2>&1; then
        pass "prNumber and baseSha are populated on a pull-request build"
    else
        fail "prNumber or baseSha is wrong on a pull-request build"
    fi
else
    if "${jq_bin}" -e '.prNumber == null' <"${OUT}/request-body.json" >/dev/null 2>&1; then
        pass "prNumber is null on a non-pull-request build, as it should be"
    else
        fail "prNumber is set on a build that has no pull request"
    fi
fi

# ---------------------------------------------------------------------------
# Tier 2 — the staging deployment answered
# ---------------------------------------------------------------------------
echo "--- :satellite: tier 2 — staging answered"

if grep -qF "debug · request body" "${OUT}/filter.stderr" &&
    grep -qF "debug · plan" "${OUT}/filter.stderr"; then
    pass "a request was sent and a plan came back and parsed"
else
    fail "no plan was requested or none parsed (is debug: true still set?)"
fi

# The absence of a fail-open marker IS the claim that a 2xx plan was read: with
# no history the resulting pipeline is identical either way, so there is nothing
# else to look at.
if saw_fail_open "${OUT}/filter.stderr"; then
    fail "the filter failed open against staging"
    grep -F "Dynamic CI" "${OUT}/filter.stderr" >&2 || true
else
    pass "the filter did not fail open"
fi

# ---------------------------------------------------------------------------
echo "--- :bar_chart: result"
if [[ ${failures} -ne 0 ]]; then
    echo "${failures} assertion(s) failed. Artifacts are under smoke-out/." >&2
    exit 1
fi
echo "every assertion passed"

# Only now, and only from the filtered output, so the steps that run are the ones
# the plugin actually produced. The verdict step at the end of it checks that what
# ran and what was marked agree.
echo "--- :pipeline: uploading the filtered sample pipeline"
buildkite-agent pipeline upload <"${OUT}/after.json"
