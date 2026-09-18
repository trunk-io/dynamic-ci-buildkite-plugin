#!/usr/bin/env bash
# The structural check the Buildkite plugins directory expects.
#
# `--id` is the short reference consumers write. The linter resolves it the way
# Buildkite does and cross-checks it against the `plugins:` examples in
# README.md, so it also catches a README documenting a reference nobody can use.
#
# On not adopting `buildkite/plugin-tester` as well, see CONTRIBUTING.md.
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
