import { describe, expect, it } from "vitest";
import { runJq } from "./support/jq";
import { RENDERED_PIPELINE } from "./support/pipeline";

const DISPATCH_ID = "3f9d2c1e-7a4b-4e8f-9c2d-5b6a7e8f9a0b";

const applyDispatch = (input: unknown) =>
  runJq({
    program: "apply-rbq-dispatch.jq",
    input,
    args: ["--arg", "id", DISPATCH_ID],
  });

describe("apply-rbq-dispatch.jq", () => {
  it("adds the dispatch id to the trigger step and changes nothing else", () => {
    expect(applyDispatch(RENDERED_PIPELINE)).toEqual({
      steps: RENDERED_PIPELINE.steps.map((step) =>
        typeof step === "object" && "trigger" in step
          ? { ...step, build: { env: { TRUNK_RBQ_DISPATCH_ID: DISPATCH_ID } } }
          : step,
      ),
    });
  });

  it("keeps the trigger step's own build and env keys", () => {
    const step = {
      trigger: "core",
      build: {
        message: "child",
        env: { FOO: "bar" },
        meta_data: { x: "y" },
      },
    };

    expect(applyDispatch({ steps: [step] })).toEqual({
      steps: [
        {
          ...step,
          build: {
            ...step.build,
            env: { FOO: "bar", TRUNK_RBQ_DISPATCH_ID: DISPATCH_ID },
          },
        },
      ],
    });
  });

  it("reaches a trigger step inside a group", () => {
    expect(
      applyDispatch({
        steps: [{ group: "Deploy", steps: [{ trigger: "deploy" }] }],
      }),
    ).toEqual({
      steps: [
        {
          group: "Deploy",
          steps: [
            {
              trigger: "deploy",
              build: { env: { TRUNK_RBQ_DISPATCH_ID: DISPATCH_ID } },
            },
          ],
        },
      ],
    });
  });

  it.each([
    { name: "build is not an object", step: { trigger: "core", build: "x" } },
    {
      name: "build.env is not an object",
      step: { trigger: "core", build: { env: ["FOO=bar"] } },
    },
  ])("leaves a trigger step alone when $name", ({ step }) => {
    expect(applyDispatch({ steps: [step] })).toEqual({ steps: [step] });
  });
});
