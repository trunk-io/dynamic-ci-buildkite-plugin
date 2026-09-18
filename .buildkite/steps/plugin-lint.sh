#!/usr/bin/env bash
# `buildkite/plugin-linter` — the structural check the Buildkite plugins
# directory expects of a published plugin.
#
# `--id trunk-io/dynamic-ci` is the short reference consumers write. The linter
# resolves it the way Buildkite does (appending `-buildkite-plugin`) and
# cross-checks it against the `plugins:` examples in README.md, so this also
# catches a README that documents a reference nobody can use — which is the
# entire reason this plugin got its own repository.
#
# We deliberately do NOT also adopt `buildkite/plugin-tester` (BATS). The vitest
# suite already drives the real hooks and the real jq out of process; a BATS
# harness would be a second, weaker one over the same surface. See CONTRIBUTING.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not available on this agent; the plugin linter needs it." >&2
    echo "Run it locally instead:" >&2
    # shellcheck disable=SC2016  # printing a command to copy; $PWD must stay literal
    echo '  docker run --rm -v "$PWD:/plugin:ro" buildkite/plugin-linter --id trunk-io/dynamic-ci' >&2
    exit 1
fi

echo "--- :buildkite: plugin-linter"
exec docker run --rm -v "${PWD}:/plugin:ro" buildkite/plugin-linter \
    --id trunk-io/dynamic-ci
