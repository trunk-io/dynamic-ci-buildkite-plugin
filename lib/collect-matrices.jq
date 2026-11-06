# Each requested step's `matrix:` block, by step key, for the plan request's
# `matrixBlocks`, plus the keys left out to stay within `$max` bytes.
#
# Same walk and narrowing as `collect-keys.jq`: a keyed, non-trigger step whose
# key was requested. Blocks are added in pipeline order until the next would
# take the serialized object past `$max`; a step left out is decided whole, so
# the cap only costs pruning, never a step.
#
# `$keys` is the request's `jobKeys`, already narrowed by only-keys and
# exclude-keys. `$max` is in UTF-8 bytes of the compact JSON object.
def walk: objects | .steps[]? | (., walk);

# `{` and `}`, then `"key":value` per entry with a comma between.
def entry_bytes: (.key | tojson | utf8bytelength) + 1 + (.value | tojson | utf8bytelength) + 1;

[walk | objects
  | select(.key != null and .trigger == null and .matrix != null)
  | select(.key | IN($keys[]))
  | {key: .key, value: .matrix}]
| reduce .[] as $entry ({blocks: {}, omitted: [], bytes: 1};
    ($entry | entry_bytes) as $bytes
    | if .bytes + $bytes <= $max
      then .blocks[$entry.key] = $entry.value | .bytes += $bytes
      else .omitted += [$entry.key]
      end)
| {blocks, omitted}
