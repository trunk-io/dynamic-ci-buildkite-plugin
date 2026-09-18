#!/usr/bin/env bash
# One step of the sample pipeline.
set -euo pipefail

name="${1:?usage: sample-step.sh <name>}"

# The verdict step reads this; a step that was planned away never gets here.
buildkite-agent meta-data set "smoke-ran-${name}" ok

# The canary must have been interpolated exactly once, by the upload in run.sh.
# Zero passes leaves the literal `${BUILDKITE_BUILD_NUMBER}` — what happens if
# `--no-interpolation` reaches the pipeline's own upload; two passes would have
# consumed it upstream. Only an agent can show either.
expected="build-${BUILDKITE_BUILD_NUMBER}"
if [[ ${SMOKE_INTERPOLATION_CANARY-} != "${expected}" ]]; then
    echo "interpolation canary mismatch in step '${name}'" >&2
    echo "  expected: ${expected}" >&2
    echo "  got:      ${SMOKE_INTERPOLATION_CANARY:-<unset>}" >&2
    exit 1
fi

echo "sample step '${name}' ran; interpolation canary is ${SMOKE_INTERPOLATION_CANARY}"
