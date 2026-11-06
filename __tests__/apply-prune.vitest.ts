import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PLUGIN_ROOT, vendoredJqPath } from "./support/jq";

/** `apply-prune.jq` over a pipeline, with the plan and the blocks the plugin sent. */
const applyPrune = (
  pipeline: unknown,
  plan: unknown,
  sent: Record<string, unknown> | null,
): unknown => {
  const dir = mkdtempSync(join(tmpdir(), "dci-prune-"));
  const sentFile = join(dir, "sent.json");
  writeFileSync(sentFile, sent === null ? "" : JSON.stringify(sent));
  return JSON.parse(
    execFileSync(
      vendoredJqPath(),
      [
        "-c",
        "--argjson",
        "plan",
        JSON.stringify(plan),
        "--slurpfile",
        "sent",
        sentFile,
        "-f",
        join(PLUGIN_ROOT, "lib/apply-prune.jq"),
      ],
      { input: JSON.stringify(pipeline), encoding: "utf8" },
    ),
  );
};

const runs = (jobKey: string, prune?: unknown) => ({
  jobKey,
  run: true,
  summary: "Runs 1 of 2 matrix variations.",
  signals: [],
  ...(prune === undefined ? {} : { prune }),
});

const SHORTHAND = {
  key: "image",
  command: "make image",
  matrix: ["amd64", "${ARM}", "riscv"],
};
const SETUP_LIST = { key: "image", matrix: { setup: ["amd64", "arm64"] } };
const NAMED = {
  key: "unit",
  command: "make test",
  matrix: {
    setup: { os: ["linux", "macos"], arch: ["amd64", "arm64"] },
    adjustments: [{ with: { os: "linux", arch: "arm64" }, soft_fail: true }],
  },
};
const ADJUSTMENT = {
  with: { os: "macos", arch: "amd64" },
  skip: "Trunk Dynamic CI: no changed file has broken it.",
};

describe("apply-prune.jq", () => {
  it("deletes a shorthand matrix's positions, counted in the block sent, from the uninterpolated step", () => {
    expect(
      applyPrune(
        { steps: [SHORTHAND] },
        { jobs: [runs("image", { dropSetup: [1] })] },
        { image: ["amd64", "arm64", "riscv"] },
      ),
    ).toEqual({
      steps: [{ ...SHORTHAND, matrix: ["amd64", "riscv"] }],
    });
  });

  it("deletes positions from a setup list, a repeated value at each of them", () => {
    expect(
      applyPrune(
        { steps: [{ key: "image", matrix: { setup: ["a", "b", "a"] } }] },
        { jobs: [runs("image", { dropSetup: [0, 2] })] },
        { image: { setup: ["a", "b", "a"] } },
      ),
    ).toEqual({ steps: [{ key: "image", matrix: { setup: ["b"] } }] });
  });

  it("appends adjustments after the step's own, unchanged", () => {
    expect(
      applyPrune(
        { steps: [NAMED] },
        { jobs: [runs("unit", { adjustments: [ADJUSTMENT] })] },
        { unit: NAMED.matrix },
      ),
    ).toEqual({
      steps: [
        {
          ...NAMED,
          matrix: {
            ...NAMED.matrix,
            adjustments: [...NAMED.matrix.adjustments, ADJUSTMENT],
          },
        },
      ],
    });
  });

  it("prunes a matrix step inside a group", () => {
    expect(
      applyPrune(
        { steps: [{ group: "Build", steps: [SETUP_LIST] }] },
        { jobs: [runs("image", { dropSetup: [0] })] },
        { image: SETUP_LIST.matrix },
      ),
    ).toEqual({
      steps: [
        {
          group: "Build",
          steps: [{ key: "image", matrix: { setup: ["arm64"] } }],
        },
      ],
    });
  });

  // Each of these leaves the step as written, so it runs every variation.
  it.each([
    {
      name: "the setup list differs in length from the block sent",
      step: SHORTHAND,
      prune: { dropSetup: [1] },
      sent: { image: ["amd64", "arm64"] },
    },
    {
      name: "the plugin sent no block for the step",
      step: SHORTHAND,
      prune: { dropSetup: [1] },
      sent: null,
    },
    {
      name: "a position is past the end",
      step: SHORTHAND,
      prune: { dropSetup: [3] },
      sent: { image: SHORTHAND.matrix },
    },
    {
      name: "every position would be deleted",
      step: SETUP_LIST,
      prune: { dropSetup: [0, 1] },
      sent: { image: SETUP_LIST.matrix },
    },
    {
      name: "positions are for a matrix with named dimensions",
      step: NAMED,
      prune: { dropSetup: [0] },
      sent: { unit: NAMED.matrix },
    },
    {
      name: "adjustments are for a matrix with no dimension names",
      step: SETUP_LIST,
      prune: { adjustments: [ADJUSTMENT] },
      sent: { image: SETUP_LIST.matrix },
    },
    {
      name: "the step would have more than 12 adjustments",
      step: NAMED,
      prune: { adjustments: Array.from({ length: 12 }, () => ADJUSTMENT) },
      sent: { unit: NAMED.matrix },
    },
  ])("leaves the step unchanged when $name", ({ step, prune, sent }) => {
    expect(
      applyPrune({ steps: [step] }, { jobs: [runs(step.key, prune)] }, sent),
    ).toEqual({ steps: [step] });
  });

  it.each([
    {
      name: "the plan skips",
      step: { ...SETUP_LIST, skip: "Trunk Dynamic CI: unchanged" },
      run: false,
    },
    {
      name: "the customer wrote their own skip",
      step: { ...SETUP_LIST, skip: false },
      run: true,
    },
    {
      name: "it is a trigger step",
      step: { ...SETUP_LIST, trigger: "deploy" },
      run: true,
    },
  ])("never touches a step $name", ({ step, run }) => {
    expect(
      applyPrune(
        { steps: [step] },
        { jobs: [{ ...runs("image", { dropSetup: [0] }), run }] },
        { image: SETUP_LIST.matrix },
      ),
    ).toEqual({ steps: [step] });
  });

  it("leaves a pipeline whose plan prunes nothing as it was, steps of every shape included", () => {
    const pipeline = {
      steps: [
        "wait",
        { wait: null },
        SHORTHAND,
        NAMED,
        { key: "plain", command: "true" },
      ],
    };
    expect(
      applyPrune(pipeline, { jobs: [runs("image"), runs("unit")] }, null),
    ).toEqual(pipeline);
  });
});
