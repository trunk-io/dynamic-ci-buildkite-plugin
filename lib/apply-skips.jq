# Add `skip` to the steps a plan says to skip. JSON in, JSON out, no I/O.
#
# This is the whole mutation. It is deliberately small enough to audit in one
# sitting, because it is the only thing in this plugin that changes what a
# customer's build does.
#
# Five properties, each pinned by a test in `__tests__/apply-skips.vitest.ts`:
#   * only `skip` is ever written — nothing else is added, removed or reordered
#   * a step the plan did not name is emitted unchanged
#   * a customer's own `skip` always wins, including `skip: false`
#   * groups are handled by the same recursion as the top level
#   * a `trigger:` step is never skipped, whatever the plan says

# A trigger step's outcome lives in the build it launches, not this one: skipping
# it means that build never happens, and the ground truth the engine would score
# against is in a trace it never sees. The guard lives here as well as in the key
# walk, so a replayed or hand-assembled plan cannot route around it.
def skippable: .key != null and .trigger == null and (has("skip") | not);

# The non-object guard is the same one `collect-keys.jq` needs, for the same
# reason: a real agent renders `- wait` as the bare string "wait", and `has(...)`
# on a string is an error. A step we cannot index is a step we cannot skip, so
# passing it through untouched is both the safe answer and the correct one.
def apply_skips($skips):
  if type != "object" then . else
    (if has("steps") then .steps |= map(apply_skips($skips)) else . end)
    | if skippable and ($skips[.key] != null)
      then .skip = $skips[.key]
      else . end
  end;

.steps |= map(apply_skips($skips))
