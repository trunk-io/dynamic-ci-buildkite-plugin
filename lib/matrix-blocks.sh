#!/usr/bin/env bash
# The plan request's `matrixBlocks`: each requested matrix step's `matrix:`
# block with the build's environment variables resolved.
#
# The pipeline this plugin uploads is still the `--no-interpolation` render; a
# second, interpolating dry-run is made only to read matrix values, and only
# when that render has a requested step with a `matrix:`, so a pipeline with
# none pays nothing. Every failure leaves the output file empty, which sends no
# blocks: Trunk then decides each matrix step whole, as before.

DCI_MATRIX_DRY_RUN_SECONDS=5
# The published limit: Trunk ignores a larger map.
DCI_MATRIX_BLOCKS_MAX_BYTES=65536

# shellcheck source-path=SCRIPTDIR
# shellcheck source=timeout.sh
source "$(dirname "${BASH_SOURCE[0]}")/timeout.sh"

dci_collect_matrices() {
    local jq_bin="$1" keys="$2"
    "${jq_bin}" -c --argjson keys "${keys}" \
        --argjson max "${DCI_MATRIX_BLOCKS_MAX_BYTES}" \
        -f "$(dirname "${BASH_SOURCE[0]}")/collect-matrices.jq"
}

# dci_matrix_blocks <jq> <keys-json> <rendered-json> <pipeline-file> <out-file>
dci_matrix_blocks() {
    local jq_bin="$1" keys="$2" rendered="$3" pipeline="$4" out="$5"
    local found interpolated collected status
    : >"${out}"

    found="$(dci_collect_matrices "${jq_bin}" "${keys}" <<<"${rendered}" 2>/dev/null)" || return 0
    if [[ "$("${jq_bin}" -r '(.blocks | length) + (.omitted | length)' <<<"${found}")" == 0 ]]; then
        return 0
    fi

    interpolated="$(with_timeout "${DCI_MATRIX_DRY_RUN_SECONDS}" \
        buildkite-agent pipeline upload --dry-run --format json <"${pipeline}" 2>/dev/null)"
    status=$?
    if [[ ${status} == 124 ]]; then
        log "--- :trunk: Dynamic CI could not read matrix values in ${DCI_MATRIX_DRY_RUN_SECONDS} s — matrix steps are decided whole"
        return 0
    fi
    if [[ ${status} != 0 ]]; then
        log "--- :trunk: Dynamic CI could not read matrix values — matrix steps are decided whole"
        return 0
    fi

    # A render with none of the matrix steps the first one had is not this pipeline.
    if ! collected="$(dci_collect_matrices "${jq_bin}" "${keys}" <<<"${interpolated}" 2>/dev/null)" ||
        ! "${jq_bin}" -e '(.blocks | length) + (.omitted | length) > 0' >/dev/null 2>&1 <<<"${collected}"; then
        log "--- :trunk: Dynamic CI could not read matrix values — matrix steps are decided whole"
        return 0
    fi

    local omitted
    omitted="$("${jq_bin}" -r '.omitted | join(", ")' <<<"${collected}")"
    if [[ -n ${omitted} ]]; then
        log "--- :trunk: Dynamic CI sent no matrix for ${omitted}: over the 64 KiB limit, so decided whole"
    fi
    "${jq_bin}" -c '.blocks | select(length > 0)' <<<"${collected}" >"${out}" 2>/dev/null || : >"${out}"
}
