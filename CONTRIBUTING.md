# Contributing

The plugin is bash and [`jq`](https://jqlang.org). There is nothing to build: the
repository is the artifact Buildkite checks out.

## Setup

Node and [pnpm](https://pnpm.io) are needed for the test suite only — the plugin
itself never sees them.

```sh
pnpm install
```

## The commands

```sh
pnpm test        # the suite, and the real gate on a change here
pnpm typecheck   # tsc over the tests and the synced schema
pnpm lint        # eslint over the same
trunk check      # shellcheck, shfmt, prettier, markdownlint, yamllint
```

```sh
# The request body, without making a call — the exact shape the tests validate
# against the engine's own schema.
lib/request-plan.sh --print-body '["unit-tests"]'
```

Point the plugin at another Trunk deployment with `TRUNK_PUBLIC_API_ADDRESS` (a
base address; the endpoint path is part of the contract and is always appended).

## How the tests work, and why they are the gate

The suite is TypeScript, but almost nothing under test is. Every test drives the
real thing out of process:

- **jq programs** run under the _vendored_ jq binary, not a system one, with
  `-f lib/<program>.jq` — so what the test exercises is the file Buildkite ships.
- **The filter** is invoked as `bin/trunk-dynamic-ci-filter`, reading stdin and
  writing stdout, exactly as a customer's pipe does.
- **The hooks** are executed by path, with a hand-built environment. `step` mode
  uses a `touch <marker>` command, so "did the step run" is a fact on the
  filesystem rather than an assertion about a mock.
- **`buildkite-agent` is faked** — `__tests__/support/agent.ts` writes a bash
  script into a temp directory and puts it first on `PATH`, which is what makes
  the YAML branch testable without an agent.
- **The plan server is real** — `__tests__/support/plan-server.ts` binds a
  loopback HTTP server on port 0 and serves plans validated against the shipped
  response schema. No HTTP mocking library is involved.

That design is the reason `pnpm test` means something: a green run says the
shell and the jq still behave, which no amount of linting establishes. Keep new
tests in the same shape — if a change can be verified by running the real script,
run the real script.

**We deliberately do not use [`buildkite/plugin-tester`](https://github.com/buildkite-plugins/buildkite-plugin-tester)
or BATS.** It is the conventional harness for a Buildkite plugin, and the
convention is worth knowing about before deciding against it. The suite above
already executes the real hooks against a real HTTP server with a stubbed agent;
a BATS suite would be a second, weaker harness over exactly that surface, and two
harnesses means a change needs updating in two places or silently only gets
tested in one. We do run [`buildkite/plugin-linter`](https://github.com/buildkite-plugins/buildkite-plugin-linter),
which checks something the vitest suite cannot — that `plugin.yml` and the
README's `plugins:` examples are structurally valid and mutually consistent:

```sh
docker run --rm -v "$PWD:/plugin:ro" buildkite/plugin-linter --id trunk-io/dynamic-ci
```

## The synced schema

`src/schema/` is a projection of Trunk's internal wire contract. **Do not
hand-edit it.** Changing the contract means changing it in the monorepo; a sync
job then opens a pull request here and against
[`trunk-io/dynamic-ci`](https://github.com/trunk-io/dynamic-ci), the Dynamic CI
GitHub Action, which vendors the same copy.

Nothing the plugin _runs_ imports those files — the request body is built in
`lib/request-body.jq`. They exist so the tests can check that body against the
real contract instead of a restatement of it.

`tsconfig.json`'s strictness mirrors the monorepo's on purpose, so a synced file
compiles identically on both sides. Relaxing a flag there desyncs the two copies.

## The vendored jq

`vendor/` holds static jq binaries for the three platforms `lib/jq.sh` resolves,
with upstream's checksums in `vendor/SHA256SUMS`. They are committed rather than
downloaded at hook time: a fetch would put the network on the critical path of
every customer build.

To move to a new jq:

```sh
scripts/update-jq.sh 1.8.1
```

It verifies each download against the checksum file upstream publishes on the
same release, and writes `SHA256SUMS` from those upstream sums rather than from
the bytes it just downloaded — a file that hashed its own downloads would agree
with itself no matter what it had fetched. Then update the version assertion in
`__tests__/vendored-jq.vitest.ts` and run the suite.

## CI

Everything that gates a pull request runs on Buildkite, in `.buildkite/`. The one
GitHub Actions workflow is `release.yml`, which moves a tag.

**Pull requests from forks do not build.** The smoke pipeline needs a real Trunk
API token, this repository is public, and a fork pull request is code we have not
reviewed yet — so `build_pull_request_forks` is off, and a fork PR gets no status
at all. To run CI on an outside contribution, push the commits to a branch in
this repository and open the pull request from there.

## Releasing

1. Draft a GitHub release with a new tag, `vX.Y.Z`, and generate notes.
2. Update the pinned refs in `README.md` if the release is one customers should
   move to.

Tags are immutable as far as customers are concerned — see the Versioning section
of `README.md` for why a moving alias behaves worse on Buildkite than it does on
GitHub Actions.
