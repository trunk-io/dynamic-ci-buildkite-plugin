# Every skippable step's `key:` in a rendered pipeline, at any nesting depth,
# narrowed by `$only` and then reduced by `$exclude`.
#
# `group:` steps nest their own `steps`, so the walk has to recurse; a flat
# `.steps[]` silently misses every grouped step, which reads as a pipeline whose
# grouped work is simply never scored.
#
# `trigger:` steps are excluded rather than scored: their outcome is in the build
# they launch, so a verdict here could suppress a build whose result the engine
# never sees. `apply-skips.jq` refuses them too — this only avoids asking.
#
# `$only` is an allowlist and `$exclude` a denylist; empty means "no opinion",
# which is the default for both. **Exclusion is applied last and therefore
# wins**, so a key named in both is excluded — the safe direction, since
# `exclude-keys` is how a customer says "never skip this one".
#
# Narrowing happens HERE, on the request, rather than in `apply-skips.jq`: a key
# we never asked about cannot come back in a plan, so one guard is enough. That
# is deliberately weaker than the trigger guard, which is duplicated in both —
# because a trigger skip breaks a build that never happens, while an
# out-of-scope skip only skips a step the customer would have let us consider
# had they not narrowed.
# A step is not always an object: the agent renders the shorthand `- wait` as the
# bare string "wait", where the longhand `- wait: ~` gives `{"wait": null}`.
# Indexing a string raises in jq, so both `objects` are load-bearing — including
# the one in `walk`, because `?` suppresses a failure to iterate, not to index.
def walk: objects | .steps[]? | (., walk);

[walk | objects | select(.key != null and .trigger == null) | .key]
| if ($only | length) == 0 then . else map(select(IN($only[]))) end
| if ($exclude | length) == 0 then . else map(select(IN($exclude[]) | not)) end
