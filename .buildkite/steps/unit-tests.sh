#!/usr/bin/env bash
# Typecheck, then the unit suite.
#
# Running the tests is all this does; reporting them is the `upload-unit-tests`
# step in ../pipeline.yml, so that results upload whether or not the suite passed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

echo "--- :pnpm: install"
PNPM_VERSION="$(sed -n 's/.*"packageManager": *"pnpm@\([0-9.]*\)".*/\1/p' package.json)"
: "${PNPM_VERSION:?could not read the pnpm version from package.json}"
npm install -g "pnpm@${PNPM_VERSION}"
pnpm install --frozen-lockfile

# Ahead of the tests: a type error is a defect in the tests, not a test result.
echo "--- :typescript: typecheck"
pnpm typecheck

echo "--- :vitest: unit tests"
pnpm test
