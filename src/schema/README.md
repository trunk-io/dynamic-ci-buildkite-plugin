# `src/schema` — synced wire contract

These files are the request/response contract the plugin speaks to the Trunk
recommendation service. **They are synced from Trunk's internal monorepo, which is
the source of truth — do not hand-edit them here.** A local edit will be
overwritten by the next sync, and worse, will silently disagree with the service.

To change the contract: change it in the monorepo, then re-run the sync. It opens
a pull request against this repository and against
[`trunk-io/dynamic-ci`](https://github.com/trunk-io/dynamic-ci), the Dynamic CI
GitHub Action, which vendors the same copy.

Nothing the plugin _runs_ imports these — the plugin is bash and jq, and builds
its request body in [`lib/request-body.jq`](../../lib/request-body.jq). They exist
so the tests can validate that body, and the plans the fake plan server serves,
against the real contract rather than against a hand-written restatement of it.
That is the whole point: if `request-body.jq` drifts from the contract, a test
fails here rather than a request failing in a customer's build.

`response.ts` intentionally omits the reserved test-level filter fields that exist
in the monorepo copy — test-level recommendations are not part of this plugin.
Zod ignores unknown keys, so a service response still carrying them parses fine.
