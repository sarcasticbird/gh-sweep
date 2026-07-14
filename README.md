# gh-sweep

Git worktrees, branches, and review threads pile up fast when you're running parallel Claude Code sessions, reviewing PRs, or just moving between features. `gh sweep` cleans them up in one shot — across multiple repos if you want.

It wraps [gh-poi](https://github.com/seachicken/gh-poi) to correctly identify squash-merged branches (which `git branch --merged` misses), adds the worktree-awareness layer that `gh-poi` lacks, walks multiple repos in a single invocation, can bulk-resolve PR review threads, and cleans up stale GitHub Actions caches and workflow runs.

## Install

```sh
gh extension install sarcasticbird/gh-sweep
```

Requires [gh-poi](https://github.com/seachicken/gh-poi) for branch commands — you'll be prompted to install it on first run.

## Usage

```sh
gh sweep [command] [flags]
```

### Commands

| Command | Description |
|---------|-------------|
| *(default)* | Full sweep: branches, orphans, caches, runs, notifications |
| `branches` | Clean merged branches + worktrees (local and remote) |
| `local` | Remove worktrees + delete local branches only |
| `remote` | Delete remote branches only |
| `orphans` | Clean up local branches with no PR and no remote tracking |
| `comments <pr>` | Resolve all unresolved review threads on a PR |
| `caches` | Delete Actions caches for branches that no longer exist |
| `runs` | Delete successful workflow runs (`--all` for all terminal statuses) |
| `notifications` | Mark unread notifications as read and done |

### Flags

| Flag | Description |
|------|-------------|
| `--all` | Include all authors' remote branches; for `runs`, include all terminal statuses |
| `--depth N` | How many directory levels to walk for repos (default: 0, current repo) |
| `--dry-run` | Show what would happen, don't act |
| `--auto` | Skip confirmation prompts |
| `--verbose` | Show detail even when nothing to clean |
| `--version` | Print version |
| `--help` | Show help |

### Examples

```sh
# Full sweep — branches, orphans, caches, runs, notifications
gh sweep

# Preview everything that would be cleaned
gh sweep --dry-run

# Just merged branches + worktrees
gh sweep branches

# Clean only local worktrees and branches
gh sweep local

# Clean only your remote branches
gh sweep remote

# Include other authors' remote branches
gh sweep remote --all

# Clean up abandoned local-only branches (no PR, no remote)
gh sweep orphans

# Walk all repos in a directory
cd ~/Projects/VoiceBrain && gh sweep --dry-run

# Walk two levels deep
gh sweep --depth 2 --dry-run

# Full branch cleanup, no prompts
gh sweep --all --auto

# Resolve all review threads on PR #42
gh sweep comments 42

# Preview which threads would be resolved
gh sweep comments 42 --dry-run

# Delete Actions caches for dead branches
gh sweep caches

# Preview which caches would go
gh sweep caches --dry-run

# Delete completed workflow runs
gh sweep runs

# Delete all terminal workflow runs (not just completed)
gh sweep runs --all

# Clear unread notifications for the current repo
gh sweep notifications

# Clear notifications across all repos two levels down
gh sweep notifications --depth 2
```

## What it does

### Default (full sweep)

Running bare `gh sweep` performs a full sweep: branches, orphans, caches, runs, and notifications. You'll be prompted to confirm before anything runs (skip with `--auto`).

### Branch commands (`branches`, `local`, `remote`)

1. **Discovers repos** — if you're in a git repo, it operates on that one. Otherwise it walks subdirectories looking for git repos (configurable depth via `--depth`).
2. **Fetches** — runs `git fetch --prune` to sync remote tracking state.
3. **Reports dead worktree metadata** — local cleanup prunes these records only after confirmation (`--dry-run` only reports them).
4. **Identifies merged branches** — uses `gh poi` for local branches and verifies linked worktree tips against merged PR commits, including squash merges.
5. **Removes stale worktrees** — finds worktrees checked out on merged branches and removes them. Skips dirty or locked worktrees.
6. **Deletes local branches** — uses `gh poi` to clean up local branches whose PRs are merged.
7. **Deletes remote branches** — pushes deletions to origin. Defaults to only your branches; use `--all` for all authors.

### `orphans`

Deletes local branches that have no associated PR and no remote tracking branch. Confirms each deletion individually (skip prompts with `--auto`).

### `comments <pr>`

Resolves all unresolved review threads on the specified PR using the GitHub GraphQL API. Auto-detects the repository from the current directory.

### `caches`

Deletes GitHub Actions caches associated with branches that no longer exist on the remote. Caches pile up from feature branches, dependabot PRs, and worktree-based workflows — this cleans them in one shot.

- Compares each cache's `ref` against active remote branches
- Caches for `refs/pull/*/merge` are checked against PR state (deleted if PR is closed/merged)
- Shows total size reclaimed
- Use `--verbose` to see individual stale cache entries

### `runs`

Deletes workflow runs from the repository. By default only deletes successful runs. Use `--all` to include all terminal statuses (cancelled, failure, skipped, timed_out, etc.). Never deletes in-progress, queued, or waiting runs.

- Use `--verbose` to see individual run details before deletion

### `notifications`

Marks unread notifications for the discovered repos as both read and done — clears them entirely from your inbox. Filters by repo so only notifications tied to walked repos are affected.

- Use `--verbose` to see notification subjects before clearing
- Default depth 0 means "current repo only"; `--depth N` walks subdirectories

## Author filtering

Remote branch deletion defaults to branches authored by the current GitHub user (determined via `gh api user`). This prevents accidentally deleting teammates' remote branches in shared repos.

| Scope | Default behavior | With `--all` |
|-------|-----------------|--------------|
| Local (worktrees + branches) | All merged branches | Same |
| Remote (`git push --delete`) | Your branches only | All authors |
| Orphans | All local orphans | N/A |

When branches are skipped due to author filtering, a summary is always shown:
```
Skipped 3 remote branches by other authors (use --all to include)
```

Use `--verbose` to see which specific branches were skipped and their authors.

## Safety

- Never touches `main`, `master`, or `develop` (enforced by gh-poi)
- Skips dirty or locked worktrees (warns instead of removing)
- Asks for confirmation before destructive actions (skip with `--auto`)
- Remote deletion scoped to your branches by default
- Orphan deletion confirms each branch individually
- Use `gh poi lock <branch>` to protect specific branches

## License

MIT
