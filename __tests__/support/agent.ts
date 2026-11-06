import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** How the fake agent answers an interpolating `pipeline upload --dry-run`. */
export interface InterpolatedDryRun {
  /** What it prints; omitted prints nothing. */
  rendered?: unknown;
  /** Seconds it sleeps first, to stand in for a dry-run that hangs. */
  sleepSeconds?: number;
  exitCode?: number;
}

export interface FakeAgent {
  /** A `PATH` with the fake agent in front. */
  path: string;
  /** How many interpolating dry-runs it was asked for, read when called. */
  interpolatingCalls: () => number;
  /** The pipeline the last interpolating dry-run read on stdin. */
  interpolatingInput: () => string;
}

/**
 * A stand-in `buildkite-agent` that answers `pipeline upload --dry-run --format
 * json` with a fixed rendering, and returns a `PATH` with it in front.
 *
 * The filter's YAML branch is the one path that calls the real agent, and it is
 * where the interpolation contract lives — so it needs a test, and a test cannot
 * assume a Buildkite agent is installed on the machine running it. What the
 * agent would have parsed does not matter here: the filter only reads the JSON
 * that comes back.
 *
 * A call without `--no-interpolation` is the matrix read; it answers with
 * `interpolated` when given, else with the same rendering.
 */
export const fakeAgent = (
  rendered: unknown,
  interpolated?: InterpolatedDryRun,
): FakeAgent => {
  const dir = mkdtempSync(join(tmpdir(), "dci-agent-"));
  const calls = join(dir, "interpolating-calls");
  const input = join(dir, "interpolating-input");
  writeFileSync(calls, "");
  writeFileSync(input, "");
  const answer =
    interpolated === undefined
      ? `cat <<'JSON'\n${JSON.stringify(rendered)}\nJSON`
      : [
          `sleep ${String(interpolated.sleepSeconds ?? 0)}`,
          interpolated.rendered === undefined
            ? ":"
            : `cat <<'JSON'\n${JSON.stringify(interpolated.rendered)}\nJSON`,
          `exit ${String(interpolated.exitCode ?? 0)}`,
        ].join("\n");
  writeFileSync(
    join(dir, "buildkite-agent"),
    [
      "#!/usr/bin/env bash",
      'if [[ " $* " == *" --no-interpolation "* ]]; then',
      "cat >/dev/null",
      `cat <<'JSON'\n${JSON.stringify(rendered)}\nJSON`,
      "exit 0",
      "fi",
      `cat >'${input}'`,
      `echo call >>'${calls}'`,
      answer,
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  return {
    path: `${dir}:${process.env["PATH"] ?? ""}`,
    interpolatingCalls: () =>
      readFileSync(calls, "utf8").split("\n").filter(Boolean).length,
    interpolatingInput: () => readFileSync(input, "utf8"),
  };
};

/** {@link fakeAgent}'s `PATH`, for a test that reads nothing else from it. */
export const fakeAgentPath = (rendered: unknown): string =>
  fakeAgent(rendered).path;
