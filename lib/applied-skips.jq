# The build-log summary of what the mutation actually did, ready to print.
#
# Derived by diffing the pipeline against `$before` rather than read off the
# plan, because `apply-skips.jq` declines verdicts the plan carries: a `trigger:`
# step is never skippable, and a `skip:` the customer wrote themselves is never
# overridden. Counting the plan would report steps that are still going to run —
# which nobody notices while the message is only a number, and which is
# immediately wrong once the message names them.
#
# Reasons come from the plan's untruncated `summary`, not from the 70-character
# `skip:` value Buildkite shows, so the log is the fuller of the two.
#
# Both `objects` are there for the reason `collect-keys.jq` spells out: a bare
# `- wait` renders as a string, and indexing a string is an error rather than a
# null. This program's failure is caught and degraded to a generic message, so
# the cost of getting it wrong is only a missing summary — but a missing summary
# on every pipeline containing a `wait` is still wrong.
def walk: objects | .steps[]? | (., walk);
def marked: [walk | objects | select(.key != null and (.skip | type) == "string") | .key];

# Long enough to read a real pipeline's decisions, short enough that a pipeline
# with hundreds of steps does not bury the rest of the log. `debug: true` prints
# the whole plan for anyone who needs it.
def limit: 25;

($before | marked) as $already
| ($plan.jobs | map({ key: .jobKey, value: .summary }) | from_entries) as $why
| marked
| map(select(IN($already[]) | not))
| if length == 0 then
    "--- :trunk: Dynamic CI marked no steps to skip"
  else
    "--- :trunk: Dynamic CI marked \(length) step(s) to skip"
    + ([.[:limit][] | "\n    \(.) — \($why[.] // "no reason given")"] | add)
    + (if length > limit then "\n    … and \(length - limit) more" else "" end)
  end
