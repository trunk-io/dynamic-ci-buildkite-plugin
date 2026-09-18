# The smoke test

The plugin, running **as a plugin**, on a real agent, at **the commit under
test**. Everything else in this repository tests the plugin's parts; this is the
only thing that tests it the way a customer uses it.

It could not exist while the plugin lived in a subdirectory of the GitHub
Action's repository: a Buildkite plugin reference resolves a repository, so there
was no commit for a pipeline to point at.

| File             | What it is                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------- |
| `../smoke.yml`   | The one step the registered pipeline uploads. Carries the plugin, pinned to `${BUILDKITE_COMMIT}` |
| `run.sh`         | The assertions, and the thing that uploads the sample pipeline                                    |
| `sample.yml`     | The pipeline the filter is run against                                                            |
| `sample-step.sh` | One sample step: records that it ran, checks the interpolation canary                             |
| `verdict.sh`     | Did what ran agree with what was marked                                                           |

## How it tests _this_ commit

`buildkite-agent pipeline upload` interpolates the YAML **before** plugins are
resolved, so `trunk-io/dynamic-ci#${BUILDKITE_COMMIT}` resolves to the commit the
build is for. Tier 0 of `run.sh` then proves it, by comparing the resolved
plugin's files against the checkout's byte for byte — rather than trusting a
naming convention we do not control.

**This cannot work for a fork pull request:** the sha is not on our remote. Forks
do not build here at all, so nothing is lost.

## What is asserted, and what is deliberately not

Assertions are tiered by what they depend on, because that decides what a failure
means.

- **Tier 0** — the plugin the agent resolved is this commit's code.
- **Tier 1** — invariants that hold whatever the service says. The central one is
  that stripping every `skip` from the before and after documents leaves them
  identical: _the only thing the filter may change is `skip:`_. That is what
  catches a dropped step, a reordered pipeline, a mangled group — without ever
  asserting whether anything was skipped.
- **Tier 2** — the staging deployment answered at all. This one needs care,
  because with no history nothing is skipped, so **a successful round trip and a
  total outage produce byte-identical output.** stderr is the only thing that
  tells them apart, which is why `debug: true` is on and why the fail-open
  markers are listed explicitly in `run.sh`.
- **Tier 3** — _what the service decided._ **Never asserted.** A pipeline with no
  history gets `WORKFLOW_NOT_RECOGNIZED` and nothing is skipped, which is
  correct. Scoring the plugin on the verdict would make this repository's CI fail
  whenever the **service** changed — the exact coupling that giving the plugin
  its own repository was meant to end.

`verdict.sh` is the assertion that survives the service gaining history. For each
keyed step it tests an exclusive or: the step recorded that it ran, **xor** the
filter marked it skipped. Both real bugs fail it; the question of whether
anything was skipped does not arise.

## Operating it

- **Retry the build, not the step.** Step keys are unique per _build_, and
  `run.sh` uploads keyed steps into the build it is already running in. Retrying
  the smoke step alone re-uploads the same keys and fails. The keys cannot be
  randomised instead: Dynamic CI's history is keyed on them, and a fresh key per
  retry would fill the service with garbage.
- **`smoke.yml` has exactly one step, deliberately.** Uploaded steps are inserted
  immediately after the step that uploads them, so the sample lands at the end of
  the tree and nothing can end up blocked behind it. Do not add steps after it.
- **A broken `plugin.yml` fails during plugin _resolution_,** before `run.sh`
  runs, and surfaces as an agent error rather than an assertion failure. Do not
  go hunting for a bug in `run.sh` when that happens.
- **Everything runs, every time, at first.** A new pipeline has no history. That
  is correct and is not a plugin fault.

## Changing it

Run it locally before spending a build on it. `run.sh` needs only a
`buildkite-agent` on PATH and something answering at
`TRUNK_PUBLIC_API_ADDRESS` — both of which can be faked in a few lines, the same
way `__tests__/support/` fakes them for the unit suite. Sabotage the plugin and
confirm the smoke test goes red: a smoke test that cannot fail is not one.
