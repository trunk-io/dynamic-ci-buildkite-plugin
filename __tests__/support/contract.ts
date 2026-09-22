import Ajv, { type ValidateFunction } from "ajv";
import type { components } from "../../src/schema/contract.js";
import contract from "../../src/schema/dynamic-ci-contract.json" with { type: "json" };

export type BuildkitePlanRequest =
  components["schemas"]["BuildkitePlanRequest"];
export type CiPlan = components["schemas"]["CiPlan"];

// `strict: false` so Ajv ignores OpenAPI's own annotations (`description`,
// `example`); the schemas themselves are plain JSON Schema.
const ajv = new Ajv({ strict: false, allErrors: true });
ajv.addSchema({ $id: "contract", components: contract.components });

const validator = <T>(name: string): ValidateFunction<T> => {
  const validate = ajv.getSchema<T>(`contract#/components/schemas/${name}`);
  if (validate === undefined) {
    throw new Error(`the contract declares no ${name} schema`);
  }
  return validate;
};

const validateRequest = validator<BuildkitePlanRequest>("BuildkitePlanRequest");
const validatePlan = validator<CiPlan>("CiPlan");

export const isPlanRequest = (value: unknown): boolean =>
  validateRequest(value);

export const parsePlanRequest = (value: unknown): BuildkitePlanRequest => {
  if (!validateRequest(value)) {
    throw new Error(
      `the request body does not satisfy the contract: ${ajv.errorsText(validateRequest.errors)}`,
    );
  }
  return value;
};

export const parsePlan = (plan: CiPlan): CiPlan => {
  if (!validatePlan(plan)) {
    throw new Error(
      `the plan does not satisfy the contract: ${ajv.errorsText(validatePlan.errors)}`,
    );
  }
  return plan;
};
