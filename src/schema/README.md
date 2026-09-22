# `src/schema` — the synced wire contract

`dynamic-ci-contract.json` is the published OpenAPI contract for the endpoint
this plugin calls, `POST /v2/dynamic-ci/generate-buildkite-plan`. **It is synced
from Trunk's monorepo — do not hand-edit it here.** A local edit is overwritten
by the next sync, and worse, silently disagrees with the API.

To change the contract, change it upstream. The sync opens a pull request here
and against [`trunk-io/dynamic-ci`](https://github.com/trunk-io/dynamic-ci), the
Dynamic CI GitHub Action, which vendors the same file.

`contract.d.ts` is generated from it by `pnpm run generate:schema`
(`openapi-typescript`) and committed; CI regenerates and diffs it.

Nothing the plugin _runs_ reads either file — the plugin is bash and jq, and
builds its request body in [`lib/request-body.jq`](../../lib/request-body.jq).
They exist so the tests can validate that body, and the plans the fake plan
server serves, against the real contract rather than a restatement of it
([`__tests__/support/contract.ts`](../../__tests__/support/contract.ts) compiles
Ajv validators from the JSON). If `request-body.jq` drifts from the contract, a
test fails here rather than a request failing in somebody's build.

The document carries request bodies and `200` responses only. Error envelopes
are deliberately absent: the plugin branches on the HTTP status, and the error
code enum spans every Trunk API product, so carrying it would raise a pull
request here every time an unrelated product added one.
