#!/usr/bin/env bash
# Product CLI tests. All fixtures and effects stay in a private temporary tree.
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/home" "$FIX/repo" "$FIX/tmp"
TTY_TOOL="$(command -v script || true)"
for tool in bash jq cat dirname mktemp rm find sort mv; do
  ln -s "$(command -v "$tool")" "$FIX/bin/$tool"
done
# Installation and legacy delegates are traps, not optional real dependencies.
cp "$ROOT/tests/mock-bin/gh" "$FIX/bin/gh"
cp "$ROOT/tests/mock-bin/git" "$FIX/bin/git"
chmod +x "$FIX/bin/gh" "$FIX/bin/git"
for tool in npm npx brew apt apt-get sudo curl wget gh-poi poi; do
  ln -s "$FIX/bin/gh" "$FIX/bin/$tool"
done
export PATH="$FIX/bin" HOME="$FIX/home" TMPDIR="$FIX/tmp"
export SHELL="$FIX/bin/bash"
export GH_CONFIG_DIR="$FIX/home/gh" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export MOCK_ROUTES="$FIX/routes" MOCK_LEDGER="$FIX/ledger"
unset GH_TOKEN GITHUB_TOKEN GH_HOST GIT_DIR GIT_WORK_TREE BASH_ENV ENV MOCK_TOOL || true
cd "$FIX/repo"
passes=0 failures=0
check() {
  local label="$1"; shift
  if "$@"; then
    passes=$((passes+1)); printf 'PASS %s\n' "$label"
  else
    failures=$((failures+1)); printf 'FAIL %s\n' "$label"
    printf '%s\n' "$OUT"
  fi
}
eq() { [[ "$1" == "$2" ]]; }
contains() { [[ "$OUT" == *"$1"* ]]; }
# A broken jq program must not masquerade as successful schema validation.
rejected() { [[ "$RC" -ne 0 && "$OUT" != *"compile error"* ]]; }
ledger() { jq -se "$1" "$MOCK_LEDGER" >/dev/null; }
route() {
  local tool="$1" replies="$2" args; shift 2
  args="$(jq -cn --args '$ARGS.positional' -- "$@")"
  jq --arg tool "$tool" --argjson args "$args" --slurpfile routes "$MOCK_ROUTES" \
    '$routes[0] + [{tool:$tool,args:$args,replies:.}]' <<< "$replies" > "$FIX/next"
  mv_fixture
}
mv_fixture() { mv "$FIX/next" "$MOCK_ROUTES"; }
reply() { printf '%s' "$1" | jq -Rsc --argjson status "${2:-0}" '[{out:.,status:$status}]'; }
reset() {
  printf '[]\n' > "$MOCK_ROUTES"; : > "$MOCK_LEDGER"
  OUT="" RC=0
  route git "$(reply "$FIX/repo")" rev-parse --show-toplevel
  route gh "$(reply example/widgets)" repo view --json nameWithOwner --jq .nameWithOwner
}
runs() {
  jq -cn --argjson n "$1" '[range(1;$n+1) | {id:.,workflow_id:10,run_attempt:1,
    created_at:"2026-01-01T00:00:00Z",actor:{login:"alice"},triggering_actor:{login:"bob"},
    status:"completed",conclusion:"success"}]'
}
pages() {
  jq -c 'length as $n | . as $r | if $n == 0 then [{total_count:0,workflow_runs:[]}]
    else [range(0;$n;100) | {total_count:$n,workflow_runs:$r[.:.+100]}] end' <<< "$1"
}
inventory() {
  route gh "$(reply "$1")" api 'repos/example/widgets/actions/runs?per_page=100' --paginate --slurp
}
cli() {
  RC=0
  OUT="$(bash "$ROOT/gh-sweep" "$@" </dev/null 2>&1)" || RC=$?
  check "boundary allowlist: $*" ledger 'all(.[]; .known)'
  check "Git hooks/fsmonitor disabled: $*" ledger 'all(.[] | select(.tool == "git"); .safe_git)'
}
ids() {
  local kind="$1"
  if [[ "$kind" == kept ]]; then
    printf '%s\n' "$OUT" | jq -Rsc '[split("\n")[] | select(startswith("Retained run: ")) | split("/")[-1] | tonumber] | sort'
  else
    printf '%s\n' "$OUT" | jq -Rsc '[split("\n")[] | select(startswith("Candidate: ")) | ltrimstr("Candidate: ") | fromjson | select(.kind == "run") | .id] | sort'
  fi
}
dry_safe() { ledger 'all(.[]; .known and (.effect|not))'; }
expect_ids() {
  check "$1 candidates" eq "$(ids candidate)" "$(jq -cS . <<< "$2")"
  check "$1 retained" eq "$(ids kept)" "$(jq -cS . <<< "$3")"
  check "$1 repository-qualified candidate identities" eq \
    "$(jq -Rsc '[split("\n")[] | select(startswith("Candidate: ")) | ltrimstr("Candidate: ") | fromjson | select(.kind == "run") | .repo + "/actions/runs/" + (.id|tostring)] | sort' <<< "$OUT")" \
    "$(jq -c 'map("example/widgets/actions/runs/" + tostring) | sort' <<< "$2")"
  check "$1 repository-qualified retained identities" eq \
    "$(jq -Rsc '[split("\n")[] | select(startswith("Retained run: ")) | ltrimstr("Retained run: ")] | sort' <<< "$OUT")" \
    "$(jq -c 'map("example/widgets/actions/runs/" + tostring) | sort' <<< "$3")"
}
branches() {
  route gh "$(reply main)" repo view --json defaultBranchRef --jq .defaultBranchRef.name
  route git "$(reply https://github.com/example/widgets.git)" -C "$FIX/repo" remote get-url origin
  route git "$(reply https://github.com/example/widgets.git)" -C "$FIX/repo" remote get-url --push --all origin
  route gh "$(reply '[[]]')" api 'repos/example/widgets/pulls?state=all&per_page=100' --paginate --slurp
  route git "$(jq -cn --arg path "$FIX/repo" '[{out:("worktree "+$path+"\u0000HEAD ignored\u0000branch refs/heads/main\u0000\u0000")}]')" -C "$FIX/repo" worktree list --porcelain -z
  route git "$(reply '')" -C "$FIX/repo" for-each-ref '--format=%(refname:short)%09%(objectname)' refs/heads
  route git "$(reply '')" -C "$FIX/repo" ls-remote --heads origin
  route gh "$(reply alice)" api user --jq .login
}

for n in 0 1 5 6 23 205 1005; do
  reset; inventory "$(pages "$(runs "$n")")"; cli runs --dry-run
  check "$n runs status" eq "$RC" 0
  expect_ids "$n runs" "$(jq -cn --argjson n "$n" '[range(1;([$n-4,1]|max))]')" \
    "$(jq -cn --argjson n "$n" '[range(([$n-4,1]|max);$n+1)]')"
  check "$n runs dry ledger" dry_safe
done

# Independent workflows, author filtering (not triggering_actor), and failed recency.
mixed="$(runs 12 | jq '[.[] | .workflow_id=(if .id <= 6 then 10 else 20 end) |
  .actor.login=(if .id % 2 == 0 then "bob" else "alice" end)] +
  [{id:99,workflow_id:10,run_attempt:9,created_at:"2026-10-01T00:00:00Z",actor:{login:"alice"},status:"completed",conclusion:"failure"}]')"
reset; inventory "$(pages "$mixed")"; cli runs --dry-run
expect_ids 'two workflows default' '[1,7]' '[2,3,4,5,6,8,9,10,11,12]'
reset; inventory "$(pages "$mixed")"; cli runs --user ALICE --keep-runs 1 --dry-run
expect_ids 'actor not triggering_actor' '[1,3,7,9]' '[5,11]'
reset; inventory "$(pages "$mixed")"; cli runs --include-failed --keep-runs 1 --dry-run
expect_ids 'recent failure participates only when requested' '[1,2,3,4,5,6,7,8,9,10,11]' '[12,99]'
reset; inventory "$(pages "$(runs 6 | jq 'map(.run_attempt=100-.id)')")"; cli runs --keep-runs 1 --dry-run
expect_ids 'timestamp tie uses descending ID not attempt' '[1,2,3,4,5]' '[6]'
reset; inventory "$(pages "$(runs 3 | jq 'map(if .id == 1 then .created_at="2026-02-01T00:00:00Z" else . end)')")"; cli runs --keep-runs 1 --dry-run
expect_ids 'timestamp precedes ID' '[2,3]' '[1]'

# Reconstruct the separately identified example/widgets 14-record discriminator.
# This is not example/tools' earlier attribution-only fixture.
widgets="$(jq -cn '[range(101;115) | . as $id |
  {id:$id,workflow_id:(if IN(112,114) then 20 else 10 end),run_attempt:1,
   created_at:(if $id == 111 then "2026-02-13T00:00:00Z" elif $id == 113 then "2026-02-14T00:00:00Z"
     elif $id == 112 then "2026-02-10T00:00:00Z" elif $id == 114 then "2026-02-09T00:00:00Z"
     else "2026-02-" + ((113-$id)|tostring|if length == 1 then "0"+. else . end) + "T00:00:00Z" end),
   actor:(if $id == 110 then null else {login:(if IN(109,113) then "bob" else "alice" end)} end),
   triggering_actor:{login:(if $id == 101 then "bob" else "alice" end)},
   status:(if $id == 108 then "in_progress" else "completed" end),
   conclusion:(if $id == 108 then null elif IN(107,111) then "failure" else "success" end)}]')"
for flags in '' '--all' '--include-failed' '--all --include-failed'; do
  reset; inventory "$(pages "$widgets")"; read -r -a extra <<< "$flags"
  cli runs --user alice --dry-run "${extra[@]}"
  check "widgets14 $flags status" eq "$RC" 0
  if [[ "$flags" == *--include-failed* ]]; then
    expect_ids "widgets14 $flags" '[105,106,107]' '[101,102,103,104,111,112,114]'
  else
    expect_ids "widgets14 $flags" '[106]' '[101,102,103,104,105,112,114]'
  fi
  check "widgets14 $flags no effects" dry_safe
done

# All nine recognized conclusions, with two runs per actor per workflow.
conclusions='["success","failure","timed_out","startup_failure","cancelled","neutral","skipped","action_required","stale"]'
matrix="$(jq -cn --argjson cs "$conclusions" '[range(0;9) as $c | range(1;5) as $i |
  {id:($c*4+$i),workflow_id:($c+1),run_attempt:1,created_at:"2026-01-01T00:00:00Z",
  actor:{login:(if $i % 2 == 1 then "alice" else "bob" end)},status:"completed",conclusion:$cs[$c]}]')"
for all in false true; do
  for failed in false true; do
    for user in '' alice bob; do
      for auto in false true; do
        flags=(runs --keep-runs 1)
        [[ "$all" == false ]] || flags+=(--all)
        [[ "$failed" == false ]] || flags+=(--include-failed)
        [[ -z "$user" ]] || flags+=(--user "$user")
        if [[ "$auto" == false ]]; then flags+=(--dry-run); else flags+=(--auto); fi
        allowed="$(jq -c --argjson a "$all" --argjson f "$failed" '[.[] | select(.workflow_id == 1 or ($f and .workflow_id <= 4) or ($a and .workflow_id >= 5))]' <<< "$matrix")"
        expected="$(jq -c --arg u "$user" '[.[] | select($u == "" or .actor.login == $u)] | group_by(.workflow_id)' <<< "$allowed")"
        candidate_ids="$(jq -c '[.[] | sort_by(.id) | .[:-1][] | .id] | sort' <<< "$expected")"
        reset; inventory "$(pages "$matrix")"
        while IFS= read -r id; do
          route gh "$(reply "$(jq -c --argjson id "$id" '.[] | select(.id == $id)' <<< "$matrix")")" api "repos/example/widgets/actions/runs/$id"
          route gh "$(reply '')" api --method DELETE "repos/example/widgets/actions/runs/$id"
        done < <(jq -r '.[]' <<< "$candidate_ids")
        cli "${flags[@]}"
        label="conclusions all=$all failed=$failed user=$user auto=$auto"
        check "$label status" eq "$RC" 0
        expect_ids "$label" "$candidate_ids" \
          "$(jq -c '[.[] | max_by(.id) | .id] | sort' <<< "$expected")"
        if [[ "$auto" == false ]]; then
          check "$label no effects" dry_safe
        else
          actual="$(jq -sc '[.[] | select(.effect) | .args[-1] | split("/")[-1] | tonumber] | sort' "$MOCK_LEDGER")"
          check "$label exact effects" eq "$actual" "$candidate_ids"
        fi
      done
    done
  done
done

for args in 'runs --keep-runs 0' 'runs --keep-runs -1' 'runs --keep-runs 1.5' 'runs --keep-runs nope' \
  'runs --keep-runs' 'runs --user' 'runs --user a/b' 'runs --user @alice' 'runs --depth -1' \
  'runs --depth 10000' 'runs --depth nope' 'runs --depth' 'bogus' 'runs --bogus' 'comments 0'; do
  reset
  read -r -a flags <<< "$args"; cli "${flags[@]}"
  check "invalid $args rejected" test "$RC" -ne 0
  check "invalid $args no boundary calls" ledger 'length == 0'
done

# Malformed attributable identities invalidate the whole inventory, not just one row.
for change in 'del(.id)' '.id=null' '.id="1"' '.id=0' '.id=1.5' '.id=9007199254740992' \
  'del(.workflow_id)' '.workflow_id=null' '.workflow_id=0' 'del(.run_attempt)' '.run_attempt=null' \
  '.run_attempt=0' 'del(.created_at)' '.created_at=null' '.created_at="yesterday"' \
  '.created_at="2026-99-01T00:00:00Z"' 'del(.actor)' '.actor={}' '.actor.login="a/b"' \
  '.actor.login=2' '.actor="alice"' '.status="unknown"' 'del(.conclusion)' '.conclusion="unknown"' \
  '.conclusion=null' '.status="in_progress"'; do
  reset; inventory "$(pages "$(runs 6 | jq ".[0] |= ($change)")")"; cli runs --auto
  check "invalid identity $change" rejected
  check "invalid identity has zero effects $change" dry_safe
done
for change in '.actor=null' '.actor.login=null' '.status="queued" | .conclusion=null' \
  '.status="in_progress" | .conclusion=null' '.status="waiting" | .conclusion=null' \
  '.status="pending" | .conclusion=null' '.status="requested" | .conclusion=null'; do
  reset; inventory "$(pages "$(runs 7 | jq ".[0] |= ($change)")")"; cli runs --dry-run
  check "unattributed/active valid $change" eq "$RC" 0
  expect_ids "unattributed/active $change" '[2]' '[3,4,5,6,7]'
  check "unattributed/active safe $change" dry_safe
done

for transform in '.[:0]' '.[0].total_count=7' '.[0].workflow_runs[0]=.[0].workflow_runs[1]' \
  '.[0].workflow_runs=null' '.[0].total_count="6"' '.[0].total_count=-1' \
  '. + [{total_count:7,workflow_runs:[]}]' '.[0].workflow_runs += .[0].workflow_runs'; do
  reset; inventory "$(pages "$(runs 6)" | jq "$transform")"; cli runs --auto
  check "bad pagination $transform" rejected
  check "bad pagination safe $transform" dry_safe
done
for transform in '.[1].total_count=204' '.[1].workflow_runs[0]=.[0].workflow_runs[0]' \
  '.[1].workflow_runs |= .[:-1]' '.[0].workflow_runs += [.[0].workflow_runs[0]]'; do
  reset; inventory "$(pages "$(runs 205)" | jq "$transform")"; cli runs --auto
  check "multi-100 pagination $transform" rejected
  check "multi-100 safe $transform" dry_safe
done
reset; inventory not-json; cli runs --auto
check 'malformed JSON rejected' rejected
check 'malformed JSON zero effects' dry_safe
reset; route gh "$(reply 'authentication failed' 1)" repo view --json nameWithOwner --jq .nameWithOwner
# Remove the default repo-view route so this is an exact replacement, not ambiguity.
jq '.[0:1] + .[2:]' "$MOCK_ROUTES" > "$FIX/next"; mv_fixture
cli runs --auto
check 'authentication failure' test "$RC" -ne 0
check 'auth failure no effects' dry_safe
reset; route gh "$(reply 'pagination failed' 1)" api 'repos/example/widgets/actions/runs?per_page=100' --paginate --slurp
cli runs --auto
check 'pagination API failure' test "$RC" -ne 0
check 'pagination API failure no effects' dry_safe

reset; inventory "$(pages "$(runs 6)")"; cli runs
check 'noninteractive refuses' test "$RC" -ne 0
check 'noninteractive refusal message' contains 'Refused: noninteractive'
check 'noninteractive zero effects' dry_safe

execution() {
  local fresh="$1" fail="${2:-0}" detail="${3:-$(runs 6 | jq -c '.[0]')}"
  reset
  route gh "$(jq -cn --arg a "$(pages "$(runs 7)")" --arg b "$(pages "$fresh")" '[{out:$a},{out:$b}]')" \
    api 'repos/example/widgets/actions/runs?per_page=100' --paginate --slurp
  for id in 1 2; do
    row="$(runs 7 | jq -c --argjson id "$id" '.[] | select(.id == $id)')"
    [[ "$id" != 1 ]] || row="$detail"
    route gh "$(reply "$row")" api "repos/example/widgets/actions/runs/$id"
    route gh "$(reply '' "$fail")" api --method DELETE "repos/example/widgets/actions/runs/$id"
  done
  cli runs --auto
}
execution "$(runs 7)"
check 'execution success' eq "$RC" 0
check 'execution summary' contains 'Results: completed=2 skipped=0 failed=0'
check 'execution exact ordered delete IDs (newest first)' ledger '[.[] | select(.effect) | .args[-1]] == ["repos/example/widgets/actions/runs/2","repos/example/widgets/actions/runs/1"] and all(.[]; .known)'
execution "$(runs 7)" 1
check 'execution failure exit' test "$RC" -ne 0
check 'execution failure summary continues' contains 'Results: completed=0 skipped=0 failed=2'
execution "$(runs 7 | jq 'map(select(.id != 1)) + [.[-1] | .id=8]')"
check 'eligibility narrows and never adds unseen' contains 'Results: completed=1 skipped=1 failed=0'
check 'no unseen delete' ledger '[.[] | select(.effect) | .args[-1]] == ["repos/example/widgets/actions/runs/2"]'
execution "$(runs 7)" 0 "$(runs 7 | jq -c '.[0] | .run_attempt=2')"
check 'detail rerun skips changed identity' contains 'Results: completed=1 skipped=1 failed=0'
check 'detail rerun no changed delete' ledger '[.[] | select(.effect) | .args[-1]] == ["repos/example/widgets/actions/runs/2"]'
execution "$(runs 7)" 0 "$(runs 7 | jq -c '.[0] | del(.actor)')"
check 'malformed execution-time attribution fails' test "$RC" -ne 0
check 'malformed execution-time attribution summary' contains 'Results: completed=1 skipped=0 failed=1'
check 'malformed execution-time attribution never deleted' ledger '[.[] | select(.effect) | .args[-1]] == ["repos/example/widgets/actions/runs/2"]'
execution '[]'
check 'empty fresh inventory skips all original candidates' contains 'Results: completed=0 skipped=2 failed=0'
check 'empty fresh inventory no effects' dry_safe
reset
route gh "$(jq -cn --arg a "$(pages "$(runs 6)")" '[{out:$a},{out:"API failed",status:1}]')" \
  api 'repos/example/widgets/actions/runs?per_page=100' --paginate --slurp
cli runs --auto
check 'fresh inventory failure aborts' test "$RC" -ne 0
check 'fresh inventory failure zero effects' dry_safe

for category in caches notifications comments orphans; do
  reset; flags=("$category"); [[ "$category" != comments ]] || flags+=(12)
  cli "${flags[@]}" --user alice --auto
  check "user $category skipped" eq "$RC" 0
  check "user $category never enumerated" ledger 'length == 0'
done
reset; branches; inventory "$(pages "$(runs 6)")"
route gh "$(reply "$(runs 6 | jq -c '.[0]')")" api repos/example/widgets/actions/runs/1
route gh "$(reply '')" api --method DELETE repos/example/widgets/actions/runs/1
cli --user alice --auto
check 'full user sweep status' eq "$RC" 0
check 'full user sweep excludes unsupported categories' ledger 'all(.[]; (.args|join(" ")|test("caches|notifications|graphql|orphan|poi|prune|install")|not))'
check 'full user sweep only selected run effect' ledger '[.[] | select(.effect) | .args] == [["api","--method","DELETE","repos/example/widgets/actions/runs/1"]] and all(.[]; .known)'

# Non-user full sweep includes cache/notification inventory, never extension delegates.
nonuser() {
  reset; branches; inventory "$(pages '[]')"
  route gh "$(reply '[{"total_count":1,"actions_caches":[{"id":41,"ref":"refs/heads/gone"}]}]')" api 'repos/example/widgets/actions/caches?per_page=100' --paginate --slurp
  route gh "$(reply '[[]]')" api 'repos/example/widgets/branches?per_page=100' --paginate --slurp
  route gh "$(reply '[[{"id":"51"}],[{"id":"52"}]]')" api 'repos/example/widgets/notifications?all=false&per_page=100' --paginate --slurp
  route gh "$(reply '')" api --method DELETE repos/example/widgets/actions/caches/41
  for id in 51 52; do
    route gh "$(reply '')" api --method PATCH "notifications/threads/$id"
    route gh "$(reply '')" api --method DELETE "notifications/threads/$id"
  done
}
nonuser; cli --dry-run
check 'full nonuser dry-run' eq "$RC" 0
check 'full nonuser dry ledger' dry_safe
nonuser; cli --auto
check 'full nonuser execution' eq "$RC" 0
check 'cache and PATCH DELETE ordered' ledger '[.[] | select(.effect) | .args] == [["api","--method","DELETE","repos/example/widgets/actions/caches/41"],["api","--method","PATCH","notifications/threads/51"],["api","--method","DELETE","notifications/threads/51"],["api","--method","PATCH","notifications/threads/52"],["api","--method","DELETE","notifications/threads/52"]] and all(.[]; .known)'
check 'nonuser summary' contains 'Results: completed=3 skipped=0 failed=0'

nonuser; cli caches --dry-run
check 'cache dry status' eq "$RC" 0
check 'cache dry zero effects' dry_safe
nonuser; cli caches --auto
check 'cache execute status' eq "$RC" 0
check 'cache exact DELETE' ledger '[.[] | select(.effect) | .args] == [["api","--method","DELETE","repos/example/widgets/actions/caches/41"]] and all(.[]; .known)'
nonuser; cli notifications --dry-run
check 'notifications slurped arrays preview' eq "$RC" 0
check 'notifications dry zero effects' dry_safe
nonuser; cli notifications --auto
check 'notifications execute' eq "$RC" 0
check 'notifications PATCH then DELETE' ledger '[.[] | select(.effect) | .args[2:]] == [["PATCH","notifications/threads/51"],["DELETE","notifications/threads/51"],["PATCH","notifications/threads/52"],["DELETE","notifications/threads/52"]] and all(.[]; .known)'
nonuser
jq 'map(if .args == ["api","--method","PATCH","notifications/threads/51"] then .replies=[{status:1}] else . end)' "$MOCK_ROUTES" > "$FIX/next"; mv_fixture
cli notifications --auto
check 'notification PATCH failure exit' test "$RC" -ne 0
check 'notification PATCH failure continues other candidates' contains 'Results: completed=1 skipped=0 failed=1'
check 'notification failed PATCH never DELETEs that thread' ledger '[.[] | select(.effect) | .args[2:]] == [["PATCH","notifications/threads/51"],["PATCH","notifications/threads/52"],["DELETE","notifications/threads/52"]]'
nonuser; cli caches
check 'cache noninteractive refusal' contains 'Refused: noninteractive'
check 'cache noninteractive zero effects' dry_safe
if [[ -n "$TTY_TOOL" ]]; then
  nonuser; RC=0
  printf -v tty_command 'bash %q caches' "$ROOT/gh-sweep"
  OUT="$("$TTY_TOOL" -q -e -c "$tty_command" /dev/null <<< n 2>&1)" || RC=$?
  check 'interactive no refuses' contains 'Refused; no effects performed'
  check 'interactive no status' eq "$RC" 0
  check 'interactive no zero effects' dry_safe
else
  printf 'SKIP interactive refusal: script unavailable\n'
fi

# Match the complete GraphQL argv, including namespace and pagination cursor.
# GraphQL variables are literal API input.
# shellcheck disable=SC2016
query='
      query($owner:String!,$repo:String!,$pr:Int!,$cursor:String) {
        repository(owner:$owner,name:$repo) { pullRequest(number:$pr) {
          reviewThreads(first:100,after:$cursor) {
            nodes { id isResolved } pageInfo { hasNextPage endCursor }
          }
        } }
      }'
# shellcheck disable=SC2016
mutation='mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { id isResolved } } }'
comments() {
  reset
  # tools and widgets are distinct repositories, never interchangeable aliases.
  jq 'map(select(.tool != "gh"))' "$MOCK_ROUTES" > "$FIX/next"; mv_fixture
  route gh "$(reply example/tools)" repo view --json nameWithOwner --jq .nameWithOwner
  route gh "$(reply '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false},{"id":"T0","isResolved":true}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}}}}')" \
    api graphql -f "query=$query" -f owner=example -f repo=tools -F pr=12
  route gh "$(reply '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T2","isResolved":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}')" \
    api graphql -f "query=$query" -f owner=example -f repo=tools -F pr=12 -f cursor=cursor-1
  for id in T1 T2; do
    route gh "$(reply "$(jq -cn --arg id "$id" '{data:{resolveReviewThread:{thread:{id:$id,isResolved:true}}}}')")" \
      api graphql -f "query=$mutation" -f "id=$id"
  done
}
comments; cli comments 12 --dry-run
check 'GraphQL paginated preview' eq "$RC" 0
check 'GraphQL preview exact namespace candidates' contains '"repo":"example/tools","id":"T1"'
check 'GraphQL dry zero mutation' dry_safe
comments; cli comments 12 --auto
check 'GraphQL execute' eq "$RC" 0
check 'GraphQL mutations ordered' ledger '[.[] | select(.effect) | .args[-1]] == ["id=T1","id=T2"] and all(.[]; .known)'
check 'GraphQL summary' contains 'Results: completed=2 skipped=0 failed=0'
comments
jq 'map(if (.args[-1] == "id=T1") then .replies=[{out:"{\"errors\":[{\"message\":\"denied\"}]}"}] else . end)' "$MOCK_ROUTES" > "$FIX/next"; mv_fixture
cli comments 12 --auto
check 'GraphQL mutation errors fail' test "$RC" -ne 0
check 'GraphQL mutation failure summary' contains 'Results: completed=1 skipped=0 failed=1'

for category in notifications caches; do
  nonuser
  if [[ "$category" == notifications ]]; then
    bad='[{"id":"51"}]'
    endpoint='repos/example/widgets/notifications?all=false&per_page=100'
  else
    bad='[{"total_count":2,"actions_caches":[]}]'
    endpoint='repos/example/widgets/actions/caches?per_page=100'
  fi
  jq --arg ep "$endpoint" 'map(select(.args[1] != $ep))' "$MOCK_ROUTES" > "$FIX/next"; mv_fixture
  route gh "$(reply "$bad")" api "$endpoint" --paginate --slurp
  cli "$category" --auto
  check "$category malformed inventory refuses" test "$RC" -ne 0
  check "$category malformed inventory zero effects" dry_safe
done

for change in '.id=0' '.id=1.5' '.id=9007199254740992' 'del(.id)' '.ref=""' '.ref="refs/heads/"' '.ref="refs/heads/bad name"'; do
  nonuser
  jq 'map(select(.args[1] != "repos/example/widgets/actions/caches?per_page=100"))' "$MOCK_ROUTES" > "$FIX/next"; mv_fixture
  bad="$(jq -cn "[{total_count:1,actions_caches:[({id:41,ref:\"refs/heads/gone\"}|$change)]}]")"
  route gh "$(reply "$bad")" api 'repos/example/widgets/actions/caches?per_page=100' --paginate --slurp
  cli caches --auto
  check "malformed cache $change rejected" rejected
  check "malformed cache $change zero effects" dry_safe
done

# Ensure the boundary itself records and refuses unknown reads, writes and delegates.
for tool in gh git npm gh-poi; do
  reset; rc=0; "$tool" unexpected install >/dev/null 2>&1 || rc=$?
  check "$tool unknown fails closed" eq "$rc" 97
  check "$tool unknown ledger" ledger 'length == 1 and .[0].known == false and .[0].effect == true'
done
printf 'Safety tests: %s passed, %s failed\n' "$passes" "$failures"
[[ "$failures" -eq 0 ]]
