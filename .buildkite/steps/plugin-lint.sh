#!/usr/bin/env bash
# The structural check the Buildkite plugins directory expects.
#
# `--id` is the short reference consumers write. The linter resolves it the way
# Buildkite does and cross-checks it against the `plugins:` examples in
# README.md, so it also catches a README documenting a reference nobody can use.
#
# `--skip-invalid` is there for the `#v<version>` placeholder the README writes
# instead of a pinned tag. The linter's version check reads every
# `trunk-io/dynamic-ci#<ref>:` in the README and does two things with it: fails a
# ref that does not parse as a version, and fails one that parses but is older
# than our newest tag. A real version in the README therefore goes stale on the
# next release — the check would have us edit six lines every time — while the
# placeholder simply does not parse. This turns off the first half only. The
# second still stands, so a real version that creeps back in and goes out of date
# is still caught.
#
# On not adopting `buildkite/plugin-tester` as well, see CONTRIBUTING.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not available on this agent; the plugin linter needs it." >&2
    echo "Run it locally instead:" >&2
    # shellcheck disable=SC2016  # printing a command to copy; $PWD must stay literal
    echo '  docker run --rm -v "$PWD:/plugin:ro" buildkite/plugin-linter --id trunk-io/dynamic-ci --skip-invalid' >&2
    exit 1
fi

echo "--- :buildkite: plugin-linter"
exec docker run --rm -v "${PWD}:/plugin:ro" buildkite/plugin-linter \
    --id trunk-io/dynamic-ci \
    --skip-invalid
