#!/usr/bin/env bash
# Every file the agent executes must be executable in git.
#
# This is here because the failure it catches is silent. Buildkite runs
# `hooks/environment` and `hooks/command` by path; a checkout that lost an exec
# bit produces a plugin that contributes nothing, fails open, and looks like a
# service that simply had no opinion. Cheap to assert, invisible otherwise.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

readonly REQUIRED=(
    hooks/command
    hooks/environment
    bin/trunk-dynamic-ci-filter
    lib/debug.sh
    lib/filter-impl.sh
    lib/jq.sh
    lib/notice.sh
    lib/request-plan.sh
    scripts/update-jq.sh
    vendor/jq-linux-amd64
    vendor/jq-linux-arm64
    vendor/jq-macos-arm64
)

failed=0
for file in "${REQUIRED[@]}"; do
    if [[ ! -f ${file} ]]; then
        echo "missing: ${file}" >&2
        failed=1
    elif [[ ! -x ${file} ]]; then
        echo "not executable: ${file}" >&2
        failed=1
    fi
done

# The list above is a denylist of omissions as much as a checklist: a new
# lib/*.sh that nobody added here would go unchecked, so catch that too.
while IFS= read -r found; do
    if [[ ! -x ${found} ]]; then
        echo "not executable: ${found}" >&2
        failed=1
    fi
done < <(find hooks bin lib scripts -type f -name '*.sh' -o -type f -path 'hooks/*' -o -type f -path 'bin/*')

if [[ ${failed} -ne 0 ]]; then
    echo >&2
    echo "Fix with: git update-index --chmod=+x <file>" >&2
    exit 1
fi

echo "all ${#REQUIRED[@]} executables carry their exec bit"
