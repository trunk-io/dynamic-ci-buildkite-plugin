# A served plan as telemetry's `<status> <reason>`, matching the GitHub Action's
# `outcomeForResponse`. Status: 1 success, 2 failed, 3 omitted.

def notice_reason:
  {
    MERGE_QUEUE_BRANCH: "merge_queue_branch",
    ORG_NOT_ENABLED: "org_not_enabled",
    REPO_NOT_ENABLED: "repo_not_enabled",
    WORKFLOW_NOT_RECOGNIZED: "workflow_not_recognized"
  }[.] // "";

(.notice.code // null) as $code
| if $code == "ENGINE_UNAVAILABLE" then { status: 2, reason: "engine_unavailable" }
  elif $code != null and $code != "REPO_IN_SHADOW_MODE" then { status: 3, reason: ($code | notice_reason) }
  elif (.jobs | length) == 0 then { status: 2, reason: "no_verdicts" }
  else { status: 1, reason: "" }
  end
| "\(.status) \(.reason)"
