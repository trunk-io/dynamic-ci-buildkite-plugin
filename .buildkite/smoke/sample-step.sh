#!/usr/bin/env bash
# One step of the sample pipeline. It records that it ran, and checks the one
# thing only a real agent can tell us.
set -euo pipefail

name="${1:?usage: sample-step.sh <name>}"

# The verdict step reads this. A step that was planned away never gets here, and
# that absence is exactly what the verdict tests against the filtered pipeline.
buildkite-agent meta-data set "smoke-ran-${name}" ok

# THE INTERPOLATION CONTRACT, measured rather than assumed.
#
# `SMOKE_INTERPOLATION_CANARY` was written as `build-${BUILDKITE_BUILD_NUMBER}` in
# sample.yml and must have been interpolated exactly once, by the upload in
# run.sh. Both failure modes are visible here:
#
#   * no pass at all — the literal `${BUILDKITE_BUILD_NUMBER}` survives, which is
#     what happens if `--no-interpolation` reaches the customer's own upload
#   * two passes — the value would already have been consumed upstream
#
# This is the failure the plugin's README warns about, and the only place it can
# actually be observed is on an agent.
expected="build-${BUILDKITE_BUILD_NUMBER}"
if [[ ${SMOKE_INTERPOLATION_CANARY-} != "${expected}" ]]; then
    echo "interpolation canary mismatch in step '${name}'" >&2
    echo "  expected: ${expected}" >&2
    echo "  got:      ${SMOKE_INTERPOLATION_CANARY:-<unset>}" >&2
    exit 1
fi

echo "sample step '${name}' ran; interpolation canary is ${SMOKE_INTERPOLATION_CANARY}"
