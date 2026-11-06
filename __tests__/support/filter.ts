import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";
import { PLUGIN_ROOT, vendoredJqPath } from "./jq";
import { AGENT_ENV } from "./plan-server";

const execFileAsync = promisify(execFile);

/**
 * Runs the filter with stdin piped in. **Asynchronous on purpose**: the plan
 * server lives on this process's event loop, so a synchronous child would
 * block the loop it needs to answer on — the filter would then wait out curl's
 * whole retry budget and the test would hang rather than fail.
 */
export const runFilter = async (
  input: string,
  env: Readonly<Record<string, string>> = {},
): Promise<{ stdout: string; stderr: string }> => {
  const child = execFileAsync(
    join(PLUGIN_ROOT, "bin/trunk-dynamic-ci-filter"),
    {
      encoding: "utf8",
      env: {
        PATH: process.env["PATH"] ?? "",
        TRUNK_DCI_JQ: vendoredJqPath(),
        ...AGENT_ENV,
        ...env,
      },
    },
  );
  child.child.stdin?.end(input);
  return child;
};
