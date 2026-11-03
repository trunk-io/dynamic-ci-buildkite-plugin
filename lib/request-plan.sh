#!/usr/bin/env bash
# Trunk Dynamic CI — the plan request.
#
# Builds the request body from the agent's environment, POSTs it to
# /v2/dynamic-ci/generate-buildkite-plan, and prints the plan on stdout. Exiting
# non-zero is a supported outcome: `hooks/command` then uploads the pipeline
# unmodified, so an outage costs a full CI run rather than a broken build.
#
# Usage:
#   request-plan.sh <job-keys-json>                POST and print the plan
#   request-plan.sh --print-body <job-keys-json>   print the body, make no call
#
# `--print-body` exists for the tests: they validate that output against the
# vendored copy of the published schema, so a missing, renamed or mistyped field
# is a CI failure here rather than a 400 nobody sees until a customer's build.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=jq.sh
source "${LIB_DIR}/jq.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=debug.sh
source "${LIB_DIR}/debug.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=telemetry.sh
source "${LIB_DIR}/telemetry.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "${LIB_DIR}/env.sh"

DEFAULT_API_ADDRESS="https://api.trunk.io"
PLAN_PATH="/v2/dynamic-ci/generate-buildkite-plan"
# Mirrors the GitHub Action's budget: 30s per attempt, three attempts total.
TIMEOUT_SECONDS=30
RETRIES=2
MAX_CHANGED_FILES=200
MAX_IMPACT_COUNT=10000000
MAX_IMPACTS=8

log() { echo "$1" >&2; }

# `owner/name` and the host from a git remote, matching what CI ingestion did
# when it created the repository row this request is resolved against.
#
# Load-bearing: the row is keyed on (org, host, "owner/name") from ingestion's
# OWN parse of this same remote. A disagreement finds no repository and the
# request fails open with nothing visible to the customer, so the two rules have
# to stay the same — take the LAST `@` (a token-bearing HTTPS remote is real,
# and its userinfo may itself contain one) and strip a `www.` prefix.
dci_parse_remote() {
    local remote="$1" rest host path

    rest="${remote##*@}" # drop scheme+userinfo if an `@` is present
    rest="${rest#*://}"  # otherwise drop the scheme
    rest="${rest#www.}"  # ingestion strips this generically; match it

    if [[ ${rest} == *:* && ${rest} != */* ]]; then
        host="${rest%%:*}"
        path="${rest#*:}"
    elif [[ ${rest} == *:* && ${rest%%:*} != *"/"* ]]; then
        host="${rest%%:*}" # scp form: host:owner/name
        path="${rest#*:}"
    else
        host="${rest%%/*}"
        path="${rest#*/}"
    fi

    path="${path%.git}"
    path="${path%/}"

    if [[ -z ${host} || ${path} != */* ]]; then
        log "could not read owner/name out of the remote ${remote}"
        return 1
    fi

    printf '%s\n%s\n' "${host}" "${path}"
}

# The merge base of the PR's target branch and HEAD, or empty when there is no
# PR or git cannot answer. Empty becomes a null `baseSha`, which is legal and
# costs the diff-derived signals rather than the whole plan.
dci_base_sha() {
    local base_branch="${BUILDKITE_PULL_REQUEST_BASE_BRANCH-}"
    if [[ -z ${base_branch} ]]; then
        return 0
    fi
    git merge-base "origin/${base_branch}" HEAD 2>/dev/null ||
        git merge-base "${base_branch}" HEAD 2>/dev/null ||
        true
}

# Fails rather than writing an empty list, which would read as "nothing changed";
# the omitted field sends the server to GitHub instead.
dci_changed_files() {
    local jq_bin="$1" base="$2" range="$3" out="$4" dir
    [[ -n ${base} ]] || return 1

    dir="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: $dir must not change later
    trap "rm -rf '${dir}'" RETURN

    git diff -z -M --no-ext-diff --no-textconv --name-status "${range}" \
        >"${dir}/status" 2>/dev/null || return 1
    git diff -z -M --no-ext-diff --no-textconv --numstat "${range}" \
        >"${dir}/numstat" 2>/dev/null || return 1
    "${jq_bin}" -n \
        --rawfile status "${dir}/status" \
        --rawfile numstat "${dir}/numstat" \
        --arg base "${base}" \
        --argjson max "${MAX_CHANGED_FILES}" \
        -f "${LIB_DIR}/changed-files.jq" >"${out}" 2>/dev/null || return 1
}

# The option's value, else the variable its `-env` twin names, read when the job
# runs: `$VAR` in pipeline YAML is filled in at upload, before a checkout sets it.
dci_option_or_env() {
    local value="$1" name="$2"
    if [[ -n ${value} ]]; then
        echo "${value}"
    else
        dci_env "${name}"
    fi
}

dci_commit_sha() {
    local sha
    sha="$(dci_option_or_env "${BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA-}" \
        "${BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA_ENV-}")"
    echo "${sha:-${BUILDKITE_COMMIT-}}"
}

# `BUILDKITE_PULL_REQUEST` is the literal string "false" off a pull request, not
# an empty value — so this has to be compared, never tested for truthiness.
dci_pr_number() {
    local pr="${BUILDKITE_PULL_REQUEST:-false}"
    if [[ ${pr} == "false" || -z ${pr} ]]; then
        return 0
    fi
    echo "${pr}"
}

# One `impacts` entry as JSON, or nothing (with a warning) when it is unreadable.
dci_impact_entry() {
    local jq_bin="$1" index="$2"
    local prefix="BUILDKITE_PLUGIN_DYNAMIC_CI_IMPACTS_${index}"
    local source count all
    source="$(dci_env "${prefix}_SOURCE")"
    count="$(dci_env "${prefix}_COUNT")"
    all="$(dci_env "${prefix}_ALL")"
    local entry="impacts[${index}]"

    if [[ ! ${source} =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
        log "Dynamic CI: ${entry}.source must be lowercase letters, digits, '.', '_' or '-', at most 64 characters, not '${source}'; dropping it"
        return 0
    fi

    # A case per spelling rather than `${all,,}`: macOS agents run bash 3.2.
    case "${all}" in
    "" | false | False | FALSE) all=false ;;
    true | True | TRUE) all=true ;;
    *)
        log "Dynamic CI: ${entry}.all must be true or false, not '${all}'; dropping ${source}"
        return 0
        ;;
    esac

    if [[ ! ${count} =~ ^[0-9]{1,8}$ ]] || ((10#${count} > MAX_IMPACT_COUNT)); then
        if [[ ${all} == false ]]; then
            log "Dynamic CI: ${entry}.count must be a whole number from 0 to ${MAX_IMPACT_COUNT}, not '${count}'; dropping ${source}"
            return 0
        fi
        count=""
    fi

    # shellcheck disable=SC2016 # jq variables, bound by --arg, not shell ones
    "${jq_bin}" -cn --arg source "${source}" --arg count "${count}" --argjson all "${all}" \
        '{source: $source, all: $all}
        + (if $count == "" then {} else {count: ($count | tonumber)} end)'
}

# The `impacts` option as a JSON list, or `null` when none is readable. Buildkite
# flattens the list to IMPACTS_<n>_*, read up to the first index with nothing set.
# Dropping an entry costs only the impact-reach signal; it never fails the plan.
dci_impacts() {
    local jq_bin="$1" index=0 kept=0 entries="" entry source seen=","
    local prefix="BUILDKITE_PLUGIN_DYNAMIC_CI_IMPACTS"
    while [[ -n "$(dci_env "${prefix}_${index}_SOURCE")$(dci_env "${prefix}_${index}_COUNT")$(dci_env "${prefix}_${index}_ALL")" ]]; do
        source="$(dci_env "${prefix}_${index}_SOURCE")"
        entry="$(dci_impact_entry "${jq_bin}" "${index}")"
        index=$((index + 1))
        if [[ -z ${entry} ]]; then
            continue
        elif [[ ${seen} == *",${source},"* ]]; then
            log "Dynamic CI: impacts lists ${source} more than once; keeping the first"
        elif ((kept >= MAX_IMPACTS)); then
            log "Dynamic CI: impacts has more than ${MAX_IMPACTS} entries; dropping ${source}"
        else
            seen="${seen}${source},"
            entries="${entries}${entry}"$'\n'
            kept=$((kept + 1))
        fi
    done

    if [[ -z ${entries} ]]; then
        echo null
        return 0
    fi
    printf '%s' "${entries}" | "${jq_bin}" -cs '.'
}

dci_build_body() {
    local jq_bin="$1" job_keys="$2" host="$3" repo_path="$4" base="$5"
    local changed_files="$6"
    local owner="${repo_path%%/*}" name="${repo_path#*/}"

    # Built by jq rather than printf: every value here is attacker-adjacent (a
    # branch name, a commit author) and jq escapes them correctly by construction.
    # `--arg` is always a string; the nulls and numbers are shaped below.
    #
    # `runId` is the build number, not `BUILDKITE_BUILD_ID`: the plan is scored
    # against the build's spans, which carry `buildkite.build.number` and never the
    # build UUID. `runAttempt` is constant because Buildkite has no build-level
    # attempt — a rebuild is a new build — and `BUILDKITE_RETRY_COUNT` counts
    # retries of THIS JOB, so in step mode each step would send a different one.
    "${jq_bin}" -n \
        --arg host "${host}" \
        --arg owner "${owner}" \
        --arg name "${name}" \
        --arg commitSha "$(dci_commit_sha)" \
        --arg baseSha "${base}" \
        --arg branch "${BUILDKITE_BRANCH-}" \
        --arg prNumber "$(dci_pr_number)" \
        --arg runId "${BUILDKITE_BUILD_NUMBER-}" \
        --argjson runAttempt 1 \
        --arg triggeringActor "${BUILDKITE_BUILD_CREATOR-}" \
        --arg eventName "${BUILDKITE_SOURCE-}" \
        --arg orgSlug "${BUILDKITE_ORGANIZATION_SLUG-}" \
        --arg pipelineSlug "${BUILDKITE_PIPELINE_SLUG-}" \
        --arg ignoreSignals "${BUILDKITE_PLUGIN_DYNAMIC_CI_IGNORE_SIGNALS-}" \
        --argjson jobKeys "${job_keys}" \
        --argjson impacts "$(dci_impacts "${jq_bin}")" \
        --slurpfile changedFiles "${changed_files}" \
        -f "${LIB_DIR}/request-body.jq"
}

# The failure reason and repo for the caller's telemetry, in the Action's vocabulary.
DCI_FAIL_REASON="internal"
DCI_REPO_JSON="{}"
dci_note_outcome() {
    local jq_bin="$1" reason="$2"
    [[ -n ${TRUNK_DCI_META-} ]] || return 0
    # shellcheck disable=SC2016 # jq variables, bound by --arg, not shell ones
    "${jq_bin}" -cn --argjson repo "${DCI_REPO_JSON}" --arg reason "${reason}" \
        '{repo: $repo, reason: $reason}' >"${TRUNK_DCI_META}" 2>/dev/null || true
}

# `--retry` alone gives up at once on a connection reset or refusal; the Action
# retries those. Probed because curl before 7.71 rejects the flag outright.
dci_curl_retries_all_errors() {
    [[ "$(curl --help all 2>/dev/null)" == *--retry-all-errors* ]]
}

dci_post() {
    local body_file="$1" token="$2" url="$3" jq_bin="$4" response status code
    local -a retry_flags=(--retry "${RETRIES}" --retry-delay 1)

    response="$(mktemp)"
    # shellcheck disable=SC2064  # expand now: $response must not change later
    trap "rm -f '${response}'" RETURN

    if dci_curl_retries_all_errors; then
        retry_flags+=(--retry-all-errors)
    fi
    status="$(curl -sS -o "${response}" -w '%{http_code}' \
        --max-time "${TIMEOUT_SECONDS}" "${retry_flags[@]}" \
        -X POST "${url}" \
        -A "$(dci_user_agent "${jq_bin}")" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data-binary "@${body_file}")" || {
        code=$?
        if [[ ${code} == 28 ]]; then
            DCI_FAIL_REASON="timeout"
        else
            DCI_FAIL_REASON="transport"
        fi
        log "the plan request could not be made"
        return 1
    }

    if [[ ${status} != 2?? ]]; then
        case "${status}" in
        429) DCI_FAIL_REASON="http_rate_limited" ;;
        4??) DCI_FAIL_REASON="http_client_error" ;;
        *) DCI_FAIL_REASON="http_server_error" ;;
        esac
        log "the plan request returned HTTP ${status}"
        # The envelope carries a coded message worth surfacing; cap it so a stray
        # HTML error page cannot flood the build log.
        head -c 500 "${response}" >&2 || true
        echo >&2
        return 1
    fi

    cat "${response}"
}

main() {
    local print_body=false

    if [[ ${1-} == "--print-body" ]]; then
        print_body=true
        shift
    fi

    local job_keys="${1-}"
    if [[ -z ${job_keys} ]]; then
        log "usage: request-plan.sh [--print-body] <job-keys-json>"
        return 1
    fi

    local jq_bin
    # The hook has already resolved and verified a jq; reuse it rather than
    # hashing the binary a second time.
    if [[ -n ${TRUNK_DCI_JQ-} ]]; then
        jq_bin="${TRUNK_DCI_JQ}"
    elif ! jq_bin="$(dci_resolve_jq "${LIB_DIR}/../vendor")"; then
        return 1
    fi

    local remote="${BUILDKITE_REPO-}"
    if [[ -z ${remote} ]]; then
        log "BUILDKITE_REPO is not set, so the repository cannot be identified"
        return 1
    fi

    local parsed host repo_path
    if ! parsed="$(dci_parse_remote "${remote}")"; then
        return 1
    fi
    host="$(head -n1 <<<"${parsed}")"
    repo_path="$(tail -n1 <<<"${parsed}")"
    # shellcheck disable=SC2016 # jq variables, bound by --arg, not shell ones
    DCI_REPO_JSON="$("${jq_bin}" -cn --arg host "${host}" --arg path "${repo_path}" \
        '{host: $host, owner: ($path | split("/")[0]), name: ($path | split("/")[1:] | join("/"))}')"

    local work base
    work="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: $work must not change later
    trap "rm -rf '${work}'" EXIT
    # A base the caller names is compared to HEAD directly; it need not be an
    # ancestor, so a merge base could pick the wrong one of several.
    local range
    base="$(dci_option_or_env "${BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA-}" \
        "${BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA_ENV-}")"
    if [[ -n ${base} ]]; then
        range="${base}..HEAD"
    else
        base="$(dci_base_sha)"
        range="${base}...HEAD"
    fi
    if ! dci_changed_files "${jq_bin}" "${base}" "${range}" "${work}/changed-files.json"; then
        : >"${work}/changed-files.json"
    fi

    dci_build_body "${jq_bin}" "${job_keys}" "${host}" "${repo_path}" \
        "${base}" "${work}/changed-files.json" >"${work}/body.json"

    # The body is what diagnoses a resolution that looked fine and was not: the
    # wrong pipeline slug, a null baseSha, a repo parsed differently from how
    # ingestion parsed it. It carries no credential — the token rides a header.
    if dci_debug_enabled; then
        dci_debug_block "${jq_bin}" "request body" \
            "$("${jq_bin}" 'if .changedFiles then .changedFiles.files |= "\(length) files" else . end' "${work}/body.json")"
    fi

    if [[ ${print_body} == true ]]; then
        cat "${work}/body.json"
        return 0
    fi

    local token_env="${TRUNK_DCI_TOKEN_ENV:-TRUNK_TOKEN}" token
    token="$(dci_env "${token_env}")"
    if [[ -z ${token} ]]; then
        log "no Trunk API token in \$${token_env} — set it, or point token-env at the variable holding it"
        return 1
    fi

    local address="${TRUNK_PUBLIC_API_ADDRESS:-${DEFAULT_API_ADDRESS}}"
    if ! dci_post "${work}/body.json" "${token}" "${address%/}${PLAN_PATH}" "${jq_bin}"; then
        dci_note_outcome "${jq_bin}" "${DCI_FAIL_REASON}"
        return 1
    fi
    dci_note_outcome "${jq_bin}" ""
}

main "$@"
