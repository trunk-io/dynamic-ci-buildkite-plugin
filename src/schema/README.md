# `src/schema` — synced wire contract

The request/response contract the plugin speaks to the Trunk recommendation
service. **Synced from an upstream definition — do not hand-edit it here.** A
local edit is overwritten by the next sync, and worse, silently disagrees with
the service.

To change the contract, change it upstream. The sync opens a pull request here
and against [`trunk-io/dynamic-ci`](https://github.com/trunk-io/dynamic-ci), the
Dynamic CI GitHub Action, which vendors the same copy.

Nothing the plugin _runs_ imports these — the plugin is bash and jq, and builds
its request body in [`lib/request-body.jq`](../../lib/request-body.jq). They
exist so the tests can validate that body, and the plans the fake plan server
serves, against the real contract rather than a restatement of it. If
`request-body.jq` drifts from the contract, a test fails here rather than a
request failing in somebody's build.

`response.ts` omits reserved test-level filter fields that are not part of this
plugin. Zod ignores unknown keys, so a response carrying them still parses.
