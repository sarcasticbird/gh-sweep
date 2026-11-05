# Input is gh api --paginate --slurp, without server-side search filters.
def integer: type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
def login: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*(\\[bot\\])?$");
def identity:
  type == "object" and (.id | integer and . > 0) and
  (.workflow_id | integer and . > 0) and (.run_attempt | integer and . > 0) and
  (.created_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (. as $timestamp | try ((fromdateiso8601 | todateiso8601) == $timestamp) catch false)) and
  has("actor") and (.actor == null or (.actor | type == "object" and has("login") and (.login == null or (.login | login)))) and
  (.status | IN("completed", "queued", "in_progress", "waiting", "pending", "requested")) and
  has("conclusion") and
  (if .status == "completed" then
     (.conclusion | IN("success", "failure", "timed_out", "startup_failure", "cancelled", "neutral", "skipped", "action_required", "stale"))
   else .conclusion == null end);
def allowed:
  .conclusion == "success" or
  ($failed and (.conclusion | IN("failure", "timed_out", "startup_failure"))) or
  ($all and (.conclusion | IN("cancelled", "neutral", "skipped", "action_required", "stale")));
def fingerprint: {id, workflow_id, run_attempt, created_at, status, conclusion, actor: (.actor.login // null)};

if type != "array" or length == 0 then error("missing run pages") else . end
| if all(.[]; type == "object" and (.total_count | integer) and (.workflow_runs | type == "array" and length <= 100))
  then . else error("malformed run page") end
| .[0].total_count as $total
| if all(.[]; .total_count == $total) then . else error("changing run total") end
| [.[].workflow_runs[]] as $runs
| if ($runs | length) != $total or ($runs | unique_by(.id) | length) != $total
  then error("incomplete or duplicate run inventory") else $runs end
| if all(.[]; identity) then . else error("invalid run identity, attribution, timestamp, status or conclusion") end
| . as $runs
| [.[] | select(.status == "completed" and .actor.login != null)
    | select($user == "" or (.actor.login | ascii_downcase) == ($user | ascii_downcase))
    | select(allowed)]
| group_by(.workflow_id)
| map(sort_by(.created_at, .id) | reverse | {kept: .[:$keep], candidates: .[$keep:]})
| {kept: [.[].kept[] | fingerprint], candidates: [.[].candidates[] | fingerprint]}
| . + {skipped: ($runs | length) - (.kept | length) - (.candidates | length), total: ($runs | length)}
