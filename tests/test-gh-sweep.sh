#!/usr/bin/env bash
# Tests for gh-sweep repo discovery and worktree handling.
# Builds throwaway git fixtures under mktemp and sources gh-sweep for its
# functions (the script skips main() when sourced). No network, no gh calls.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gh-sweep"

set --
# shellcheck source=../gh-sweep
source "$SCRIPT"

# hermetic git: no reliance on the host's identity or global config
export GIT_AUTHOR_NAME="gh-sweep-test" GIT_AUTHOR_EMAIL="test@localhost"
export GIT_COMMITTER_NAME="gh-sweep-test" GIT_COMMITTER_EMAIL="test@localhost"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

FIX="$(cd "$(mktemp -d)" && pwd -P)"
TREE="$FIX/tree"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$TREE"

fail=0

check_discover() {
  local desc="$1" depth="$2" dir="$3" expected="$4"
  local got
  got="$(cd "$dir" && DEPTH="$depth" discover_repos 2>/dev/null | sort)" || got="(error exit)"
  if [[ "$got" == "$expected" ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected: $(echo "$expected" | tr '\n' '|')"
    echo "  got:      $(echo "$got" | tr '\n' '|')"
    fail=1
  fi
}

# --- fixtures -----------------------------------------------------------
# regular1/                regular repo, with a submodule at regular1/sub
# container/{.bare,main,feature-x}     bare layout, protected worktree
# container2/{.bare,feature-y}         bare layout, no protected worktree
# container3/{.bare,main,trunk}        dir names disagree with branches:
#                                      main/ has feature-z, trunk/ has main
# nested/regular2/         regular repo one level deeper
# plainfolder/             nothing

git init -q -b main "$TREE/regular1"
git -C "$TREE/regular1" commit -q --allow-empty -m init

git init -q -b main "$FIX/subsrc"
git -C "$FIX/subsrc" commit -q --allow-empty -m init
git -C "$TREE/regular1" -c protocol.file.allow=always submodule add -q "$FIX/subsrc" sub

mkdir -p "$TREE/container" "$TREE/container2" "$TREE/container3" "$TREE/nested" "$TREE/plainfolder"

git clone -q --bare "$TREE/regular1" "$TREE/container/.bare"
git -C "$TREE/container/.bare" worktree add -q "$TREE/container/main" main
git -C "$TREE/container/.bare" worktree add -q "$TREE/container/feature-x" -b feature-x

git clone -q --bare "$TREE/regular1" "$TREE/container2/.bare"
git -C "$TREE/container2/.bare" worktree add -q "$TREE/container2/feature-y" -b feature-y

git clone -q --bare "$TREE/regular1" "$TREE/container3/.bare"
git -C "$TREE/container3/.bare" worktree add -q "$TREE/container3/main" -b feature-z
git -C "$TREE/container3/.bare" worktree add -q "$TREE/container3/trunk" main

git init -q -b main "$TREE/nested/regular2"
git -C "$TREE/nested/regular2" commit -q --allow-empty -m init

# --- discovery ----------------------------------------------------------

check_discover "depth 1 finds regular and bare-layout repos, excludes submodule and deeper repos" 1 "$TREE" \
"$TREE/container/main
$TREE/container2/feature-y
$TREE/container3/trunk
$TREE/regular1"

check_discover "depth 2 adds nested repo, worktrees still deduped" 2 "$TREE" \
"$TREE/container/main
$TREE/container2/feature-y
$TREE/container3/trunk
$TREE/nested/regular2
$TREE/regular1"

check_discover "dedupe prefers checked-out protected branch over directory name" 1 "$TREE" \
"$TREE/container/main
$TREE/container2/feature-y
$TREE/container3/trunk
$TREE/regular1"

check_discover "no repos in walk range errors" 1 "$TREE/plainfolder" "(error exit)"

check_discover "depth 0 inside a repo returns that repo" 0 "$TREE/regular1" "$TREE/regular1"

# --- sweep-root preservation --------------------------------------------
# The worktree a sweep operates from must never be removed, even when its
# branch is in the merged set.

if ! local_safe "$TREE/container2/feature-y" feature-y "$(worktrees "$TREE/container2/feature-y")"; then
  echo "PASS: sweep root worktree is never removed"
else
  echo "FAIL: sweep root worktree is never removed"
  fail=1
fi

# --- untracked data protection with real disposable Git -------------------
safety_root="$FIX/worktree-safety"
hidden_path="$FIX/hidden-untracked"
race_path="$FIX/late-untracked"
clean_path="$FIX/clean-removal"
git init -q -b main "$safety_root"
git -C "$safety_root" commit -q --allow-empty -m init
git -C "$safety_root" config status.showUntrackedFiles no
git -C "$safety_root" worktree add -q -b hidden-topic "$hidden_path"
printf '%s\n' 'synthetic untracked data' > "$hidden_path/untracked.txt"
if local_safe "$safety_root" hidden-topic "$(worktrees "$safety_root")"; then
  echo 'FAIL: hidden untracked files make a worktree ineligible'
  fail=1
else
  echo 'PASS: hidden untracked files make a worktree ineligible'
fi

git -C "$safety_root" worktree add -q -b race-topic "$race_path"
oid="$(git -C "$safety_root" rev-parse HEAD)"
action="$(jq -nc --arg dir "$safety_root" --arg path "$race_path" --arg oid "$oid" \
  '{kind:"worktree",repo:"example/widgets",dir:$dir,path:$path,branch:"race-topic",oid:$oid,default_branch:"main"}')"
rc=0
out="$(
  # Inject only after the real clean status check, before the real removal.
  # This simulates a concurrent writer without modifying any user workspace.
  git() {
    local status=0
    command git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@" || status=$?
    if [[ "$status" -eq 0 && "${1:-}" == --no-optional-locks && "${2:-}" == -C && "${3:-}" == "$race_path" && "${4:-}" == status ]]; then
      printf '%s\n' 'synthetic concurrent data' > "$race_path/late.txt"
    fi
    return "$status"
  }
  effect "$action" 2>&1
)" || rc=$?
if [[ "$rc" -eq 1 && -f "$race_path/late.txt" && "$(< "$race_path/late.txt")" == 'synthetic concurrent data' ]]; then
  echo 'PASS: removal independently preserves late untracked files despite hidden status configuration'
else
  echo 'FAIL: removal independently preserves late untracked files despite hidden status configuration'
  echo "  status=$rc output=$out"
  fail=1
fi

git -C "$safety_root" worktree add -q -b clean-topic "$clean_path"
action="$(jq -nc --arg dir "$safety_root" --arg path "$clean_path" --arg oid "$oid" \
  '{kind:"worktree",repo:"example/widgets",dir:$dir,path:$path,branch:"clean-topic",oid:$oid,default_branch:"main"}')"
rc=0
effect "$action" || rc=$?
if [[ "$rc" -eq 0 && ! -d "$clean_path" ]]; then
  echo 'PASS: clean disposable worktree removal still succeeds with hidden status configuration'
else
  echo 'FAIL: clean disposable worktree removal still succeeds with hidden status configuration'
  fail=1
fi

exit "$fail"
