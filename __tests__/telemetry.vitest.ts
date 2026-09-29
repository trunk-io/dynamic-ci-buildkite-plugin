import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import type { CiPlan } from "./support/contract";
import { PLUGIN_ROOT, vendoredJqPath } from "./support/jq";
import {
  AGENT_ENV,
  type CapturedRequest,
  withPlanServer,
} from "./support/plan-server";
import { decodeTelemetry } from "./support/telemetry";

const execFileAsync = promisify(execFile);

const PIPELINE = {
  steps: [
    { key: "unit", label: "Unit", command: "make test" },
    { key: "e2e", label: "E2E", command: "make e2e" },
  ],
};

const PLAN: CiPlan = {
  jobs: [
    { jobKey: "unit", run: false, summary: "passed 40/40", signals: [] },
    { jobKey: "e2e", run: true, summary: "paths changed", signals: [] },
  ],
};

const PLUGINS = (ref: string): string =>
  JSON.stringify([
    { "github.com/buildkite-plugins/docker-buildkite-plugin#v5.0.0": {} },
    { [`github.com/trunk-io/dynamic-ci-buildkite-plugin#${ref}`]: {} },
  ]);

// Async: the servers live on this event loop, which a synchronous child blocks.
const runFilter = async (
  address: string,
  env: Readonly<Record<string, string>> = {},
): Promise<string> => {
  const child = execFileAsync(
    join(PLUGIN_ROOT, "bin/trunk-dynamic-ci-filter"),
    {
      encoding: "utf8",
      env: {
        PATH: process.env["PATH"] ?? "",
        TRUNK_DCI_JQ: vendoredJqPath(),
        ...AGENT_ENV,
        TRUNK_PUBLIC_API_ADDRESS: address,
        BUILDKITE_PLUGINS: PLUGINS("v0.3.0"),
        ...env,
      },
    },
  );
  child.child.stdin?.end(JSON.stringify(PIPELINE));
  return (await child).stdout;
};

const reportsFor = async (
  plan: CiPlan,
  env: Readonly<Record<string, string>> = {},
  status = 200,
): Promise<{ captured: CapturedRequest; stdout: string }> => {
  const captured: CapturedRequest = {};
  let stdout = "";
  await withPlanServer(
    plan,
    captured,
    async (address) => {
      stdout = await runFilter(address, env);
    },
    { status },
  );
  return { captured, stdout };
};

describe("plan telemetry", () => {
  it("reports a served plan once, as a success, and leaves stdout alone", async () => {
    const { captured, stdout } = await reportsFor(PLAN);

    expect(captured.telemetry).toHaveLength(1);
    const report = decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0));
    expect(report).toMatchObject({
      actionVersion: "buildkite/v0.3.0",
      repo: { host: "github.com", owner: "trunk-io", name: "trunk2" },
      status: 1,
      reason: "",
      jobCount: 2,
    });
    expect(report.durationMs).toBeGreaterThanOrEqual(0);
    expect(JSON.parse(stdout)).toMatchObject({ steps: expect.any(Array) });
  });

  it("names the plugin version on both requests", async () => {
    const { captured } = await reportsFor(PLAN);

    expect(captured.userAgent).toBe("trunk-dynamic-ci-buildkite-plugin/v0.3.0");
    expect(captured.telemetryUserAgent).toBe(
      "trunk-dynamic-ci-buildkite-plugin/v0.3.0",
    );
  });

  it.each([
    [
      "a pinned sha, cut to 7",
      PLUGINS("16de9c7f0a1b2c3d4e5f60718293a4b5c6d7e8f9"),
      "buildkite/16de9c7",
    ],
    ["no plugin list", "", "buildkite/unknown"],
    [
      "a reference with no ref",
      JSON.stringify([{ "trunk-io/dynamic-ci": {} }]),
      "buildkite/unknown",
    ],
  ])("labels the version for %s", async (_name, plugins, label) => {
    const { captured } = await reportsFor(PLAN, { BUILDKITE_PLUGINS: plugins });

    expect(
      decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0)).actionVersion,
    ).toBe(label);
  });

  it("reports a plan with a notice as omitted, with the notice as the reason", async () => {
    const { captured } = await reportsFor({
      jobs: [],
      notice: { code: "ORG_NOT_ENABLED", message: "Not enabled." },
    });

    expect(
      decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0)),
    ).toMatchObject({ status: 3, reason: "org_not_enabled", jobCount: 0 });
  });

  it("reports a fail-open with the failure class that caused it", async () => {
    const { captured, stdout } = await reportsFor(PLAN, {}, 500);

    expect(
      decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0)),
    ).toMatchObject({ status: 2, reason: "http_server_error", jobCount: 0 });
    expect(JSON.parse(stdout)).toEqual(PIPELINE);
  });

  it("sends nothing when TRUNK_DISABLE_TELEMETRY is true", async () => {
    const { captured } = await reportsFor(PLAN, {
      TRUNK_DISABLE_TELEMETRY: " TRUE ",
    });

    expect(captured.telemetry).toBeUndefined();
  });

  it("reports from step mode too", async () => {
    const captured: CapturedRequest = {};
    await withPlanServer(PLAN, captured, async (address) => {
      await execFileAsync(join(PLUGIN_ROOT, "hooks/command"), {
        encoding: "utf8",
        env: {
          PATH: process.env["PATH"] ?? "",
          TRUNK_DCI_JQ: vendoredJqPath(),
          ...AGENT_ENV,
          TRUNK_PUBLIC_API_ADDRESS: address,
          BUILDKITE_PLUGINS: PLUGINS("v0.3.0"),
          BUILDKITE_PLUGIN_DYNAMIC_CI_MODE: "step",
          BUILDKITE_STEP_KEY: "unit",
          BUILDKITE_COMMAND: "true",
        },
      });
    });

    expect(
      decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0)),
    ).toMatchObject({
      actionVersion: "buildkite/v0.3.0",
      status: 1,
      jobCount: 2,
    });
  });
});
