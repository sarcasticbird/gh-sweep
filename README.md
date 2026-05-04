# gh-sweep

Git worktrees and branches pile up fast when you're running parallel Claude Code sessions, reviewing PRs, or just moving between features. `gh sweep` cleans them up in one shot — across multiple repos if you want.

It wraps [gh-poi](https://github.com/seachicken/gh-poi) to correctly identify squash-merged branches (which `git branch --merged` misses), adds the worktree-awareness layer that `gh-poi` lacks, and walks multiple repos in a single invocation.

## Install

```sh
gh extension install sarcasticbird/gh-sweep
```

Requires [gh-poi](https://github.com/seachicken/gh-poi) — you'll be prompted to install it on first run.

## Usage

```sh
gh sweep [flags]
```

### Flags

| Flag | Description |
|------|-------------|
| `--local` | Remove worktrees + delete local branches only |
| `--remote` | Delete remote branches only |
| `--all` | Include all authors' remote branches (default: yours only) |
| `--orphans` | Clean up local branches with no PR and no remote tracking |
| `--depth N` | How many directory levels to walk for repos (default: 1) |
| `--dry-run` | Show what would happen, don't act |
| `--force` | Skip confirmation prompts |
| `--verbose` | Show detail even when nothing to clean |
| `--version` | Print version |
| `--help` | Show help |

Flags combine freely: `gh sweep --local --force`, `gh sweep --orphans --dry-run`, `gh sweep --remote --all --depth 2`, etc.

### Examples

```sh
# Preview what would be cleaned in the current repo
gh sweep --dry-run

# Clean current repo — worktrees, local branches, and your remote branches
gh sweep

# Clean only local worktrees and branches
gh sweep --local

# Clean only your remote branches
gh sweep --remote

# Include other authors' remote branches
gh sweep --all

# Also clean up abandoned local-only branches (no PR, no remote)
gh sweep --orphans

# Walk all repos in a directory
cd ~/Projects/VoiceBrain && gh sweep --dry-run

# Walk two levels deep (e.g., from ~/Projects into ~/Projects/VoiceBrain/vb-*)
gh sweep --depth 2 --dry-run

# Full cleanup, no prompts
gh sweep --all --orphans --force
```

## What it does

1. **Discovers repos** — if you're in a git repo, it operates on that one. Otherwise it walks subdirectories looking for git repos (configurable depth via `--depth`).
2. **Fetches** — runs `git fetch --prune` to sync remote tracking state.
3. **Identifies merged branches** — uses `gh poi` to detect branches whose PRs were merged on GitHub, including squash merges.
4. **Removes stale worktrees** — finds worktrees checked out on merged branches and removes them. Skips worktrees with uncommitted changes.
5. **Deletes local branches** — uses `gh poi` to clean up local branches whose PRs are merged.
6. **Deletes remote branches** — pushes deletions to origin. Defaults to only your branches; use `--all` for all authors.
7. **Cleans orphan branches** (with `--orphans`) — deletes local branches that have no PR and no remote tracking, with individual confirmation for each.

## Author filtering

Remote branch deletion defaults to branches authored by the current GitHub user (determined via `gh api user`). This prevents accidentally deleting teammates' remote branches in shared repos.

| Scope | Default behavior | With `--all` |
|-------|-----------------|--------------|
| Local (worktrees + branches) | All merged branches | Same |
| Remote (`git push --delete`) | Your branches only | All authors |
| Orphans (`--orphans`) | All local orphans | N/A |

When branches are skipped due to author filtering, a summary is always shown:
```
Skipped 3 remote branches by other authors (use --all to include)
```

Use `--verbose` to see which specific branches were skipped and their authors.

## Safety

- Never touches `main`, `master`, or `develop` (enforced by gh-poi)
- Skips worktrees with uncommitted changes (warns instead of removing)
- Asks for confirmation before destructive actions (override with `--force`)
- Remote deletion scoped to your branches by default
- Orphan deletion confirms each branch individually
- Use `gh poi lock <branch>` to protect specific branches

## License

MIT
