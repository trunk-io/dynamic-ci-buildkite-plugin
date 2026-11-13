# Pass Run Before Queue's dispatch id (`$id`) to the builds trigger steps launch.
# JSON in, JSON out, no I/O.
#
# Trunk sets `TRUNK_RBQ_DISPATCH_ID` in the env of a build it creates, and every
# job of that build sees it — but a child build does not inherit its parent's
# env, so a trigger step carries it on as `build.env.TRUNK_RBQ_DISPATCH_ID`.
#
# Only that one key is ever written. `build` and `build.env` are created when
# absent; a trigger step whose `build` or `build.env` is not an object is left as
# it was rather than replaced. Groups recurse as in `apply-skips.jq`.

def carries_env:
  .trigger != null
  and ((.build // {}) | type) == "object"
  and ((.build.env // {}) | type) == "object";

def apply_dispatch($id):
  if type != "object" then . else
    (if has("steps") then .steps |= map(apply_dispatch($id)) else . end)
    | if carries_env then .build.env.TRUNK_RBQ_DISPATCH_ID = $id else . end
  end;

.steps |= map(apply_dispatch($id))
