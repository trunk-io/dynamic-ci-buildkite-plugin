# Leave the variations a plan prunes out of the matrix steps it runs. JSON in,
# JSON out, no I/O.
#
# A job's `prune` is one of:
#   * `dropSetup`: positions to delete from a matrix with no dimension names
#     (`matrix: [a, b]` or `matrix: {setup: [a, b]}`), counted in the block this
#     plugin sent (`$sent`, the interpolating render). The step being edited is
#     the `--no-interpolation` render, which lists the same values in the same
#     order, so a position names the same value in both.
#   * `adjustments`: entries appended unchanged to a matrix with named
#     dimensions (`matrix: {setup: {os: [...]}}`).
#
# Anything this cannot apply exactly leaves the step as it was, so it runs every
# variation: a setup list whose length differs from the one sent, a position
# past its end, a deletion that would leave no value (Buildkite rejects an empty
# matrix), output of the other kind, or more than 12 adjustments in all.
#
# Only a step the plan runs is touched; a skipped one already has `skip`. A
# `trigger:` step and a step with the customer's own `skip:` are never touched,
# as in `apply-skips.jq`.

def max_adjustments: 12;

def setup_list:
  if type == "array" then .
  elif type == "object" and (.setup | type) == "array" then .setup
  else null
  end;

def without($positions): [to_entries[] | select(.key | IN($positions[]) | not) | .value];

def drop_setup($positions; $sent):
  (.matrix | setup_list) as $list
  | ($sent | setup_list) as $sent_list
  | if $list == null or $sent_list == null
      or ($list | length) != ($sent_list | length)
      or ($positions | any(. < 0 or . >= ($list | length)))
      or ($positions | unique | length) >= ($list | length)
    then .
    elif (.matrix | type) == "array" then .matrix |= without($positions)
    else .matrix.setup |= without($positions)
    end;

def append_adjustments($entries):
  if (.matrix | type) == "object" and (.matrix.setup | type) == "object"
    and ((.matrix.adjustments // []) | length) + ($entries | length) <= max_adjustments
  then .matrix.adjustments = ((.matrix.adjustments // []) + $entries)
  else .
  end;

def prune_step($prune; $sent):
  if ($prune.dropSetup | type) == "array" and ($prune.dropSetup | length) > 0 then
    drop_setup($prune.dropSetup; $sent)
  elif ($prune.adjustments | type) == "array" and ($prune.adjustments | length) > 0 then
    append_adjustments($prune.adjustments)
  else .
  end;

def prunable: .key != null and .trigger == null and .matrix != null and (has("skip") | not);

def apply_prunes($prunes; $sent):
  if type != "object" then . else
    (if has("steps") then .steps |= map(apply_prunes($prunes; $sent)) else . end)
    | if prunable and $prunes[.key] != null
      then prune_step($prunes[.key]; $sent[.key])
      else .
      end
  end;

([$plan.jobs[]? | select(.run == true and (.prune | type) == "object") | { key: .jobKey, value: .prune }]
  | from_entries) as $prunes
| ($sent[0] // {}) as $blocks
| .steps |= map(apply_prunes($prunes; $blocks))
