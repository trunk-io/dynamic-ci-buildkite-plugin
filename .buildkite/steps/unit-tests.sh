#!/usr/bin/env bash
# Typecheck, then the unit suite, with results reported to Trunk Flaky Tests.
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

# Ahead of the tests and outside the uploader: a type error is a defect in the
# tests themselves, and there is nothing to report about it.
echo "--- :typescript: typecheck"
pnpm typecheck

# `TRUNK_PUBLIC_REPO_ID` is a non-secret per-repo identifier, set as plain `env:`
# in the pipeline. It is what keeps this step free of any `secrets:` block, and
# so keeps this whole pipeline movable to a secret-free cluster the day we want
# CI on fork pull requests.
#
# Until it is set, the suite still runs and still gates the build — it just
# reports nowhere. That is deliberate: an unreported suite is a gap worth seeing
# in the log, not a reason to fail a pull request.
if [[ -z ${TRUNK_PUBLIC_REPO_ID-} ]]; then
    echo "--- :vitest: unit tests (not reported to Trunk Flaky Tests)"
    echo "TRUNK_PUBLIC_REPO_ID is unset, so results are not being uploaded." >&2
    echo "Set it as plain env: on this pipeline to turn reporting on." >&2
    exec pnpm test
fi

echo "--- :vitest: unit tests"
curl -fsSLO --retry 3 https://trunk.io/releases/trunk
chmod +x trunk

# `flakytests test` runs the command, uploads the report, and re-applies
# quarantining to its own exit code. That is the whole of what the GitHub Actions
# lane needed `continue-on-error:` plus the uploader's `previous-step-outcome` to
# express: a quarantined flake passes, a real failure does not.
exec ./trunk flakytests test \
    --org-url-slug trunk \
    --public-repo-id "${TRUNK_PUBLIC_REPO_ID}" \
    --junit-paths junit.xml \
    -- pnpm test
