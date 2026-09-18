#!/usr/bin/env bash
# `trunk check` on a Buildkite agent.
#
# There is no `trunk-io/trunk-action` equivalent here, so this does by hand what
# that action does: fetch the launcher, make the node toolchain available (eslint
# needs the dependency tree to resolve), run the check, and turn a failure into
# something a reviewer can read without opening the job.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

echo "--- :pnpm: install"
PNPM_VERSION="$(sed -n 's/.*"packageManager": *"pnpm@\([0-9.]*\)".*/\1/p' package.json)"
: "${PNPM_VERSION:?could not read the pnpm version from package.json}"
npm install -g "pnpm@${PNPM_VERSION}"
pnpm install --frozen-lockfile

# eslint runs here as well as under `trunk check`, and that is not redundant:
# trunk lints a copy in a temp directory, where the flat config's own
# `allowDefaultProject` path cannot match, so eslint.config.mjs is excluded there
# and covered here. See the ignore in .trunk/trunk.yaml.
echo "--- :eslint: config"
pnpm lint

echo "--- :trunk: check"
curl -fsSLO --retry 3 https://trunk.io/releases/trunk
chmod +x trunk

# `--all`, not hold-the-line. Buildkite's checkout does not fetch the base
# branch, so `--upstream` would need a fetch and a merge-base; over a repo this
# size a whole-repo check costs less than the subtlety, and it makes a `main`
# build and a pull-request build identical.
set +e
./trunk check --all --ci --no-progress 2>&1 | tee trunk-check.out
rc="${PIPESTATUS[0]}"
set -e

# A Buildkite job log is not a GitHub check annotation. Without this the failure
# is only visible to someone who opens the job.
if [[ ${rc} -ne 0 ]] && command -v buildkite-agent >/dev/null 2>&1; then
    {
        # shellcheck disable=SC2016  # markdown backticks, not an expansion
        echo '### :trunk: `trunk check` found issues'
        echo
        echo '```term'
        cat trunk-check.out
        echo '```'
    } | buildkite-agent annotate --style error --context trunk-check
fi

exit "${rc}"
