# The build-log summary of the matrix variations the prune left out, ready to
# print; nothing when it left none out. Derived by diffing the pipeline against
# `$before`, as `applied-skips.jq` is, because `apply-prune.jq` declines what it
# cannot apply exactly.
def walk: objects | .steps[]? | (., walk);
def setup_size: if type == "array" then length elif (.setup | type) == "array" then (.setup | length) else 0 end;
def adjustment_count: if type == "object" then ((.adjustments // []) | length) else 0 end;
def matrices: [walk | objects | select(.key != null and .matrix != null) | { key: .key, value: .matrix }] | from_entries;

($before | matrices) as $old
| [matrices | to_entries[]
    | ($old[.key] // null) as $was
    | select($was != null)
    | {
        key,
        left_out: ((($was | setup_size) - (.value | setup_size))
          + ((.value | adjustment_count) - ($was | adjustment_count)))
      }
    | select(.left_out > 0)]
| if length == 0 then empty
  else
    "--- :trunk: Dynamic CI left out \(map(.left_out) | add) matrix variation(s)"
    + (map("\n    \(.key) — \(.left_out) left out") | add)
  end
