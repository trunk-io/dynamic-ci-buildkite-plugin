import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { parsePlanRequest } from "./support/contract";
import { PLUGIN_ROOT, vendoredJqPath } from "./support/jq";

/**
 * A Buildkite agent's environment, as `request-plan.sh` reads it. Built from
 * nothing rather than from `process.env` so the test cannot pass because the
 * machine running it happens to be in CI.
 */
const AGENT_ENV = {
  BUILDKITE_REPO: "git@github.com:trunk-io/trunk2.git",
  BUILDKITE_COMMIT: "9f2c1b7c2b4c9d1e0a3f5b6c7d8e9f0a1b2c3d4e",
  BUILDKITE_BRANCH: "feature/widget-cache",
  BUILDKITE_PULL_REQUEST: "4213",
  BUILDKITE_BUILD_NUMBER: "13083",
  BUILDKITE_RETRY_COUNT: "0",
  BUILDKITE_BUILD_CREATOR: "octocat",
  BUILDKITE_SOURCE: "webhook",
  BUILDKITE_ORGANIZATION_SLUG: "trunk",
  BUILDKITE_PIPELINE_SLUG: "trunk2-pr",
} as const;

interface PrintBodyArgs {
  env?: Readonly<Record<string, string>>;
  cwd?: string;
  jobKeys?: readonly string[];
}

/**
 * A repository with `main` and a feature branch one commit ahead, so the merge
 * base is `main`'s tip — what the script must resolve.
 */
const gitRepoWithBranch = (): { dir: string; mergeBase: string } => {
  const dir = mkdtempSync(join(tmpdir(), "dci-git-"));
  const git = (...args: readonly string[]): string =>
    execFileSync("git", [...args], {
      cwd: dir,
      encoding: "utf8",
      env: {
        PATH: process.env["PATH"] ?? "",
        HOME: dir,
        GIT_AUTHOR_NAME: "t",
        GIT_AUTHOR_EMAIL: "t@example.com",
        GIT_COMMITTER_NAME: "t",
        GIT_COMMITTER_EMAIL: "t@example.com",
      },
    });

  git("init", "--quiet", "--initial-branch=main");
  git("commit", "--quiet", "--allow-empty", "-m", "base");
  const mergeBase = git("rev-parse", "HEAD").trim();
  git("checkout", "--quiet", "-b", "feature");
  git("commit", "--quiet", "--allow-empty", "-m", "ahead");

  return { dir, mergeBase };
};

/**
 * `main` with `keep.txt`, `old.txt` and `gone.txt`, and a feature branch that
 * edits, renames, deletes and adds — plus `extra` more new files, for the cap.
 */
const gitRepoWithChanges = (
  extra = 0,
): { dir: string; mergeBase: string; mainTip: string } => {
  const dir = mkdtempSync(join(tmpdir(), "dci-diff-"));
  const git = (...args: readonly string[]): string =>
    execFileSync("git", [...args], {
      cwd: dir,
      encoding: "utf8",
      env: {
        PATH: process.env["PATH"] ?? "",
        HOME: dir,
        GIT_AUTHOR_NAME: "t",
        GIT_AUTHOR_EMAIL: "t@example.com",
        GIT_COMMITTER_NAME: "t",
        GIT_COMMITTER_EMAIL: "t@example.com",
      },
    });
  const write = (path: string, content: string): void => {
    writeFileSync(join(dir, path), content);
  };

  git("init", "--quiet", "--initial-branch=main");
  write("keep.txt", "a\nb\nc\n");
  write("old.txt", `${Array.from({ length: 20 }, (_u, i) => i).join("\n")}\n`);
  write("gone.txt", "x\ny\n");
  git("add", ".");
  git("commit", "--quiet", "-m", "base");
  const mergeBase = git("rev-parse", "HEAD").trim();

  git("checkout", "--quiet", "-b", "feature");
  write("keep.txt", "a\nB\nc\nd\n");
  git("mv", "old.txt", "new.txt");
  write("new.txt", `${Array.from({ length: 21 }, (_u, i) => i).join("\n")}\n`);
  git("rm", "--quiet", "gone.txt");
  write("added with space.txt", "1\n2\n");
  mkdirSync(join(dir, "many"));
  for (let i = 0; i < extra; i += 1) {
    write(join("many", `f${String(i).padStart(4, "0")}.txt`), "1\n");
  }
  git("add", ".");
  git("commit", "--quiet", "-m", "change");

  // `main` moves on after the branch point, so a direct diff from its tip and
  // a diff from the merge base disagree.
  git("checkout", "--quiet", "main");
  write("main-only.txt", "m\n");
  git("add", ".");
  git("commit", "--quiet", "-m", "main moves on");
  const mainTip = git("rev-parse", "HEAD").trim();
  git("checkout", "--quiet", "feature");

  return { dir, mergeBase, mainTip };
};

/** A directory that is deliberately not a git repository, so `baseSha` is null. */
const nonGitDir = (): string => mkdtempSync(join(tmpdir(), "dci-nogit-"));

const printBody = ({
  env = {},
  cwd = nonGitDir(),
  jobKeys = ["unit", "e2e"],
}: PrintBodyArgs = {}): unknown => {
  const stdout = execFileSync(
    join(PLUGIN_ROOT, "lib/request-plan.sh"),
    ["--print-body", JSON.stringify(jobKeys)],
    {
      cwd,
      encoding: "utf8",
      env: {
        PATH: process.env["PATH"] ?? "",
        TRUNK_DCI_JQ: vendoredJqPath(),
        ...AGENT_ENV,
        ...env,
      },
    },
  );
  return JSON.parse(stdout);
};

describe("the plan request body", () => {
  it("satisfies the published schema", () => {
    expect(() => parsePlanRequest(printBody())).not.toThrow();
  });

  it("maps each field from the agent's environment", () => {
    const body = parsePlanRequest(printBody());

    expect(body).toMatchObject({
      repo: { host: "github.com", owner: "trunk-io", name: "trunk2" },
      commitSha: AGENT_ENV.BUILDKITE_COMMIT,
      branch: "feature/widget-cache",
      prNumber: 4213,
      runId: AGENT_ENV.BUILDKITE_BUILD_NUMBER,
      runAttempt: 1,
      triggeringActor: "octocat",
      eventName: "webhook",
      buildkiteOrganizationSlug: "trunk",
      buildkitePipelineSlug: "trunk2-pr",
      jobKeys: ["unit", "e2e"],
    });
  });

  // `BUILDKITE_RETRY_COUNT` is how many times THIS JOB has been retried, so in
  // step mode two steps of one build report different counts. Deriving the run's
  // attempt from it split one build's plans across several attempts of a run that
  // only ever had one.
  it("reports the same run attempt however often the upload step is retried", () => {
    const body = parsePlanRequest(
      printBody({ env: { BUILDKITE_RETRY_COUNT: "2" } }),
    );

    expect(body.runAttempt).toBe(1);
  });

  it("sends a null prNumber when the build is not a pull request", () => {
    const body = parsePlanRequest(
      printBody({ env: { BUILDKITE_PULL_REQUEST: "false" } }),
    );

    expect(body.prNumber).toBeNull();
  });

  it("sends a null baseSha when there is no base branch to diff against", () => {
    const body = parsePlanRequest(printBody());

    expect(body.baseSha).toBeNull();
  });

  // The only path that actually shells out to git. Worth a real repository: a
  // silently-empty `baseSha` costs the diff-derived signals on every build, and
  // nothing else in the plan would look wrong.
  it("resolves baseSha to the merge base of the PR's target branch", () => {
    const { dir, mergeBase } = gitRepoWithBranch();

    const body = parsePlanRequest(
      printBody({
        cwd: dir,
        env: { BUILDKITE_PULL_REQUEST_BASE_BRANCH: "main" },
      }),
    );

    expect(body.baseSha).toBe(mergeBase);
  });

  it("omits the optional fields rather than sending them empty", () => {
    const body = printBody({
      env: { BUILDKITE_BUILD_CREATOR: "", BUILDKITE_SOURCE: "" },
    });

    expect(body).not.toHaveProperty("triggeringActor");
    expect(body).not.toHaveProperty("eventName");
  });

  it("splits the pull request's labels on commas, keeping their case", () => {
    const body = parsePlanRequest(
      printBody({
        env: { BUILDKITE_PULL_REQUEST_LABELS: "Ready for CI, bug,,size/S " },
      }),
    );

    expect(body.prLabels).toEqual(["Ready for CI", "bug", "size/S"]);
  });

  it("omits prLabels when the pull request has no labels", () => {
    expect(printBody()).not.toHaveProperty("prLabels");
    expect(
      printBody({ env: { BUILDKITE_PULL_REQUEST_LABELS: "" } }),
    ).not.toHaveProperty("prLabels");
  });

  it("splits ignore-signals and drops the empties", () => {
    const body = parsePlanRequest(
      printBody({
        env: {
          BUILDKITE_PLUGIN_DYNAMIC_CI_IGNORE_SIGNALS:
            "estimated-cost, required-check,",
        },
      }),
    );

    expect(body.ignoreSignals).toEqual(["estimated-cost", "required-check"]);
  });

  // An unknown identifier is a 400 from the API, on purpose: a typo fails open
  // loudly rather than silently disabling nothing. So the body must carry it
  // through rather than filtering it out here.
  it("passes an unknown signal identifier through to be rejected", () => {
    const body = printBody({
      env: { BUILDKITE_PLUGIN_DYNAMIC_CI_IGNORE_SIGNALS: "not-a-signal" },
    });

    expect(() => parsePlanRequest(body)).toThrow();
  });
});

describe("the remote parse", () => {
  const repoFor = (remote: string): unknown => {
    const body = printBody({ env: { BUILDKITE_REPO: remote } });
    if (typeof body !== "object" || body === null || !("repo" in body)) {
      throw new Error("no repo in the body");
    }
    return body.repo;
  };

  const EXPECTED = {
    host: "github.com",
    owner: "trunk-io",
    name: "trunk2",
  } as const;

  it("reads an scp-style ssh remote", () => {
    expect(repoFor("git@github.com:trunk-io/trunk2.git")).toEqual(EXPECTED);
  });

  it("reads an https remote", () => {
    expect(repoFor("https://github.com/trunk-io/trunk2.git")).toEqual(EXPECTED);
  });

  it("reads an https remote with no .git suffix", () => {
    expect(repoFor("https://github.com/trunk-io/trunk2")).toEqual(EXPECTED);
  });

  // Takes the LAST `@`, which is the rule ingestion settled on: a token-bearing
  // remote is a real input, and the token itself may contain one.
  it("reads a token-bearing https remote", () => {
    expect(
      repoFor("https://x-access-token:ghs_abc@github.com/trunk-io/trunk2.git"),
    ).toEqual(EXPECTED);
  });

  it("strips a www. prefix, as ingestion does", () => {
    expect(repoFor("https://www.github.com/trunk-io/trunk2.git")).toEqual(
      EXPECTED,
    );
  });

  it("reads a non-GitHub host rather than assuming GitHub", () => {
    expect(repoFor("git@gitlab.com:acme/widgets.git")).toEqual({
      host: "gitlab.com",
      owner: "acme",
      name: "widgets",
    });
  });
});

describe("the changed files", () => {
  const withChanges = (extra = 0, env: Record<string, string> = {}) => {
    const { dir, mergeBase } = gitRepoWithChanges(extra);
    const body = parsePlanRequest(
      printBody({
        cwd: dir,
        env: { BUILDKITE_PULL_REQUEST_BASE_BRANCH: "main", ...env },
      }),
    );
    return { body, mergeBase };
  };

  it("lists every change against the merge base, renames included", () => {
    const { body, mergeBase } = withChanges();

    expect(body.changedFiles).toEqual({
      base: mergeBase,
      totalFiles: 4,
      totalAdditions: 5,
      totalDeletions: 3,
      files: [
        {
          path: "added with space.txt",
          status: "added",
          additions: 2,
          deletions: 0,
        },
        { path: "gone.txt", status: "removed", additions: 0, deletions: 2 },
        { path: "keep.txt", status: "modified", additions: 2, deletions: 1 },
        {
          path: "new.txt",
          previousPath: "old.txt",
          status: "renamed",
          additions: 1,
          deletions: 0,
        },
      ],
    });
  });

  it("caps the list at 200 and keeps the totals over every file", () => {
    const { body } = withChanges(250);

    expect(body.changedFiles).toMatchObject({
      totalFiles: 254,
      totalAdditions: 255,
      totalDeletions: 3,
    });
    expect(body.changedFiles?.files).toHaveLength(200);
  });

  // An empty list would read as "nothing changed". Leaving the field out sends
  // the server to GitHub instead.
  it("is omitted when there is no base to diff against", () => {
    expect(printBody()).not.toHaveProperty("changedFiles");
  });

  it("appears in the debug log as a count, not a list", () => {
    const { dir } = gitRepoWithChanges();
    const { stderr } = spawnSync(
      join(PLUGIN_ROOT, "lib/request-plan.sh"),
      ["--print-body", "[]"],
      {
        cwd: dir,
        encoding: "utf8",
        env: {
          PATH: process.env["PATH"] ?? "",
          TRUNK_DCI_JQ: vendoredJqPath(),
          ...AGENT_ENV,
          BUILDKITE_PULL_REQUEST_BASE_BRANCH: "main",
          BUILDKITE_PLUGIN_DYNAMIC_CI_DEBUG: "true",
        },
      },
    );

    expect(stderr).toContain('"files": "4 files"');
    expect(stderr).not.toContain("keep.txt");
  });

  it("is omitted when git cannot find the base branch", () => {
    const { dir } = gitRepoWithChanges();

    expect(
      printBody({
        cwd: dir,
        env: { BUILDKITE_PULL_REQUEST_BASE_BRANCH: "no-such-branch" },
      }),
    ).not.toHaveProperty("changedFiles");
  });
});

describe("the base", () => {
  const bodyWith = (
    env: (repo: {
      mergeBase: string;
      mainTip: string;
    }) => Record<string, string>,
  ) => {
    const repo = gitRepoWithChanges();
    const body = parsePlanRequest(
      printBody({
        cwd: repo.dir,
        env: { BUILDKITE_PULL_REQUEST_BASE_BRANCH: "main", ...env(repo) },
      }),
    );
    return { ...repo, body };
  };
  const pathsOf = (body: {
    changedFiles?: { files: { path: string; status: string }[] };
  }) => body.changedFiles?.files.map((file) => `${file.status} ${file.path}`);

  it("is the merge base by default, leaving out what main added since", () => {
    const { body, mergeBase } = bodyWith(() => ({}));

    expect(body.baseSha).toBe(mergeBase);
    expect(body.changedFiles?.base).toBe(mergeBase);
    expect(pathsOf(body)).not.toContain("removed main-only.txt");
  });

  // Compared directly, so a file only the named base has reads as removed.
  it("is compared to HEAD directly when base-sha names it", () => {
    const { body, mainTip } = bodyWith(({ mainTip }) => ({
      BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA: mainTip,
    }));

    expect(body.baseSha).toBe(mainTip);
    expect(body.changedFiles?.base).toBe(mainTip);
    expect(pathsOf(body)).toContain("removed main-only.txt");
  });

  it("is read from the variable base-sha-env names", () => {
    const { body, mainTip } = bodyWith(({ mainTip }) => ({
      BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA_ENV: "COMPARISON_BASE",
      COMPARISON_BASE: mainTip,
    }));

    expect(body.baseSha).toBe(mainTip);
  });

  it("prefers base-sha over base-sha-env", () => {
    const { body, mergeBase } = bodyWith(({ mergeBase, mainTip }) => ({
      BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA: mergeBase,
      BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA_ENV: "COMPARISON_BASE",
      COMPARISON_BASE: mainTip,
    }));

    expect(body.baseSha).toBe(mergeBase);
  });

  it.each([
    ["an empty variable", { COMPARISON_BASE: "" }],
    ["something that is not a variable name", {}],
  ])("falls back to the merge base for %s", (_name, extra) => {
    const { body, mergeBase } = bodyWith(() => ({
      BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA_ENV:
        "COMPARISON_BASE" in extra ? "COMPARISON_BASE" : "$(echo x)",
      ...extra,
    }));

    expect(body.baseSha).toBe(mergeBase);
  });

  // A named base git cannot resolve omits the list; the server falls back.
  it("omits the changed files when the named base is not a commit", () => {
    const { dir } = gitRepoWithChanges();

    const body = printBody({
      cwd: dir,
      env: { BUILDKITE_PLUGIN_DYNAMIC_CI_BASE_SHA: "f".repeat(40) },
    });

    expect(body).toMatchObject({ baseSha: "f".repeat(40) });
    expect(body).not.toHaveProperty("changedFiles");
  });
});

describe("the reported commit", () => {
  const commitFor = (env: Record<string, string>): unknown =>
    parsePlanRequest(printBody({ env })).commitSha;

  it("is BUILDKITE_COMMIT by default", () => {
    expect(commitFor({})).toBe(AGENT_ENV.BUILDKITE_COMMIT);
  });

  it("is commit-sha when set", () => {
    expect(
      commitFor({
        BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA: "head",
        BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA_ENV: "PR_HEAD",
        PR_HEAD: "from-env",
      }),
    ).toBe("head");
  });

  it("is read from the variable commit-sha-env names", () => {
    expect(
      commitFor({
        BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA_ENV: "PR_HEAD",
        PR_HEAD: "from-env",
      }),
    ).toBe("from-env");
  });

  it.each([
    ["an empty variable", { PR_HEAD: "" }],
    ["an unset variable", {}],
  ])("falls back to BUILDKITE_COMMIT for %s", (_name, env) => {
    expect(
      commitFor({
        BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA_ENV: "PR_HEAD",
        ...env,
      }),
    ).toBe(AGENT_ENV.BUILDKITE_COMMIT);
  });

  it("falls back to BUILDKITE_COMMIT when commit-sha-env is not a variable name", () => {
    expect(
      commitFor({ BUILDKITE_PLUGIN_DYNAMIC_CI_COMMIT_SHA_ENV: "$(echo x)" }),
    ).toBe(AGENT_ENV.BUILDKITE_COMMIT);
  });
});
