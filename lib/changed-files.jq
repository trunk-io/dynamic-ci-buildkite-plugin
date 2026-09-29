# The request's `changedFiles`, from `git diff -z -M --name-status` ($status)
# and `git diff -z -M --numstat` ($numstat) over the same range.
#
# Any line either listing cannot account for is an error, never a dropped file:
# a short list reads as "these files did not change".

def fields($raw): $raw | split("\u0000") | if last == "" then .[:-1] else . end;

# `R100\0old\0new` for a rename, `M\0path` for everything else.
def statuses:
  fields($status) as $f
  | { i: 0, out: [] }
  | until(.i >= ($f | length);
      ($f[.i] | .[0:1]) as $code
      | if $code == "R" or $code == "C" then
          .out += [{ code: $code, previousPath: $f[.i + 1], path: $f[.i + 2] }]
          | .i += 3
        else
          .out += [{ code: $code, path: $f[.i + 1] }]
          | .i += 2
        end)
  | .out;

def lines: if . == "-" then 0 else tonumber end;

# `A\tD\tpath`, or `A\tD\t\0old\0new` for a rename. A binary file counts `-`.
def counts:
  fields($numstat) as $f
  | { i: 0, out: {} }
  | until(.i >= ($f | length);
      ($f[.i] | split("\t")) as $cols
      | if ($cols | length) == 3 and $cols[2] == "" then
          .out[$f[.i + 2]] = { additions: ($cols[0] | lines), deletions: ($cols[1] | lines) }
          | .i += 3
        else
          .out[$cols[2:] | join("\t")] = { additions: ($cols[0] | lines), deletions: ($cols[1] | lines) }
          | .i += 1
        end)
  | .out;

def status_of($code):
  { A: "added", M: "modified", D: "removed", R: "renamed", C: "copied", T: "modified" }[$code]
  // error("unknown git status \($code)");

counts as $counts
| [statuses[]
    | . as $entry
    | ($counts[$entry.path] // error("no line counts for \($entry.path)")) as $lines
    | { path: $entry.path }
    + (if $entry.previousPath then { previousPath: $entry.previousPath } else {} end)
    + { status: status_of($entry.code) }
    + $lines]
| sort_by(.path)
| if length != ($counts | length) then error("the two listings disagree") else . end
| {
    base: $base,
    totalFiles: length,
    totalAdditions: (map(.additions) | add // 0),
    totalDeletions: (map(.deletions) | add // 0),
    files: .[0:$max],
  }
