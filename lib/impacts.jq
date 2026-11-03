# The `impacts` option, given as JSON in `$raw`, checked entry by entry.
#
# Prints `{impacts, warnings}`: `impacts` is the list to send, or null when no
# entry is readable, and each warning names an entry it dropped. Dropping an
# entry costs only the impact-reach signal; it never fails the plan.

def max_count: 10000000;
def max_impacts: 8;
def shown: if type == "string" then . else tojson end;
def slug: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$");

# A whole number in range, as a number or (from a quoted YAML value) a digit string.
def count_value:
  if type == "number" and . == floor and . >= 0 and . <= max_count then .
  elif type == "string" and test("^[0-9]{1,8}$") and (tonumber <= max_count) then tonumber
  else null
  end;

def check($index):
  . as $entry
  | "impacts[\($index)]" as $name
  | if type != "object" then
      {warning: "\($name) must be an object with source, count and all; dropping it"}
    elif ((keys - ["source", "count", "all"]) | length) > 0 then
      {warning: "\($name) has unknown keys \(keys - ["source", "count", "all"] | join(", ")); dropping it"}
    elif (.source | slug | not) then
      {warning: "\($name).source must be lowercase letters, digits, '.', '_' or '-', at most 64 characters, not '\(.source // "" | shown)'; dropping it"}
    elif (.all != null and (.all | type) != "boolean") then
      {warning: "\($name).all must be true or false, not '\(.all | shown)'; dropping \(.source)"}
    elif (.all != true and (.count | count_value) == null) then
      {warning: "\($name).count must be a whole number from 0 to \(max_count), not '\(.count // "" | shown)'; dropping \(.source)"}
    else
      {impact: ({source: .source, all: (.all == true)}
        + (if (.count | count_value) == null then {} else {count: (.count | count_value)} end))}
    end;

(try {value: ($raw | fromjson)} catch null) as $read
| $read.value as $parsed
| if $read == null then
    {impacts: null, warnings: ["impacts is not valid JSON; sending no impacts"]}
  elif ($parsed | type) != "array" then
    {impacts: null, warnings: ["impacts is not a JSON list; sending no impacts"]}
  else
    reduce ($parsed | to_entries[]) as {key: $index, value: $entry}
      ({impacts: [], warnings: []};
        ($entry | check($index)) as $checked
        | if $checked.warning then .warnings += [$checked.warning]
          elif any(.impacts[]; .source == $checked.impact.source) then
            .warnings += ["impacts lists \($checked.impact.source) more than once; keeping the first"]
          elif (.impacts | length) >= max_impacts then
            .warnings += ["impacts has more than \(max_impacts) entries; dropping \($checked.impact.source)"]
          else .impacts += [$checked.impact]
          end)
    | if (.impacts | length) == 0 then .impacts = null else . end
  end
