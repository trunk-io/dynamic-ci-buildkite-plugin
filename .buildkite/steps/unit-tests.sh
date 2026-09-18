#!/usr/bin/env bash
# Typecheck, then the unit suite.
#
# This step RUNS the tests and nothing else. Reporting them to Trunk Flaky Tests
# is a separate pipeline step — see `upload-unit-tests` in ../pipeline.yml — so
# that the upload happens whether or not the suite passed, which is precisely
# when a flake is worth knowing about.
#
# The suite is the real gate on this repository: it execs the actual bash and the
# actual vendored jq out of process, against a fake `buildkite-agent` on PATH and
# a loopback plan server. Green here means the shell and the jq programs still
# behave, which no amount of linting establishes.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

echo "--- :pnpm: install"
PNPM_VERSION="$(sed -n 's/.*"packageManager": *"pnpm@\([0-9.]*\)".*/\1/p' package.json)"
: "${PNPM_VERSION:?could not read the pnpm version from package.json}"
npm install -g "pnpm@${PNPM_VERSION}"
pnpm install --frozen-lockfile

# Ahead of the tests: a type error is a defect in the tests themselves, and there
# is nothing to report to Flaky Tests about one.
echo "--- :typescript: typecheck"
pnpm typecheck

echo "--- :vitest: unit tests"
pnpm test
