import { spawnSync } from "node:child_process";
import { mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { type CiPlan, parsePlanRequest } from "./support/contract";
import { fakeAgent } from "./support/agent";
import { runFilter } from "./support/filter";
import { PLUGIN_ROOT, runJq } from "./support/jq";
import { type CapturedRequest, withPlanServer } from "./support/plan-server";

const MAX_BYTES = 65_536;

const collect = (
  pipeline: unknown,
  keys: readonly string[],
  max = MAX_BYTES,
): unknown =>
  runJq({
    program: "collect-matrices.jq",
    input: pipeline,
    args: [
      "--argjson",
      "keys",
      JSON.stringify(keys),
      "--argjson",
      "max",
      String(max),
    ],
  });

describe("collect-matrices.jq", () => {
  it("takes each requested keyed step's matrix, grouped steps included, in pipeline order", () => {
    expect(
      collect(
        {
          steps: [
            "wait",
            { key: "image", matrix: ["amd64", "arm64"] },
            { label: "unkeyed", matrix: ["a", "b"] },
            { key: "plain", command: "make" },
            {
              group: "tests",
              steps: [
                {
                  key: "unit",
                  matrix: { setup: { os: ["linux", "macos"] } },
                },
                { key: "not-asked", matrix: ["x"] },
              ],
            },
          ],
        },
        ["image", "plain", "unit"],
      ),
    ).toEqual({
      blocks: {
        image: ["amd64", "arm64"],
        unit: { setup: { os: ["linux", "macos"] } },
      },
      omitted: [],
    });
  });

  it("leaves out a step whose block would take the object past the limit, counting UTF-8 bytes", () => {
    const pipeline = {
      steps: [
        { key: "first", matrix: ["é"] },
        { key: "second", matrix: ["b"] },
      ],
    };
    const exact = new TextEncoder().encode(
      JSON.stringify({ first: ["é"], second: ["b"] }),
    ).length;

    expect(collect(pipeline, ["first", "second"], exact)).toEqual({
      blocks: { first: ["é"], second: ["b"] },
      omitted: [],
    });
    expect(collect(pipeline, ["first", "second"], exact - 1)).toEqual({
      blocks: { first: ["é"] },
      omitted: ["second"],
    });
  });
});

const PLAN: CiPlan = {
  jobs: [
    { jobKey: "image", run: true, summary: "runs", signals: [] },
    { jobKey: "unit", run: false, summary: "passed 40/40", signals: [] },
  ],
};

const YAML = "steps:\n  - key: image\n    matrix: [amd64, ${ARM}]\n";
/** What `--no-interpolation` renders: the template is still there. */
const RENDERED = {
  steps: [
    { key: "image", command: "build", matrix: ["amd64", "${ARM}"] },
    { key: "unit", command: "make test" },
  ],
};
const INTERPOLATED = {
  steps: [
    { key: "image", command: "build", matrix: ["amd64", "arm64"] },
    { key: "unit", command: "make test" },
  ],
};

const filterWith = async (
  agent: ReturnType<typeof fakeAgent>,
  {
    input = YAML,
    env = {},
    plan = PLAN,
  }: { input?: string; env?: Record<string, string>; plan?: CiPlan } = {},
) => {
  const captured: CapturedRequest = {};
  let result = { stdout: "", stderr: "" };
  await withPlanServer(plan, captured, async (address) => {
    result = await runFilter(input, {
      TRUNK_PUBLIC_API_ADDRESS: address,
      PATH: agent.path,
      ...env,
    });
  });
  return { ...result, request: parsePlanRequest(captured.received) };
};

/** The uploaded pipeline: the `--no-interpolation` render, with the plan's skip. */
const UPLOADED = {
  steps: [
    { key: "image", command: "build", matrix: ["amd64", "${ARM}"] },
    {
      key: "unit",
      command: "make test",
      skip: "Trunk Dynamic CI: passed 40/40",
    },
  ],
};

describe("the filter's matrix read", () => {
  it("sends each matrix step's block with env values resolved, and uploads the uninterpolated render", async () => {
    const agent = fakeAgent(RENDERED, { rendered: INTERPOLATED });

    const { stdout, request } = await filterWith(agent);

    expect({
      matrixBlocks: request.matrixBlocks,
      uploaded: JSON.parse(stdout),
      calls: agent.interpolatingCalls(),
      read: agent.interpolatingInput(),
    }).toEqual({
      matrixBlocks: { image: ["amd64", "arm64"] },
      uploaded: UPLOADED,
      calls: 1,
      read: YAML,
    });
  });

  it("reads a generated JSON pipeline's matrix values the same way", async () => {
    const agent = fakeAgent(RENDERED, { rendered: INTERPOLATED });
    const input = JSON.stringify(RENDERED);

    const { request } = await filterWith(agent, { input });

    expect({
      matrixBlocks: request.matrixBlocks,
      read: agent.interpolatingInput(),
    }).toEqual({ matrixBlocks: { image: ["amd64", "arm64"] }, read: input });
  });

  it("makes no interpolating dry-run for a pipeline with no requested matrix step", async () => {
    const agent = fakeAgent(RENDERED, { rendered: INTERPOLATED });

    const { request } = await filterWith(agent, {
      env: { BUILDKITE_PLUGIN_DYNAMIC_CI_EXCLUDE_KEYS: "image" },
    });

    expect({
      matrixBlocks: request.matrixBlocks,
      calls: agent.interpolatingCalls(),
    }).toEqual({ matrixBlocks: undefined, calls: 0 });
  });

  it.each([
    { name: "prints nothing", dryRun: {}, log: "could not read matrix values" },
    {
      name: "fails",
      dryRun: { rendered: INTERPOLATED, exitCode: 1 },
      log: "could not read matrix values",
    },
    {
      name: "prints something that is not a pipeline",
      dryRun: { rendered: "nope" },
      log: "could not read matrix values",
    },
  ])(
    "sends no blocks and still applies the plan when the dry-run $name",
    async ({ dryRun, log }) => {
      const agent = fakeAgent(RENDERED, dryRun);

      const { stdout, stderr, request } = await filterWith(agent);

      expect({
        matrixBlocks: request.matrixBlocks,
        uploaded: JSON.parse(stdout),
        logged: stderr.includes(log),
      }).toEqual({ matrixBlocks: undefined, uploaded: UPLOADED, logged: true });
    },
  );

  it("gives up on a dry-run that hangs past 5 s, and still applies the plan", async () => {
    const agent = fakeAgent(RENDERED, {
      rendered: INTERPOLATED,
      sleepSeconds: 30,
    });
    const started = Date.now();

    const { stdout, stderr, request } = await filterWith(agent);

    expect({
      matrixBlocks: request.matrixBlocks,
      uploaded: JSON.parse(stdout),
      logged: stderr.includes("could not read matrix values in 5 s"),
      withinBudget: Date.now() - started < 15_000,
    }).toEqual({
      matrixBlocks: undefined,
      uploaded: UPLOADED,
      logged: true,
      withinBudget: true,
    });
  }, 20_000);

  it("leaves out a step past the 64 KiB limit and names it", async () => {
    const big = Array.from(
      { length: 40 },
      (_, i) => `${String(i)}${"x".repeat(1_000)}`,
    );
    const pipeline = {
      steps: [
        { key: "image", matrix: big },
        { key: "unit", matrix: big },
      ],
    };
    const agent = fakeAgent(pipeline, { rendered: pipeline });

    const { stderr, request } = await filterWith(agent);

    expect({
      steps: Object.keys(request.matrixBlocks ?? {}),
      logged: stderr.includes("sent no matrix for unit: over the 64 KiB limit"),
    }).toEqual({ steps: ["image"], logged: true });
  });
});

/**
 * A `PATH` holding only what `with_timeout` itself calls, so neither
 * `timeout` nor `gtimeout` is found, as on a stock macOS agent.
 */
const pathWithoutTimeout = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "dci-path-"));
  for (const tool of ["cat", "sleep", "mktemp", "rm"]) {
    const found = spawnSync("bash", ["-c", `command -v ${tool}`], {
      encoding: "utf8",
    }).stdout.trim();
    symlinkSync(found, join(dir, tool));
  }
  return dir;
};

const bash = spawnSync("bash", ["-c", "command -v bash"], {
  encoding: "utf8",
}).stdout.trim();

const withTimeout = (command: string, input = "") => {
  const started = Date.now();
  const result = spawnSync(
    bash,
    ["-c", `source "${join(PLUGIN_ROOT, "lib/timeout.sh")}"; ${command}`],
    { input, encoding: "utf8", env: { PATH: pathWithoutTimeout() } },
  );
  return {
    status: result.status,
    stdout: result.stdout,
    elapsedMs: Date.now() - started,
  };
};

describe("with_timeout without timeout or gtimeout", () => {
  it("runs the command on the caller's stdin and returns as soon as it ends", () => {
    const { status, stdout, elapsedMs } = withTimeout(
      'out="$(with_timeout 5 cat)"; printf %s "${out}"',
      "pipeline",
    );

    expect({ status, stdout, fast: elapsedMs < 3_000 }).toEqual({
      status: 0,
      stdout: "pipeline",
      fast: true,
    });
  });

  it("keeps the command's own exit status", () => {
    expect(withTimeout("with_timeout 5 \"${BASH}\" -c 'exit 3'").status).toBe(
      3,
    );
  });

  it("kills a command that runs past the limit, as 124", () => {
    const { status, elapsedMs } = withTimeout("with_timeout 1 sleep 30");

    expect({ status, killedSoon: elapsedMs < 5_000 }).toEqual({
      status: 124,
      killedSoon: true,
    });
  }, 10_000);
});

describe("the filter's matrix prune", () => {
  const pruning: CiPlan = {
    jobs: [
      {
        jobKey: "image",
        run: true,
        summary: "Runs 1 of 2 matrix variations (amd64).",
        signals: [],
        prune: { dropSetup: [1] },
      },
      { jobKey: "unit", run: false, summary: "passed 40/40", signals: [] },
    ],
  };

  it("uploads the step without the pruned value and names it in the log", async () => {
    const agent = fakeAgent(RENDERED, { rendered: INTERPOLATED });

    const { stdout, stderr } = await filterWith(agent, { plan: pruning });

    expect({
      uploaded: JSON.parse(stdout),
      logged: stderr.includes(
        "Dynamic CI left out 1 matrix variation(s)\n    image — 1 left out",
      ),
    }).toEqual({
      uploaded: {
        steps: [
          { key: "image", command: "build", matrix: ["amd64"] },
          UPLOADED.steps[1],
        ],
      },
      logged: true,
    });
  });

  it("runs every variation when it sent no block for the step", async () => {
    const agent = fakeAgent(RENDERED, { exitCode: 1 });

    const { stdout, stderr } = await filterWith(agent, { plan: pruning });

    expect({
      uploaded: JSON.parse(stdout),
      logged: stderr.includes("left out"),
    }).toEqual({ uploaded: UPLOADED, logged: false });
  });
});
