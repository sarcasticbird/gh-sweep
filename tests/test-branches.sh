#!/usr/bin/env bash
# Standalone CLI diagnostics: only shared exact-argv mocks can reach git or gh.
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/home" "$FIX/repo" "$FIX/tmp"
for tool in bash jq cat dirname mktemp rm find sort mv mkdir; do
  ln -s "$(command -v "$tool")" "$FIX/bin/$tool"
done
cp "$ROOT/tests/mock-bin/gh" "$ROOT/tests/mock-bin/git" "$FIX/bin/"
chmod +x "$FIX/bin/gh" "$FIX/bin/git"
for tool in npm npx brew apt apt-get sudo curl wget gh-poi poi; do
  ln -s "$FIX/bin/gh" "$FIX/bin/$tool"
done
export PATH="$FIX/bin" HOME="$FIX/home" TMPDIR="$FIX/tmp" SHELL="$FIX/bin/bash"
export GH_CONFIG_DIR="$FIX/home/gh" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export MOCK_ROUTES="$FIX/routes" MOCK_LEDGER="$FIX/ledger"
unset GH_TOKEN GITHUB_TOKEN GH_HOST GIT_DIR GIT_WORK_TREE BASH_ENV ENV MOCK_TOOL || true
cd "$FIX/repo"
passes=0 failures=0 OUT='' RC=0
OID=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
check() {
  local label="$1"; shift
  if "$@"; then
    passes=$((passes+1)); printf 'PASS %s\n' "$label"
  else
    failures=$((failures+1)); printf 'FAIL %s\n%s\n' "$label" "$OUT"
  fi
}
eq() { [[ "$1" == "$2" ]]; }
contains() { [[ "$OUT" == *"$1"* ]]; }
rejected() { [[ "$RC" -ne 0 && "$OUT" != *'compile error'* ]]; }
ledger() { jq -se "$1" "$MOCK_LEDGER" >/dev/null; }
no_effects() { ledger 'all(.[]; .known and (.effect|not))'; }
reply() { jq -cn --arg out "$1" --argjson status "${2:-0}" '[{out:$out,status:$status}]'; }
sequence() { jq -cn --arg a "$1" --arg b "$2" '[{out:$a},{out:$b}]'; }
route() {
  local tool="$1" replies="$2" args; shift 2
  args="$(jq -cn --args '$ARGS.positional' -- "$@")"
  # Replacement keeps every route unique, including fault-injection overrides.
  jq --arg tool "$tool" --argjson args "$args" --argjson replies "$replies" \
    'map(select(.tool != $tool or .args != $args)) + [{tool:$tool,args:$args,replies:$replies}]' \
    "$MOCK_ROUTES" > "$FIX/next"
  mv "$FIX/next" "$MOCK_ROUTES"
}
pr() {
  jq -cn --arg branch "$1" --arg author "${2:-alice}" --arg oid "$OID" \
    '{number:(if $branch == "other" then 2 else 1 end),state:"closed",merged_at:"2026-01-01T00:00:00Z",user:{login:$author},
      head:{ref:$branch,sha:$oid,repo:{full_name:"example/widgets"}}}'
}
config() {
  local branch="$1" flag="$2" value="${3:-}" status="${4:-1}"
  route git "$(reply "$value" "$status")" -C "$FIX/repo" config --get "branch.$branch.$flag"
  route git "$(reply "$value" "$status")" -C "$FIX/repo" config --type=bool --get "branch.$branch.$flag"
}
tree() {
  # Keep NUL bytes inside JSON until the shared gh mock writes .out using jq -r.
  jq -cn --arg path "$1" --arg branch "$2" --arg flag "${3:-}" \
    '"worktree " + $path + "\u0000HEAD ignored\u0000branch refs/heads/" + $branch +
     "\u0000" + (if $flag == "" then "" else $flag + "\u0000" end) + "\u0000"'
}
trees_reply() { jq -cn --argjson out "$1" '[{out:$out}]'; }
reset() {
  printf '[]\n' > "$MOCK_ROUTES"; : > "$MOCK_LEDGER"
  OUT='' RC=0
  route git "$(reply "$FIX/repo")" rev-parse --show-toplevel
  route gh "$(reply example/widgets)" repo view --json nameWithOwner --jq .nameWithOwner
  route gh "$(reply main)" repo view --json defaultBranchRef --jq .defaultBranchRef.name
  route git "$(reply https://github.com/example/widgets.git)" -C "$FIX/repo" remote get-url origin
  route git "$(reply https://github.com/example/widgets.git)" -C "$FIX/repo" remote get-url --push --all origin
  route gh "$(reply alice)" api user --jq .login
  PULLS="$(jq -cn --argjson a "$(pr topic)" --argjson b "$(pr other bob)" '[[$a,$b]]')"
  LOCALS="$(printf 'topic\t%s\nother\t%s\norphan\t%s' "$OID" "$OID" "$OID")"
  REMOTE="$(printf '%s\trefs/heads/topic\n%s\trefs/heads/other' "$OID" "$OID")"
  for branch in topic other orphan; do
    config "$branch" gh-poi-locked
    config "$branch" gh-poi-protected
    route git "$(reply '')" -C "$FIX/repo" for-each-ref '--format=%(upstream)' "refs/heads/$branch"
    route git "$(reply "$OID")" -C "$FIX/repo" rev-parse --verify "refs/heads/$branch"
    route git "$(reply '')" -C "$FIX/repo" update-ref -d "refs/heads/$branch" "$OID"
    route git "$(reply '')" -C "$FIX/repo" push "--force-with-lease=refs/heads/$branch:$OID" origin ":refs/heads/$branch"
  done
  TREES="$(tree "$FIX/repo" main)"
}
inventories() {
  route gh "$(reply "$PULLS")" api 'repos/example/widgets/pulls?state=all&per_page=100' --paginate --slurp
  route git "$(trees_reply "$TREES")" -C "$FIX/repo" worktree list --porcelain -z
  route git "$(reply "$LOCALS")" -C "$FIX/repo" for-each-ref '--format=%(refname:short)%09%(objectname)' refs/heads
  route git "$(reply "$REMOTE")" -C "$FIX/repo" ls-remote --heads origin
  route gh "$(reply '[{"total_count":0,"workflow_runs":[]}]')" api 'repos/example/widgets/actions/runs?per_page=100' --paginate --slurp
  route gh "$(reply '[{"total_count":0,"actions_caches":[]}]')" api 'repos/example/widgets/actions/caches?per_page=100' --paginate --slurp
  route gh "$(reply '[[]]')" api 'repos/example/widgets/branches?per_page=100' --paginate --slurp
  route gh "$(reply '[[]]')" api 'repos/example/widgets/notifications?all=false&per_page=100' --paginate --slurp
}
cli() {
  RC=0; OUT="$(bash "$ROOT/gh-sweep" "$@" </dev/null 2>&1)" || RC=$?
  check "exact boundary: $*" ledger 'all(.[]; .known)'
  check "Git hooks/fsmonitor disabled: $*" ledger 'all(.[] | select(.tool == "git"); .safe_git)'
}
candidates() {
  jq -Rsc '[split("\n")[] | select(startswith("Candidate: ")) | ltrimstr("Candidate: ") |
    fromjson | [.kind,.branch,.oid]] | sort' <<< "$OUT"
}
expect_candidates() {
  local expected
  expected="$(jq -c --arg oid "$OID" 'map(. + [$oid]) | sort' <<< "$2")"
  check "$1 candidates" eq "$(candidates)" "$expected"
}
expect_effects() {
  local expected
  expected="$(jq -c --arg dir "$FIX/repo" --arg oid "$OID" 'map(
    if .[0] == "local" then ["-C",$dir,"update-ref","-d",("refs/heads/"+.[1]),$oid]
    elif .[0] == "worktree" then ["-c","status.showUntrackedFiles=all","-C",$dir,"worktree","remove","--",.[1]]
    else ["-C",$dir,"push",("--force-with-lease=refs/heads/"+.[1]+":"+$oid),"origin",(":refs/heads/"+.[1])] end)' <<< "$2")"
  check "$1 exact ordered effects" eq "$(jq -sc '[.[] | select(.effect) | .args]' "$MOCK_LEDGER")" "$expected"
}

# Command/author/mode matrix: --all broadens authors, never the selected user.
for command in branches local remote full; do
  for scope in default all user user-all; do
    for mode in dry execute; do
      reset; inventories
      flags=(); [[ "$command" == full ]] || flags+=("$command")
      case "$scope" in all) flags+=(--all);; user) flags+=(--user ALICE);; user-all) flags+=(--user ALICE --all);; esac
      if [[ "$mode" == dry ]]; then flags+=(--dry-run --auto); else flags+=(--auto); fi
      expected='[]'
      if [[ "$command" != remote ]]; then
        expected='[["local","topic"]]'
        if [[ "$scope" == default || "$scope" == all ]]; then
          expected="$(jq -c '. + [["local","other"]]' <<< "$expected")"
          [[ "$command" != full ]] || expected="$(jq -c '. + [["local","orphan"]]' <<< "$expected")"
        fi
      fi
      if [[ "$command" != local ]]; then
        expected="$(jq -c '. + [["remote","topic"]]' <<< "$expected")"
        [[ "$scope" != all ]] || expected="$(jq -c '. + [["remote","other"]]' <<< "$expected")"
      fi
      cli "${flags[@]}"; label="$command $scope $mode"
      check "$label status" eq "$RC" 0
      expect_candidates "$label" "$expected"
      if [[ "$mode" == dry ]]; then check "$label no effects" no_effects
      else expect_effects "$label" "$expected"; fi
      check "$label no delegate/prune/fetch/branch-delete" ledger \
        'all(.[]; (.tool == "git" or .tool == "gh") and
          ((.args | index("prune")) == null) and ((.args | index("fetch")) == null) and
          ((.args | index("branch")) == null))'
      if [[ "$scope" == user* ]]; then
        check "$label unsupported categories not enumerated" ledger \
          'all(.[]; (.args|join(" ")|test("caches|notifications|graphql|upstream|poi$|prune")|not))'
      fi
    done
  done
done

# Orphan exclusion requires a complete remote ref, not a prefix collision.
for command in orphans full; do
  for remote_kind in none prefix child exact-first exact-last; do
    for mode in dry execute; do
      reset; PULLS='[[]]'; LOCALS="$(printf 'topic\t%s' "$OID")"
      for branch in topic-extra topic/child; do
        config "$branch" gh-poi-locked
        config "$branch" gh-poi-protected
      done
      case "$remote_kind" in
        none) REMOTE='' ;;
        prefix) REMOTE="$(printf '%s\trefs/heads/topic-extra' "$OID")" ;;
        child) REMOTE="$(printf '%s\trefs/heads/topic/child' "$OID")" ;;
        exact-first) REMOTE="$(printf '%s\trefs/heads/topic\n%s\trefs/heads/topic-extra' "$OID" "$OID")" ;;
        exact-last) REMOTE="$(printf '%s\trefs/heads/topic-extra\n%s\trefs/heads/topic' "$OID" "$OID")" ;;
      esac
      inventories
      flags=(); [[ "$command" == full ]] || flags+=(orphans)
      [[ "$mode" == dry ]] && flags+=(--dry-run) || flags+=(--auto)
      expected='[["local","topic"]]'
      [[ "$remote_kind" != exact-* ]] || expected='[]'
      cli "${flags[@]}"
      check "$command $remote_kind $mode status" eq "$RC" 0
      expect_candidates "$command $remote_kind $mode" "$expected"
      if [[ "$mode" == dry ]]; then check "$command $remote_kind preview has no effects" no_effects
      else expect_effects "$command $remote_kind execution" "$expected"; fi
    done
  done
done

# Protected names, both gh-poi flags, root, dirty, locked and prunable worktrees.
for unsafe in main master develop locked protected root dirty wt-locked prunable; do
  for mode in dry execute; do
    reset
    branch=topic; [[ "$unsafe" != main && "$unsafe" != master && "$unsafe" != develop ]] || branch="$unsafe"
    PULLS="$(jq -cn --argjson p "$(pr "$branch")" '[[$p]]')"
    LOCALS="$(printf '%s\t%s' "$branch" "$OID")"
    REMOTE="$(printf '%s\trefs/heads/%s' "$OID" "$branch")"
    case "$unsafe" in
      locked) config topic gh-poi-locked true 0;;
      protected) config topic gh-poi-protected true 0;;
      root) TREES="$(tree "$FIX/repo" topic)";;
      dirty|wt-locked|prunable)
        flag=''; [[ "$unsafe" != wt-locked ]] || flag='locked reason'
        [[ "$unsafe" != prunable ]] || flag='prunable reason'
        TREES="$(tree "$FIX/linked tree" topic "$flag")"
        route git "$(reply ' M tracked')" --no-optional-locks -C "$FIX/linked tree" status --porcelain --untracked-files=all;;
    esac
    inventories
    flags=(local --all); [[ "$mode" != dry ]] && flags+=(--auto) || flags+=(--dry-run)
    cli "${flags[@]}"
    check "$unsafe $mode status" eq "$RC" 0
    expect_candidates "$unsafe $mode" '[]'
    check "$unsafe $mode no effects" no_effects
    if [[ "$branch" != topic ]]; then
      cli branches --all --auto
      expect_candidates "$unsafe remote protected" '[]'
      check "$unsafe remote protected no effects" no_effects
    fi
  done
done

# Real NUL records and a path with whitespace; removal must precede old-OID delete.
for order in linked-first linked-last; do
 for mode in dry execute; do
  reset; LOCALS="$(printf 'topic\t%s' "$OID")"; REMOTE=''
  TREES="$(jq -cn --arg order "$order" --argjson a "$TREES" --argjson b "$(tree "$FIX/linked tree" topic)" \
    'if $order == "linked-first" then $b+$a else $a+$b end')"
  inventories
  route git "$(reply '')" --no-optional-locks -C "$FIX/linked tree" status --porcelain --untracked-files=all
  route git "$(reply '')" -c status.showUntrackedFiles=all -C "$FIX/repo" worktree remove -- "$FIX/linked tree"
  if [[ "$mode" == execute ]]; then
    route git "$(jq -cn --argjson before "$TREES" --argjson after "$(tree "$FIX/repo" main)" \
      '[{out:$before},{out:$before},{out:$before},{out:$after}]')" -C "$FIX/repo" worktree list --porcelain -z
  fi
  flags=(local); [[ "$mode" != dry ]] && flags+=(--auto) || flags+=(--dry-run)
  cli "${flags[@]}"
  check "clean worktree $order $mode status" eq "$RC" 0
  expect_candidates "clean worktree $order $mode" '[["worktree","topic"],["local","topic"]]'
  if [[ "$mode" == dry ]]; then check "clean worktree $order preview no effects" no_effects
  else expect_effects "clean worktree $order execute" "$(jq -cn --arg p "$FIX/linked tree" '[["worktree",$p],["local","topic"]]')"; fi
 done
done

# User scope must never infer ownership for orphans, even with --all/--auto.
reset; inventories; cli orphans --user alice --all --auto
check 'selected user orphan command skipped' eq "$RC" 0
check 'selected user orphan command no calls' ledger 'length == 0'

# Known API failures must abort globally before any valid branch gets deleted.
for failure in auth pulls missing-user invalid-login missing-sha invalid-sha missing-state missing-number missing-merged nonarray not-json later-category; do
  reset; inventories
  case "$failure" in
    auth) route gh "$(reply 'authentication failed' 1)" repo view --json nameWithOwner --jq .nameWithOwner;;
    pulls) route gh "$(reply 'PR inventory unavailable' 1)" api 'repos/example/widgets/pulls?state=all&per_page=100' --paginate --slurp;;
    later-category) route gh "$(reply 'invalid runs schema')" api 'repos/example/widgets/actions/runs?per_page=100' --paginate --slurp;;
    *)
      case "$failure" in
        missing-user) change='del(.user)';; invalid-login) change='.user.login="a/b"';;
        missing-sha) change='del(.head.sha)';; invalid-sha) change='.head.sha="bad"';;
        missing-state) change='del(.state)';; missing-number) change='del(.number)';;
        missing-merged) change='del(.merged_at)';; nonarray|not-json) change='.';;
      esac
      bad="$(jq -c ".[0][1] |= ($change)" <<< "$PULLS")"
      [[ "$failure" != nonarray ]] || bad='{"pulls":[]}'
      [[ "$failure" != not-json ]] || bad='not JSON'
      route gh "$(reply "$bad")" api 'repos/example/widgets/pulls?state=all&per_page=100' --paginate --slurp;;
  esac
  cli --user alice --all --auto
  check "$failure rejects whole plan" rejected
  check "$failure zero effects" no_effects
done

for failure in auth invalid-login; do
  reset; inventories
  if [[ "$failure" == auth ]]; then response="$(reply 'authentication failed' 1)"
  else response="$(reply 'a/b')"; fi
  route gh "$response" api user --jq .login
  cli remote --auto
  check "authenticated caller $failure rejected" rejected
  check "authenticated caller $failure no effects" no_effects
done

# Eligibility attribution: missing PR, open PR, fork, null author and mismatched SHA.
for change in 'empty' '.state="open" | .merged_at=null' '.head.repo.full_name="fork/widgets"' \
  '.user=null' '.user.login=null' ".head.sha=\"$NEW\""; do
  reset; LOCALS="$(printf 'topic\t%s' "$OID")"; REMOTE="$(printf '%s\trefs/heads/topic' "$OID")"
  if [[ "$change" == empty ]]; then PULLS='[[]]'
  else PULLS="$(jq -cn --argjson p "$(pr topic | jq "$change")" '[[$p]]')"; fi
  inventories; cli branches --user alice --all --auto
  check "ineligible $change status" eq "$RC" 0
  expect_candidates "ineligible $change" '[]'
  check "ineligible $change no effects" no_effects
done

# Revalidation can narrow, never replace the captured old OID or add new branches.
for change in inventory detail fresh-failure; do
  reset; LOCALS="$(printf 'topic\t%s' "$OID")"; inventories
  case "$change" in
    inventory)
      route git "$(sequence "$LOCALS" "$(printf 'topic\t%s\nother\t%s' "$NEW" "$OID")")" \
        -C "$FIX/repo" for-each-ref '--format=%(refname:short)%09%(objectname)' refs/heads;;
    detail) route git "$(reply "$NEW")" -C "$FIX/repo" rev-parse --verify refs/heads/topic;;
    fresh-failure) route gh "$(jq -cn --arg p "$PULLS" '[{out:$p},{out:"failed",status:1}]')" \
      api 'repos/example/widgets/pulls?state=all&per_page=100' --paginate --slurp;;
  esac
  cli local --user alice --auto
  if [[ "$change" == fresh-failure ]]; then check 'fresh failure rejected' rejected
  else check "$change narrowing status" eq "$RC" 0; check "$change narrowed summary" contains 'completed=0 skipped=1 failed=0'; fi
  check "$change no effects or unseen deletes" no_effects
done

# A changed remote head must not be substituted into the originally displayed lease.
reset; inventories
route git "$(sequence "$REMOTE" "$(printf '%s\trefs/heads/topic' "$NEW")")" -C "$FIX/repo" ls-remote --heads origin
cli remote --user alice --auto
check 'remote changed inventory status' eq "$RC" 0
check 'remote changed inventory narrows' contains 'completed=0 skipped=1 failed=0'
check 'remote changed inventory no replacement lease' no_effects

# Remote races rely on an exact old-OID lease, not unguarded branch deletion.
reset; inventories
route git "$(reply 'stale lease' 1)" -C "$FIX/repo" push "--force-with-lease=refs/heads/topic:$OID" origin :refs/heads/topic
cli remote --user alice --auto
check 'remote stale lease failure reported' rejected
expect_effects 'remote stale lease' '[["remote","topic"]]'
check 'remote stale lease summary' contains 'completed=0 skipped=0 failed=1'

reset; inventories; cli branches --user alice
check 'branch noninteractive execution refused' rejected
check 'branch refusal no effects' no_effects

for flag in gh-poi-locked gh-poi-protected; do
  reset; config topic "$flag" true 0; inventories; cli remote --user alice --all --auto
  check "remote $flag protected" eq "$RC" 0
  expect_candidates "remote $flag protected" '[]'
  check "remote $flag zero effects" no_effects
done
reset; inventories
route gh "$(reply topic)" repo view --json defaultBranchRef --jq .defaultBranchRef.name
cli branches --user alice --all --auto
expect_candidates 'nonstandard default branch protected' '[]'
check 'nonstandard default branch zero effects' no_effects
for origin in https://github.com/example/other.git /tmp/unverifiable; do
  reset; inventories
  route git "$(reply "$origin")" -C "$FIX/repo" remote get-url origin
  cli branches --auto
  check "origin $origin rejects" rejected
  check "origin $origin no effects" no_effects
done
reset; inventories
route git "$(reply https://github.com/example/other.git)" -C "$FIX/repo" remote get-url --push --all origin
cli remote --user alice --auto
check 'distinct push destination rejected' rejected
check 'distinct push destination no effects' no_effects
for change in '.number=1.5' '.merged_at=false' 'del(.head.repo)' '.head.repo={}' \
  '.head.repo.full_name=17'; do
  reset; PULLS="$(jq -cn --argjson p "$(pr topic | jq "$change")" '[[$p]]')"; inventories
  cli branches --user alice --auto
  check "malformed PR $change rejected" rejected
  check "malformed PR $change no effects" no_effects
done
reset
PULLS="$(jq -cn --argjson p "$(pr topic)" '[[$p,($p|.number=2|.user.login="bob")]]')"
inventories; cli branches --user alice --all --auto
expect_candidates 'conflicting same-head authors' '[]'
check 'conflicting authors no effects' no_effects
reset
PULLS="$(jq -cn --argjson p "$(pr topic)" '[[$p,$p]]')"
inventories; cli branches --user alice --all --auto
check 'duplicate PR inventory rejected' rejected
check 'duplicate PR inventory no effects' no_effects

# Repository B's default branch must not protect an unrelated candidate in A.
reset
mkdir -p "$FIX/repo/a/.git" "$FIX/repo/b/.git"
route git "$(reply .git)" rev-parse --git-common-dir
route gh ' [{"out":"example/widgets"},{"out":"example/tools"},{"out":"example/widgets"},{"out":"example/tools"}]' \
  repo view --json nameWithOwner --jq .nameWithOwner
route gh ' [{"out":"main"},{"out":"topic"},{"out":"main"},{"out":"topic"}]' \
  repo view --json defaultBranchRef --jq .defaultBranchRef.name
for entry in a b; do
  dir="$FIX/repo/$entry"; repo=example/widgets
  [[ "$entry" != b ]] || repo=example/tools
  route git "$(reply "https://github.com/$repo.git")" -C "$dir" remote get-url origin
  route git "$(reply "https://github.com/$repo.git")" -C "$dir" remote get-url --push --all origin
  route git "$(trees_reply "$(tree "$dir" main)")" -C "$dir" worktree list --porcelain -z
  route git "$(reply '')" -C "$dir" for-each-ref '--format=%(refname:short)%09%(objectname)' refs/heads
  if [[ "$entry" == a ]]; then
    route gh "$(jq -cn --argjson p "$(pr topic)" '[{out:([[$p]]|tojson)}]')" api "repos/$repo/pulls?state=all&per_page=100" --paginate --slurp
    route git "$(reply "$(printf '%s\trefs/heads/topic' "$OID")")" -C "$dir" ls-remote --heads origin
    for flag in gh-poi-locked gh-poi-protected; do
      route git "$(reply '' 1)" -C "$dir" config --type=bool --get "branch.topic.$flag"
    done
    route git "$(reply '')" -C "$dir" push "--force-with-lease=refs/heads/topic:$OID" origin :refs/heads/topic
  else
    route gh "$(reply '[[]]')" api "repos/$repo/pulls?state=all&per_page=100" --paginate --slurp
    route git "$(reply '')" -C "$dir" ls-remote --heads origin
  fi
done
cli remote --depth 1 --user alice --auto
check 'multiple repository execution status' eq "$RC" 0
expect_candidates 'repository-specific default protection' '[["remote","topic"]]'
check 'multiple repository execution summary' contains 'Results: completed=1 skipped=0 failed=0'
check 'only captured repository A is mutated' eq \
  "$(jq -sc '[.[] | select(.effect) | .args[1]]' "$MOCK_LEDGER")" "$(jq -cn --arg dir "$FIX/repo/a" '[$dir]')"
: > "$MOCK_LEDGER"
route gh "$(reply 'second repository API failed' 1)" api 'repos/example/tools/pulls?state=all&per_page=100' --paginate --slurp
cli remote --depth 1 --user alice --auto
check 'second repository failure rejects whole request' rejected
check 'second repository failure prevents first repository effect' no_effects

# Exercise the boundary itself; unknown read failures cannot hide as empty output.
for tool in gh git; do
  reset; rc=0; "$tool" unexpected read >/dev/null 2>&1 || rc=$?
  check "$tool unknown exit" eq "$rc" 97
  check "$tool unknown ledger" ledger 'length == 1 and .[0].known == false'
done
printf 'Branch tests: %s passed, %s failed\n' "$passes" "$failures"
[[ "$failures" -eq 0 ]]
