import { describe, expect, it } from "vitest";
import { runJq } from "./support/jq";
import { RENDERED_PIPELINE } from "./support/pipeline";

const collect = (
  input: unknown,
  only: readonly string[] = [],
  exclude: readonly string[] = [],
): unknown =>
  runJq({
    program: "collect-keys.jq",
    input,
    args: [
      "--argjson",
      "only",
      JSON.stringify(only),
      "--argjson",
      "exclude",
      JSON.stringify(exclude),
    ],
  });

describe("collect-keys.jq", () => {
  it("collects keys at the top level and inside groups", () => {
    expect(collect(RENDERED_PIPELINE)).toEqual([
      "unit",
      "lint",
      "fmt",
      "e2e",
      "smoke",
      "gate-enter",
      "gate-exit",
    ]);
  });

  it("ignores steps with no key, and non-command steps", () => {
    expect(
      collect({
        steps: [{ label: "no key" }, { wait: null }, { block: "go?" }],
      }),
    ).toEqual([]);
  });

  // What the hook branches on to tell the customer to add a `key:` rather than
  // calling the API to be told there is nothing to score.
  it("returns an empty array for a pipeline with no keyed step", () => {
    expect(collect({ steps: [] })).toEqual([]);
  });

  // A trigger step's outcome is in the build it launches, so a verdict here
  // could suppress a build whose result the engine never sees.
  it("excludes a trigger step even though it has a key", () => {
    const keys = collect(RENDERED_PIPELINE);

    expect(keys).not.toContain("downstream");
  });

  it("recurses through nested groups", () => {
    expect(
      collect({
        steps: [
          {
            group: "outer",
            steps: [{ group: "inner", steps: [{ key: "deep" }] }],
          },
        ],
      }),
    ).toEqual(["deep"]);
  });
});

describe("collect-keys.jq with only-keys", () => {
  it("narrows to the named keys", () => {
    expect(collect(RENDERED_PIPELINE, ["unit", "smoke"])).toEqual([
      "unit",
      "smoke",
    ]);
  });

  it("reaches a named key nested in a group", () => {
    expect(collect(RENDERED_PIPELINE, ["e2e"])).toEqual(["e2e"]);
  });

  // An empty list is the default and means no restriction — not "consider
  // nothing", which would silently disable the plugin.
  it("considers everything when the list is empty", () => {
    expect(collect(RENDERED_PIPELINE, [])).toEqual(collect(RENDERED_PIPELINE));
  });

  it("returns nothing when no named key is in the pipeline", () => {
    expect(collect(RENDERED_PIPELINE, ["nope"])).toEqual([]);
  });

  // Narrowing cannot promote a step the walk already refuses.
  it("still excludes a trigger step even when it is named", () => {
    expect(collect(RENDERED_PIPELINE, ["downstream"])).toEqual([]);
  });
});

describe("collect-keys.jq with exclude-keys", () => {
  it("drops the named keys and keeps the rest", () => {
    expect(collect(RENDERED_PIPELINE, [], ["unit", "e2e"])).toEqual([
      "lint",
      "fmt",
      "smoke",
      "gate-enter",
      "gate-exit",
    ]);
  });

  it("drops a named key nested in a group", () => {
    const kept = collect(RENDERED_PIPELINE, [], ["e2e"]);

    expect(kept).not.toContain("e2e");
    expect(kept).toContain("smoke");
  });

  // Exclusion is applied last, so it wins — the safe direction, since this is
  // how a customer says "never skip this".
  it("wins over only-keys when a key is in both", () => {
    expect(collect(RENDERED_PIPELINE, ["unit", "lint"], ["unit"])).toEqual([
      "lint",
    ]);
  });

  it("considers everything when the list is empty", () => {
    expect(collect(RENDERED_PIPELINE, [], [])).toEqual(
      collect(RENDERED_PIPELINE),
    );
  });

  // REGRESSION. A real agent renders the shorthand `- wait` as the bare string
  // "wait" — only the longhand `- wait: ~` gives `{ wait: null }`. jq raises on
  // indexing a string, so before this was guarded the program exited non-zero on
  // any pipeline containing a plain `- wait`, and the plugin fail-opened having
  // decided nothing. Nearly every real pipeline has one.
  //
  // It survived the unit tests because the fixture carried only the object form,
  // and it was caught by the smoke test the first time it ran on a real agent.
  // Both spellings are in the fixture now; these pin the shorthand explicitly.
  describe("a shorthand step that renders as a bare string", () => {
    it("does not stop the walk at the top level", () => {
      expect(
        collect({
          steps: [{ key: "before" }, "wait", { key: "after" }],
        }),
      ).toEqual(["before", "after"]);
    });

    it("does not stop the walk inside a group", () => {
      expect(
        collect({
          steps: [
            { group: "g", steps: [{ key: "child" }, "wait"] },
            { key: "sibling" },
          ],
        }),
      ).toEqual(["child", "sibling"]);
    });

    it("is not itself collected as a key", () => {
      expect(collect({ steps: ["wait", "block"] })).toEqual([]);
    });
  });
});
