import { execFile } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { PLUGIN_ROOT, vendoredJqPath } from "./support/jq";
import {
  AGENT_ENV,
  type CapturedRequest,
  withPlanServer,
} from "./support/plan-server";

const execFileAsync = promisify(execFile);

const PIPELINE = {
  steps: [{ key: "unit", label: "Unit", command: "make test" }],
};

const PLAN = {
  jobs: [{ jobKey: "unit", run: false, summary: "passed 40/40", signals: [] }],
};

const SKIPPED = {
  steps: [
    {
      key: "unit",
      label: "Unit",
      command: "make test",
      skip: "Trunk Dynamic CI: passed 40/40",
    },
  ],
};

/**
 * A `curl` from before 7.71: its help does not list `--retry-all-errors` and it
 * refuses the flag, as the real one does with exit 2.
 */
const oldCurlPath = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "dci-curl-"));
  const realPath = process.env["PATH"] ?? "";
  writeFileSync(
    join(dir, "curl"),
    [
      "#!/usr/bin/env bash",
      'for arg in "$@"; do',
      '  if [[ ${arg} == --help ]]; then echo " --retry <num>  Retry request"; exit 0; fi',
      '  if [[ ${arg} == --retry-all-errors ]]; then echo "curl: option --retry-all-errors: is unknown" >&2; exit 2; fi',
      "done",
      `PATH=${JSON.stringify(realPath)} exec curl "$@"`,
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  return `${dir}:${realPath}`;
};

const runFilter = async (
  address: string,
  path = process.env["PATH"] ?? "",
): Promise<string> => {
  const child = execFileAsync(
    join(PLUGIN_ROOT, "bin/trunk-dynamic-ci-filter"),
    {
      encoding: "utf8",
      env: {
        PATH: path,
        TRUNK_DCI_JQ: vendoredJqPath(),
        ...AGENT_ENV,
        TRUNK_PUBLIC_API_ADDRESS: address,
      },
    },
  );
  child.child.stdin?.end(JSON.stringify(PIPELINE));
  return (await child).stdout;
};

describe("plan request retries", () => {
  it("retries a connection the server dropped", async () => {
    const captured: CapturedRequest = {};

    await withPlanServer(
      PLAN,
      captured,
      async (address) => {
        expect(JSON.parse(await runFilter(address))).toEqual(SKIPPED);
      },
      { resets: 1 },
    );

    expect(captured.resets).toBe(1);
  });

  it("still plans with a curl too old for --retry-all-errors", async () => {
    const captured: CapturedRequest = {};

    await withPlanServer(PLAN, captured, async (address) => {
      expect(JSON.parse(await runFilter(address, oldCurlPath()))).toEqual(
        SKIPPED,
      );
    });
  });
});
