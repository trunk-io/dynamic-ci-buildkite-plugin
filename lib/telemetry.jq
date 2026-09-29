# A `PlanRequestMetrics` protobuf (trunk1 `services/telemetry/proto/v1/dynamic_ci.proto`),
# printed as `\xHH` escapes for `printf '%b'`. jq cannot write raw bytes itself.
#
# Every string is ASCII, so a character's code is its byte. Anything else is an
# error, and the caller then sends nothing.

def varint: if . < 128 then [.] else [. % 128 + 128] + (. / 128 | floor | varint) end;
def tag($field; $wire): $field * 8 + $wire | varint;
def uint($field): if . > 0 then tag($field; 0) + varint else [] end;
def bytes($field): if length > 0 then tag($field; 2) + (length | varint) + . else [] end;
def string($field):
  if test("^[\\x20-\\x7e]*$") then explode | bytes($field) else error("not ascii") end;
def hex: "0123456789abcdef" as $d | $d[. / 16 | floor:(. / 16 | floor) + 1] + $d[. % 16:. % 16 + 1];

(($repo.host // "" | string(1)) + ($repo.owner // "" | string(2)) + ($repo.name // "" | string(3))) as $repo_bytes
| (($duration_ms / 1000 | floor | uint(1)) + ($duration_ms % 1000 * 1000000 | uint(2))) as $duration_bytes
| ($version | string(1))
  + ($repo_bytes | bytes(2))
  + ($status | uint(3))
  + ($reason | string(4))
  + ($duration_bytes | bytes(6))
  + ($job_count | uint(7))
| map("\\x" + hex)
| join("")
