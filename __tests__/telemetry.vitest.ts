import { execFile, execFileSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
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

// The suite itself runs from a git checkout, which the version lookup now reads.
const copyPlugin = (into: string): string => {
  mkdirSync(into, { recursive: true });
  for (const dir of ["bin", "hooks", "lib"]) {
    cpSync(join(PLUGIN_ROOT, dir), join(into, dir), { recursive: true });
  }
  return into;
};

const git = (cwd: string, ...args: string[]): string =>
  execFileSync(
    "git",
    [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "-c",
      "commit.gpgsign=false",
      ...args,
    ],
    { cwd, encoding: "utf8", env: { PATH: process.env["PATH"] ?? "" } },
  ).trim();

const commitAll = (root: string): string => {
  git(root, "init", "-q");
  git(root, "add", ".");
  git(root, "commit", "-qm", "plugin");
  return git(root, "rev-parse", "HEAD");
};

// Async: the servers live on this event loop, which a synchronous child blocks.
const runFilter = async (
  address: string,
  env: Readonly<Record<string, string>> = {},
  root: string = PLUGIN_ROOT,
): Promise<string> => {
  const child = execFileAsync(join(root, "bin/trunk-dynamic-ci-filter"), {
    encoding: "utf8",
    env: {
      PATH: process.env["PATH"] ?? "",
      TRUNK_DCI_JQ: vendoredJqPath(),
      ...AGENT_ENV,
      TRUNK_PUBLIC_API_ADDRESS: address,
      BUILDKITE_PLUGINS: PLUGINS("v0.3.0"),
      ...env,
    },
  });
  child.child.stdin?.end(JSON.stringify(PIPELINE));
  return (await child).stdout;
};

const reportsFor = async (
  plan: CiPlan,
  env: Readonly<Record<string, string>> = {},
  status = 200,
  root: string = PLUGIN_ROOT,
): Promise<{ captured: CapturedRequest; stdout: string }> => {
  const captured: CapturedRequest = {};
  let stdout = "";
  await withPlanServer(
    plan,
    captured,
    async (address) => {
      stdout = await runFilter(address, env, root);
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
    const root = copyPlugin(mkdtempSync(join(tmpdir(), "dci-plain-")));
    const { captured } = await reportsFor(
      PLAN,
      { BUILDKITE_PLUGINS: plugins },
      200,
      root,
    );

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

  it("still reports when the customer's job exports LIB_DIR", async () => {
    const { captured } = await reportsFor(PLAN, { LIB_DIR: "/opt/app/lib" });

    expect(captured.telemetry).toHaveLength(1);
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

// The agent checks a plugin out as a git clone; a copy installed outside the
// `plugins:` list never reaches BUILDKITE_PLUGINS, so that clone is the only
// other place the version is written down.
describe("the version, from the plugin's own checkout", () => {
  const versionFrom = async (
    root: string,
    env: Readonly<Record<string, string>> = {},
  ): Promise<{ label: string; userAgent: string | undefined }> => {
    const { captured } = await reportsFor(
      PLAN,
      { BUILDKITE_PLUGINS: "", ...env },
      200,
      root,
    );
    return {
      label: decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0))
        .actionVersion,
      userAgent: captured.userAgent,
    };
  };

  it("names the commit, cut to 7, on both requests", async () => {
    const root = copyPlugin(mkdtempSync(join(tmpdir(), "dci-clone-")));
    const sha = commitAll(root);

    expect(await versionFrom(root)).toEqual({
      label: `buildkite/${sha.slice(0, 7)}`,
      userAgent: `trunk-dynamic-ci-buildkite-plugin/${sha.slice(0, 7)}`,
    });
  });

  it("names the tag when the checkout is on one", async () => {
    const root = copyPlugin(mkdtempSync(join(tmpdir(), "dci-tag-")));
    commitAll(root);
    git(root, "tag", "v0.1.5");

    expect((await versionFrom(root)).label).toBe("buildkite/v0.1.5");
  });

  it("prefers the ref in the plugins list", async () => {
    const root = copyPlugin(mkdtempSync(join(tmpdir(), "dci-both-")));
    commitAll(root);

    expect(
      (await versionFrom(root, { BUILDKITE_PLUGINS: PLUGINS("v0.3.0") })).label,
    ).toBe("buildkite/v0.3.0");
  });

  it("does not name the commit of a repository the plugin is vendored into", async () => {
    const host = mkdtempSync(join(tmpdir(), "dci-host-"));
    copyPlugin(join(host, "vendor/dynamic-ci"));
    commitAll(host);

    expect((await versionFrom(join(host, "vendor/dynamic-ci"))).label).toBe(
      "buildkite/unknown",
    );
  });

  it("ignores a GIT_DIR the customer's job exports", async () => {
    const root = copyPlugin(mkdtempSync(join(tmpdir(), "dci-own-")));
    const sha = commitAll(root);
    const other = mkdtempSync(join(tmpdir(), "dci-other-"));
    writeFileSync(join(other, "file"), "x");
    commitAll(other);

    expect(
      (await versionFrom(root, { GIT_DIR: join(other, ".git") })).label,
    ).toBe(`buildkite/${sha.slice(0, 7)}`);
  });

  it("still filters and reports when git fails", async () => {
    const root = copyPlugin(mkdtempSync(join(tmpdir(), "dci-badgit-")));
    commitAll(root);
    const bin = mkdtempSync(join(tmpdir(), "dci-git-"));
    writeFileSync(
      join(bin, "git"),
      "#!/usr/bin/env bash\necho 'fatal: broken' >&2\nexit 128\n",
    );
    chmodSync(join(bin, "git"), 0o755);
    const expected = (await reportsFor(PLAN)).stdout;

    const { captured, stdout } = await reportsFor(
      PLAN,
      { BUILDKITE_PLUGINS: "", PATH: `${bin}:${process.env["PATH"] ?? ""}` },
      200,
      root,
    );

    expect(stdout).toBe(expected);
    expect(
      decodeTelemetry(captured.telemetry?.[0] ?? Buffer.alloc(0)),
    ).toMatchObject({
      actionVersion: "buildkite/unknown",
      status: 1,
      jobCount: 2,
    });
  });
});

// `${!name}` on an invalid name abandons the enclosing command: in filter mode
// that skipped the fail-open and emitted an empty pipeline.
describe("a token-env that is not a variable name", () => {
  const BAD_TOKEN_ENV = { BUILDKITE_PLUGIN_DYNAMIC_CI_TOKEN_ENV: "MY-TOKEN" };

  it("passes the pipeline through unchanged in filter mode", async () => {
    const { stdout, captured } = await reportsFor(PLAN, BAD_TOKEN_ENV);

    expect(stdout).toBe(JSON.stringify(PIPELINE));
    expect(captured.telemetry).toBeUndefined();
  });

  it("still runs the step in step mode", async () => {
    const marker = join(mkdtempSync(join(tmpdir(), "dci-token-")), "ran");
    await withPlanServer(PLAN, {}, async (address) => {
      await execFileAsync(join(PLUGIN_ROOT, "hooks/command"), {
        encoding: "utf8",
        env: {
          PATH: process.env["PATH"] ?? "",
          TRUNK_DCI_JQ: vendoredJqPath(),
          ...AGENT_ENV,
          ...BAD_TOKEN_ENV,
          TRUNK_PUBLIC_API_ADDRESS: address,
          BUILDKITE_PLUGIN_DYNAMIC_CI_MODE: "step",
          BUILDKITE_STEP_KEY: "unit",
          BUILDKITE_COMMAND: `touch ${marker}`,
        },
      });
    });

    expect(existsSync(marker)).toBe(true);
  });
});

describe("an unusable temp directory", () => {
  it("still runs the step in step mode", async () => {
    const marker = join(mkdtempSync(join(tmpdir(), "dci-tmp-")), "ran");
    await withPlanServer(PLAN, {}, async (address) => {
      await execFileAsync(join(PLUGIN_ROOT, "hooks/command"), {
        encoding: "utf8",
        env: {
          PATH: process.env["PATH"] ?? "",
          TRUNK_DCI_JQ: vendoredJqPath(),
          ...AGENT_ENV,
          TMPDIR: "/nonexistent",
          TRUNK_PUBLIC_API_ADDRESS: address,
          BUILDKITE_PLUGIN_DYNAMIC_CI_MODE: "step",
          BUILDKITE_STEP_KEY: "unit",
          BUILDKITE_COMMAND: `touch ${marker}`,
        },
      });
    });

    expect(existsSync(marker)).toBe(true);
  });
});
