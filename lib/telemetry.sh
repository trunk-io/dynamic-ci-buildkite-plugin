#!/usr/bin/env bash
# Plan telemetry, to the GitHub Action's endpoint: one attempt, one second, never an error.

DCI_TELEMETRY_PATH="/v1/dynamic-ci/plan-metrics"
# Found from this file, never from an inherited variable a customer's job can set.
DCI_TELEMETRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only when the plugin is the checkout's root: a copy vendored inside another
# repository would otherwise report that repository's commit as ours.
dci_checkout_ref() {
    local root
    root="$(cd "${DCI_TELEMETRY_DIR}/.." 2>/dev/null && pwd -P)" || return 0
    command -v git >/dev/null 2>&1 || return 0
    (
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
        [[ "$(git -C "${root}" rev-parse --show-toplevel 2>/dev/null)" == "${root}" ]] || exit 0
        git -C "${root}" describe --tags --exact-match HEAD 2>/dev/null ||
            git -C "${root}" rev-parse --short=7 HEAD 2>/dev/null
    ) </dev/null 2>/dev/null || true
}

# A full sha is cut to 7: the server keeps at most 32 characters of the label.
dci_plugin_ref() {
    local jq_bin="$1" ref
    ref="$("${jq_bin}" -r '[.[] | keys[] | select(test("dynamic-ci"; "i"))][0] // ""
        | if contains("#") then split("#") | last else "" end' \
        <<<"${BUILDKITE_PLUGINS:-[]}" 2>/dev/null)" || ref=""
    if [[ -z ${ref} ]]; then
        ref="$(dci_checkout_ref)" || ref=""
    fi
    if [[ ${ref} =~ ^[0-9a-fA-F]{40}$ ]]; then
        ref="${ref:0:7}"
    fi
    echo "${ref:-unknown}"
}

dci_user_agent() {
    echo "trunk-dynamic-ci-buildkite-plugin/$(dci_plugin_ref "$1")"
}

dci_now_ms() {
    if [[ -n ${EPOCHREALTIME-} ]]; then
        local now="${EPOCHREALTIME/[.,]/}"
        echo "$((10#${now} / 1000))"
    else
        echo "$((SECONDS * 1000))"
    fi
}

dci_telemetry_url() {
    local address="${TRUNK_PUBLIC_API_ADDRESS:-https://api.trunk.io}"
    address="${address%/}"
    if [[ ${address} == https://* ]]; then
        local host="${address#https://}"
        echo "https://telemetry.${host%%/*}${DCI_TELEMETRY_PATH}"
    else
        echo "${address}${DCI_TELEMETRY_PATH}"
    fi
}

dci_send_telemetry() {
    local jq_bin="$1" token="$2" status="$3" reason="$4" job_count="$5" started_ms="$6"
    local meta_file="$7" escaped body
    local disabled
    disabled="$(tr -d '[:space:]' <<<"${TRUNK_DISABLE_TELEMETRY-}" | tr '[:upper:]' '[:lower:]')"
    if [[ ${disabled} == "true" || -z ${token} ]]; then
        return 0
    fi

    escaped="$("${jq_bin}" -rn \
        --arg version "buildkite/$(dci_plugin_ref "${jq_bin}")" \
        --argjson repo "$("${jq_bin}" -c '.repo // {}' "${meta_file}" 2>/dev/null || echo '{}')" \
        --argjson status "${status}" \
        --arg reason "${reason}" \
        --argjson duration_ms "$(($(dci_now_ms) - started_ms))" \
        --argjson job_count "${job_count}" \
        -f "${DCI_TELEMETRY_DIR}/telemetry.jq" 2>/dev/null)" || return 0

    body="$(mktemp 2>/dev/null)" || return 0
    printf '%b' "${escaped}" 2>/dev/null >"${body}" || {
        rm -f "${body}"
        return 0
    }
    curl -sS -o /dev/null --max-time 1 \
        -X POST "$(dci_telemetry_url)" \
        -A "$(dci_user_agent "${jq_bin}")" \
        -H "x-api-token: ${token}" \
        -H "Content-Type: application/x-protobuf" \
        --data-binary "@${body}" >/dev/null 2>&1 || true
    rm -f "${body}"
    return 0
}
