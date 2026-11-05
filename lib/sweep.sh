# shellcheck shell=bash
# All discovery and validation finish before the first product effect. Plans are
# JSON lines, not shell commands; candidate data is never evaluated as code.

api() { gh api "$@"; }

array_pages() {
  local pages
  pages="$(api "$1" --paginate --slurp)" || return 1
  jq -ce 'if type == "array" and length > 0 and all(.[]; type == "array" and length <= 100)
    then add else error("invalid array pagination") end' <<< "$pages"
}

skip_category() {
  jq -nc --arg category "$1" --arg reason "$2" '{kind:"skip", category:$category, reason:$reason}' >> "$PLAN"
}

run_plan() {
  local repo="$1" pages selected
  # No actor/status/created search: those filters impose a 1,000-result cap.
  pages="$(api "repos/$repo/actions/runs?per_page=100" --paginate --slurp)" || return 1
  selected="$(jq -ce --arg user "$SELECTED_USER" --argjson keep "$KEEP_RUNS" \
    --argjson all "$ALL" --argjson failed "$INCLUDE_FAILED" -f "$SWEEP_LIB/runs.jq" <<< "$pages")" || return 1
  jq -c --arg repo "$repo" '. as $p |
    {kind:"run-summary",repo:$repo,total:.total,retained:(.kept|length),skipped:.skipped,candidates:(.candidates|length)},
    (.kept[] | {kind:"kept-run",repo:$repo,id:.id}),
    (.candidates[] | {kind:"run",repo:$repo,id:.id,expected:.})' <<< "$selected" >> "$PLAN"
}

cache_plan() {
  local repo="$1" pages caches branches ref id number state
  pages="$(api "repos/$repo/actions/caches?per_page=100" --paginate --slurp)" || return 1
  caches="$(jq -ce '
    def integer: type == "number" and floor == . and . >= 0 and . <= 9007199254740991;
    if type != "array" or length == 0 or any(.[]; (.total_count|integer|not) or (.actions_caches|type) != "array" or (.actions_caches|length) > 100)
    then error("invalid cache pages") else . end |
    .[0].total_count as $n | if all(.[]; .total_count == $n) then [.[].actions_caches[]] else error("changing cache total") end |
    if length != $n or (unique_by(.id)|length) != $n then error("incomplete cache inventory") else . end |
    if all(.[]; (.id|integer and . > 0) and
      (.ref|type == "string" and length > 0 and (test("[\\x00-\\x20]")|not) and . != "refs/heads/"))
    then . else error("invalid cache") end' <<< "$pages")" || return 1
  branches="$(array_pages "repos/$repo/branches?per_page=100")" || return 1
  jq -e 'all(.[]; .name|type == "string" and length > 0) and (length == (unique_by(.name)|length))' <<< "$branches" >/dev/null || return 1
  while IFS= read -r cache; do
    ref="$(jq -r .ref <<< "$cache")"; id="$(jq -r .id <<< "$cache")"
    if [[ "$ref" == refs/heads/* ]]; then
      jq -e --arg branch "${ref#refs/heads/}" 'any(.[]; .name == $branch)' <<< "$branches" >/dev/null && continue
    elif [[ "$ref" =~ ^refs/pull/([1-9][0-9]*)/(merge|head)$ ]]; then
      number="${BASH_REMATCH[1]}"
      state="$(api "repos/$repo/pulls/$number")" || return 1
      jq -e '.state == "open" or .state == "closed"' <<< "$state" >/dev/null || return 1
      [[ "$(jq -r .state <<< "$state")" == open ]] && continue
    else
      continue
    fi
    jq -nc --arg repo "$repo" --argjson id "$id" --arg ref "$ref" '{kind:"cache",repo:$repo,id:$id,ref:$ref}' >> "$PLAN"
  done < <(jq -c '.[]' <<< "$caches")
}

notification_plan() {
  local repo="$1" notifications
  notifications="$(array_pages "repos/$repo/notifications?all=false&per_page=100")" || return 1
  jq -e 'all(.[]; .id|type == "string" and test("^[0-9]+$"))' <<< "$notifications" >/dev/null || return 1
  jq -c --arg repo "$repo" '.[] | {kind:"notification",repo:$repo,id:.id}' <<< "$notifications" >> "$PLAN"
}

comment_plan() {
  local repo="$1" cursor="" response nodes next seen='[]' seen_ids='[]' cursor_args=()
  while :; do
    cursor_args=()
    [[ -z "$cursor" ]] || cursor_args=(-f "cursor=$cursor")
    # GraphQL variables must reach GitHub literally, not expand in Bash.
    # shellcheck disable=SC2016
    response="$(api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!,$cursor:String) {
        repository(owner:$owner,name:$repo) { pullRequest(number:$pr) {
          reviewThreads(first:100,after:$cursor) {
            nodes { id isResolved } pageInfo { hasNextPage endCursor }
          }
        } }
      }' -f owner="${repo%/*}" -f repo="${repo#*/}" -F pr="$PR_NUMBER" "${cursor_args[@]}")" || return 1
    nodes="$(jq -ce 'if (.errors // [] | length) > 0 then error("GraphQL errors") else .data.repository.pullRequest.reviewThreads end |
      if (.nodes|type) != "array" or (.pageInfo.hasNextPage|type) != "boolean" or
        any(.nodes[]; (.id|type) != "string" or (.id|length) == 0 or (.isResolved|type) != "boolean")
      then error("invalid review threads") else . end' <<< "$response")" || return 1
    seen_ids="$(jq -c --argjson seen "$seen_ids" '$seen + [.nodes[].id] |
      if length == (unique|length) then . else error("duplicate review-thread identity") end' <<< "$nodes")" || return 1
    jq -c --arg repo "$repo" '.nodes[] | select(.isResolved == false) | {kind:"comment",repo:$repo,id:.id}' <<< "$nodes" >> "$PLAN"
    [[ "$(jq -r .pageInfo.hasNextPage <<< "$nodes")" == false ]] && break
    next="$(jq -er '.pageInfo.endCursor | select(type == "string" and length > 0)' <<< "$nodes")" || return 1
    jq -e --arg c "$next" 'index($c) == null' <<< "$seen" >/dev/null || { echo 'error: repeated review cursor' >&2; return 1; }
    seen="$(jq -c --arg c "$next" '. + [$c]' <<< "$seen")"; cursor="$next"
  done
}

worktrees() {
  local dir="$1" token path="" branch="" locked=false prunable=false valid=false count=0 result=0
  local inventory
  inventory="$(mktemp)" || return 1
  git -C "$dir" worktree list --porcelain -z > "$inventory" || { rm -f "$inventory"; return 1; }
  while IFS= read -r -d '' token; do
    case "$token" in
      worktree\ *) path="${token#worktree }" ;;
      HEAD\ *|bare) valid=true ;;
      branch\ refs/heads/*) branch="${token#branch refs/heads/}" ;;
      locked*) locked=true ;;
      prunable*) prunable=true ;;
      '')
        if [[ "$valid" == false || "$path" != /* ]]; then result=1; break; fi
        jq -nc --arg path "$path" --arg branch "$branch" --argjson locked "$locked" --argjson prunable "$prunable" \
          '{path:$path,branch:$branch,locked:$locked,prunable:$prunable}'
        count=$((count+1))
        path=""; branch=""; locked=false; prunable=false; valid=false ;;
    esac
  done < "$inventory"
  rm -f "$inventory"
  [[ "$count" -gt 0 && -z "$path" && "$result" -eq 0 ]]
}

branch_unlocked() {
  local dir="$1" branch="$2" status flag config_status
  is_protected_branch "$branch" && return 1
  [[ -n "${DEFAULT_BRANCH:-}" && "$branch" == "$DEFAULT_BRANCH" ]] && return 1
  for flag in gh-poi-locked gh-poi-protected; do
    config_status=0
    status="$(git -C "$dir" config --type=bool --get "branch.$branch.$flag")" || config_status=$?
    [[ "$config_status" -le 1 ]] || return 1
    [[ "$status" == true ]] && return 1
  done
  return 0
}

local_safe() {
  local dir="$1" branch="$2" trees="$3" wt path status
  branch_unlocked "$dir" "$branch" || return 1
  while IFS= read -r wt; do
    [[ "$(jq -r .branch <<< "$wt")" == "$branch" ]] || continue
    path="$(jq -r .path <<< "$wt")"
    [[ "$path" == "$dir" ]] && return 1
    [[ "$(jq -r '.locked or .prunable' <<< "$wt")" == true ]] && return 1
    status="$(git --no-optional-locks -C "$path" status --porcelain --untracked-files=all)" || return 1
    [[ -n "$status" ]] && return 1
  done <<< "$trees"
  return 0
}

branch_plan() {
  local repo="$1" dir="$2" pulls remote locals trees branch oid matches selector="$SELECTED_USER"
  local wt path origin origin_repo upstream push_origin DEFAULT_BRANCH
  origin="$(git -C "$dir" remote get-url origin)" || return 1
  case "$origin" in
    https://github.com/*) origin_repo="${origin#https://github.com/}" ;;
    git@github.com:*) origin_repo="${origin#git@github.com:}" ;;
    ssh://git@github.com/*) origin_repo="${origin#ssh://git@github.com/}" ;;
    *) echo 'error: cannot verify origin repository identity' >&2; return 1 ;;
  esac
  origin_repo="${origin_repo%.git}"
  [[ "${origin_repo,,}" == "${repo,,}" ]] || { echo 'error: origin does not match selected GitHub repository' >&2; return 1; }
  if [[ "$COMMAND" != local && "$COMMAND" != orphans ]]; then
    push_origin="$(git -C "$dir" remote get-url --push --all origin)" || return 1
    [[ "$push_origin" == "$origin" ]] || { echo 'error: distinct or multiple origin push URLs are unsupported' >&2; return 1; }
  fi
  DEFAULT_BRANCH="$(cd "$dir" && gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)" || return 1
  [[ -n "$DEFAULT_BRANCH" && "$DEFAULT_BRANCH" != null ]] || { echo 'error: missing default branch identity' >&2; return 1; }
  pulls="$(array_pages "repos/$repo/pulls?state=all&per_page=100")" || return 1
  jq -e 'all(.[]; (.number|type == "number" and . > 0 and floor == .) and has("merged_at") and
    (.merged_at == null or (.merged_at|type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
    (.state|IN("open","closed")) and (.head.ref|type == "string") and
    (.head|has("repo")) and (.head.repo == null or (.head.repo.full_name|type == "string")) and
    (.head.sha|type == "string" and test("^[0-9a-f]{40,64}$")) and has("user") and
    (.user == null or (.user|has("login") and (.login == null or (.login|type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*(\\[bot\\])?$")))))) and
    (length == (unique_by(.number)|length))' <<< "$pulls" >/dev/null || { echo 'error: invalid PR attribution/schema' >&2; return 1; }
  trees="$(worktrees "$dir")" || return 1
  locals="$(git -C "$dir" for-each-ref --format='%(refname:short)%09%(objectname)' refs/heads)" || return 1
  remote="$(git -C "$dir" ls-remote --heads origin)" || return 1
  if [[ -z "$selector" && "$ALL" == false && "$COMMAND" != local && "$COMMAND" != orphans ]]; then
    selector="$(api user --jq .login)" || return 1
    [[ "$selector" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$ ]] || return 1
  fi
  if [[ "$COMMAND" != remote ]]; then
    while IFS=$'\t' read -r branch oid; do
      [[ -z "$branch" ]] && continue
      local_safe "$dir" "$branch" "$trees" || { skip_category "local branch $repo:$branch" 'protected, sweep root, locked, dirty or unreadable worktree'; continue; }
      matches="$(jq -c --arg branch "$branch" '[.[] | select(.head.ref == $branch)]' <<< "$pulls")"
      if [[ "$COMMAND" == orphans ]] || [[ "$COMMAND" == all && "$(jq length <<< "$matches")" -eq 0 ]]; then
        [[ -n "$SELECTED_USER" ]] && continue
        # An orphan must have no PR at all and no remote tracking or remote head.
        [[ "$(jq length <<< "$matches")" -eq 0 ]] || continue
        upstream="$(git -C "$dir" for-each-ref --format='%(upstream)' "refs/heads/$branch")" || return 1
        [[ -z "$upstream" ]] || continue
        # Include the final record boundary so topic-extra/child cannot match topic.
        [[ "$remote"$'\n' == *$'\t'"refs/heads/$branch"$'\n'* ]] && continue
      else
        [[ "$COMMAND" == orphans ]] && continue
        matches="$(jq -c --arg oid "$oid" --arg user "$SELECTED_USER" --arg repo "$repo" '
          if any(.[]; .state == "open") then [] else
          [.[] | select(.head.sha == $oid and .head.repo.full_name == $repo)] |
          if any(.[]; .user.login == null) or ([.[].user.login|ascii_downcase]|unique|length) != 1 then [] else
          [.[] | select(.merged_at != null) |
            select($user == "" or (.user.login|ascii_downcase) == ($user|ascii_downcase))] end end' <<< "$matches")"
        [[ "$(jq length <<< "$matches")" -gt 0 ]] || continue
      fi
      while IFS= read -r wt; do
        [[ "$(jq -r .branch <<< "$wt")" == "$branch" ]] || continue
        path="$(jq -r .path <<< "$wt")"
        jq -nc --arg repo "$repo" --arg dir "$dir" --arg branch "$branch" --arg oid "$oid" --arg path "$path" --arg default "$DEFAULT_BRANCH" \
          '{kind:"worktree",repo:$repo,dir:$dir,branch:$branch,oid:$oid,path:$path,default_branch:$default}' >> "$PLAN"
      done <<< "$trees"
      jq -nc --arg repo "$repo" --arg dir "$dir" --arg branch "$branch" --arg oid "$oid" --arg default "$DEFAULT_BRANCH" \
        '{kind:"local",repo:$repo,dir:$dir,branch:$branch,oid:$oid,default_branch:$default}' >> "$PLAN"
    done <<< "$locals"
  fi
  if [[ "$COMMAND" != local && "$COMMAND" != orphans ]]; then
    while IFS=$'\t' read -r oid branch; do
      [[ "$branch" == refs/heads/* ]] || continue
      branch="${branch#refs/heads/}"
      branch_unlocked "$dir" "$branch" || continue
      matches="$(jq -c --arg branch "$branch" --arg oid "$oid" --arg repo "$repo" --arg user "$selector" \
        '[.[] | select(.head.ref == $branch and .head.repo.full_name == $repo)] |
        if any(.[]; .state == "open") then [] else
        [.[] | select(.head.sha == $oid)] |
        if any(.[]; .user.login == null) or ([.[].user.login|ascii_downcase]|unique|length) != 1 then [] else
        [.[] | select(.merged_at != null) |
          select($user == "" or (.user.login|ascii_downcase) == ($user|ascii_downcase))] end end' <<< "$pulls")"
      [[ "$(jq length <<< "$matches")" -gt 0 ]] || continue
      jq -nc --arg repo "$repo" --arg dir "$dir" --arg branch "$branch" --arg oid "$oid" --arg origin "$origin" --arg default "$DEFAULT_BRANCH" \
        '{kind:"remote",repo:$repo,dir:$dir,branch:$branch,oid:$oid,origin:$origin,default_branch:$default}' >> "$PLAN"
    done <<< "$remote"
  fi
}

build_plan() {
  local directory="$1" repo_dir repo dirs
  PLAN="$2"
  : > "$PLAN"
  if [[ -n "$SELECTED_USER" ]]; then
    skip_category caches 'not enumerated: reliable cache-owner attribution unavailable'
    skip_category notifications 'not enumerated: authenticated caller scope is not selected-user attribution'
    skip_category 'orphan branches' 'not enumerated: no reliable PR-author attribution'
    skip_category 'worktree metadata' 'not enumerated: repository-wide metadata has no reliable selected-user owner'
    skip_category comments 'not enumerated: reliable review-thread attribution unsupported'
    case "$COMMAND" in caches|notifications|orphans|comments) return 0 ;; esac
  else
    case "$COMMAND" in all|branches|local)
      skip_category 'worktree metadata' 'not enumerated: repository-wide prune cannot be bounded to captured records' ;;
    esac
  fi
  dirs="$(cd "$directory" && discover_repos)" || return 1
  while IFS= read -r repo_dir; do
    [[ -n "$repo_dir" ]] || return 1
    repo="$(cd "$repo_dir" && gh repo view --json nameWithOwner --jq .nameWithOwner)" || return 1
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'error: invalid repository identity' >&2; return 1; }
    case "$COMMAND" in all|branches|local|remote|orphans) branch_plan "$repo" "$repo_dir" || return 1 ;; esac
    case "$COMMAND" in all|runs) run_plan "$repo" || return 1 ;; esac
    case "$COMMAND" in all|caches) [[ -n "$SELECTED_USER" ]] || cache_plan "$repo" || return 1 ;; esac
    case "$COMMAND" in all|notifications) [[ -n "$SELECTED_USER" ]] || notification_plan "$repo" || return 1 ;; esac
    [[ "$COMMAND" != comments ]] || comment_plan "$repo" || return 1
  done <<< "$dirs"
  # Duplicated API identities indicate an untrustworthy inventory, not more work.
  jq -se 'map(select(.kind | IN("run","cache","notification","comment","local","remote","worktree"))) |
    length == (unique_by([.kind,.repo,.id,.branch,.path])|length)' "$PLAN" >/dev/null
}

show_plan() {
  jq -r 'if .kind == "skip" then "Skipped category: \(.category) - \(.reason)"
    elif .kind == "run-summary" then "Runs \(.repo): total=\(.total) retained=\(.retained) skipped=\(.skipped) candidates=\(.candidates)"
    elif .kind == "kept-run" then "Retained run: \(.repo)/actions/runs/\(.id)"
    else "Candidate: " + (. | tojson) end' "$1"
}

effect() {
  local action="$1" kind repo id dir branch oid path current trees DEFAULT_BRANCH
  kind="$(jq -r .kind <<< "$action")"; repo="$(jq -r .repo <<< "$action")"; id="$(jq -r .id <<< "$action")"
  dir="$(jq -r .dir <<< "$action")"; branch="$(jq -r .branch <<< "$action")"; oid="$(jq -r .oid <<< "$action")"; path="$(jq -r .path <<< "$action")"
  DEFAULT_BRANCH="$(jq -r '.default_branch // ""' <<< "$action")"
  case "$kind" in
    run)
      current="$(api "repos/$repo/actions/runs/$id")" || return 1
      jq -nc --argjson run "$current" '[{total_count:1,workflow_runs:[$run]}]' |
        jq -e --arg user "$SELECTED_USER" --argjson keep 1 --argjson all "$ALL" \
          --argjson failed "$INCLUDE_FAILED" -f "$SWEEP_LIB/runs.jq" >/dev/null || return 1
      jq -e --argjson expected "$(jq .expected <<< "$action")" \
        '{id,workflow_id,run_attempt,created_at,status,conclusion,actor:(.actor.login // null)} == $expected' <<< "$current" >/dev/null || return 2
      api --method DELETE "repos/$repo/actions/runs/$id" >/dev/null || return 1 ;;
    cache) api --method DELETE "repos/$repo/actions/caches/$id" >/dev/null || return 1 ;;
    notification)
      api --method PATCH "notifications/threads/$id" >/dev/null || return 1
      api --method DELETE "notifications/threads/$id" >/dev/null || return 1 ;;
    comment)
      # shellcheck disable=SC2016
      current="$(api graphql -f query='mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { id isResolved } } }' -f id="$id")" || return 1
      jq -e --arg id "$id" '(.errors // [] | length) == 0 and .data.resolveReviewThread.thread.id == $id and .data.resolveReviewThread.thread.isResolved == true' <<< "$current" >/dev/null || return 1 ;;
    worktree|local)
      current="$(git -C "$dir" rev-parse --verify "refs/heads/$branch")" || return 2
      [[ "$current" == "$oid" ]] || return 2
      trees="$(worktrees "$dir")" || return 1
      local_safe "$dir" "$branch" "$trees" || return 2
      if [[ "$kind" == worktree ]]; then
        jq -se --arg path "$path" --arg branch "$branch" 'any(.[]; .path == $path and .branch == $branch)' <<< "$trees" >/dev/null || return 2
        git -c status.showUntrackedFiles=all -C "$dir" worktree remove -- "$path" || return 1
      else
        jq -se --arg branch "$branch" 'all(.[]; .branch != $branch)' <<< "$trees" >/dev/null || return 2
        git -C "$dir" update-ref -d "refs/heads/$branch" "$oid" || return 1
      fi ;;
    remote)
      current="$(git -C "$dir" remote get-url --push --all origin)" || return 1
      [[ "$current" == "$(jq -r .origin <<< "$action")" ]] || return 2
      branch_unlocked "$dir" "$branch" || return 2
      git -C "$dir" push "--force-with-lease=refs/heads/$branch:$oid" origin ":refs/heads/$branch" || return 1 ;;
    *) echo "error: unsupported effect $kind" >&2; return 1 ;;
  esac
}

safe_sweep() (
  export GIT_OPTIONAL_LOCKS=0
  local directory="$PWD" temporary plan fresh candidates count answer action status completed=0 skipped=0 failed=0
  if ! command -v gh >/dev/null || ! command -v jq >/dev/null; then
    echo 'error: gh and jq are required (install explicitly)' >&2; return 1
  fi
  umask 077
  temporary="$(mktemp -d)"
  trap 'rm -rf "$temporary"' EXIT
  export TMPDIR="$temporary"
  plan="$temporary/plan"; fresh="$temporary/fresh"; candidates="$temporary/candidates"
  [[ "$VERBOSE" == false ]] || echo "Planning command=$COMMAND depth=$DEPTH; no delegates or preparation writes"
  build_plan "$directory" "$plan" || { echo 'error: incomplete/invalid plan; no effects performed' >&2; return 1; }
  show_plan "$plan"
  jq -c 'select(.kind | IN("run","cache","notification","comment","local","remote","worktree"))' "$plan" > "$candidates"
  count="$(jq -s length "$candidates")"
  echo "Plan: $count candidates"
  if [[ "$DRY_RUN" == true ]]; then echo 'Dry run: no effects performed'; return 0; fi
  if [[ "$count" -eq 0 ]]; then echo 'No matches; no effects performed'; return 0; fi
  if [[ "$AUTO" == false ]]; then
    if [[ ! -t 0 ]]; then echo 'Refused: noninteractive input requires --auto; no effects performed' >&2; return 1; fi
    read -rp 'Execute exactly this plan? [y/N] ' answer || answer=""
    if [[ "$answer" != y && "$answer" != Y && "$answer" != yes ]]; then echo 'Refused; no effects performed'; return 0; fi
  else
    echo 'Auto: executing displayed candidates without waiting for confirmation'
  fi
  # Re-enumerate before any effect. Intersect whole action identities, never add
  # new candidates or replace a captured identity following confirmation.
  build_plan "$directory" "$fresh" || { echo 'error: revalidation failed; no effects performed' >&2; return 1; }
  while IFS= read -r action; do
    if ! jq -se --argjson action "$action" 'any(.[]; . == $action)' "$fresh" >/dev/null; then
      echo "Skipped changed eligibility: $action"; skipped=$((skipped+1)); continue
    fi
    status=0
    effect "$action" || status=$?
    case "$status" in
      0) completed=$((completed+1)); echo "Completed: $action" ;;
      2) skipped=$((skipped+1)); echo "Skipped changed eligibility: $action" ;;
      *) failed=$((failed+1)); echo "Failed: $action" >&2 ;;
    esac
  done < "$candidates"
  echo "Results: completed=$completed skipped=$skipped failed=$failed"
  [[ "$failed" -eq 0 ]]
)
