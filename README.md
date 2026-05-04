# gh-sweep

A GitHub CLI extension that cleans up git worktrees and branches whose PRs have been merged.

Wraps [gh-poi](https://github.com/seachicken/gh-poi) with worktree awareness and multi-repo support. Handles squash merges correctly.

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
| `--dry-run` | Show what would happen, don't act |
| `--force` | Skip confirmation prompts |
| `--verbose` | Show detail even when nothing to clean |
| `--version` | Print version |
| `--help` | Show help |

Flags combine freely: `gh sweep --local --force`, `gh sweep --remote --all --dry-run`, etc.

### Examples

```sh
# Preview what would be cleaned
gh sweep --dry-run

# Clean current repo — local branches + your remote branches
gh sweep

# Clean only local worktrees and branches (all authors, always)
gh sweep --local

# Clean only your remote branches
gh sweep --remote

# Clean everyone's remote branches
gh sweep --remote --all

# Full sweep including other authors' remote branches, no prompts
gh sweep --all --force

# Walk all repos in a directory
cd ~/Projects/VoiceBrain && gh sweep --dry-run
```

## What it does

1. **Discovers repos** — if you're in a git repo, it cleans that one. Otherwise it walks one level of subdirectories looking for git repos.
2. **Fetches** — runs `git fetch --prune` to sync remote tracking state.
3. **Identifies merged branches** — uses `gh poi` to detect branches whose PRs were merged on GitHub (including squash merges).
4. **Removes stale worktrees** — finds worktrees checked out on merged branches and removes them. Skips worktrees with uncommitted changes.
5. **Deletes local branches** — uses `gh poi` to clean up local branches.
6. **Deletes remote branches** — pushes deletions to origin. Defaults to only your branches; use `--all` for all authors.

## Author filtering

Remote branch deletion defaults to branches authored by the current GitHub user (determined via `gh api user`). This prevents accidentally deleting teammates' remote branches in shared repos.

| Scope | Default behavior | With `--all` |
|-------|-----------------|--------------|
| Local (worktrees + branches) | All merged branches | Same (no change) |
| Remote (`git push --delete`) | Your branches only | All authors |

When branches are skipped due to author filtering, a summary line is always shown:
```
Skipped 3 remote branches by other authors (use --all to include)
```

Use `--verbose` to see which specific branches were skipped and their authors.

## Safety

- Never touches `main`, `master`, or `develop` (enforced by gh-poi)
- Skips worktrees with uncommitted changes (warns instead of removing)
- Asks for confirmation before destructive actions (override with `--force`)
- Remote branch deletion scoped to your branches by default
- Use `gh poi lock <branch>` to protect specific branches from deletion

## License

MIT
