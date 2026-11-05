# gh-sweep

Preview and clean merged branches, worktrees, stale Actions caches, workflow
runs, notifications, and PR review threads across GitHub repositories.

```sh
gh extension install sarcasticbird/gh-sweep
gh sweep --dry-run
```

Requires Bash 4+, Git, `gh` and `jq`. Tools must be installed explicitly.
The extension's `#!/usr/bin/env bash` selects Bash from `PATH`, not your login
shell. macOS ships Bash 3.2; unsupported Bash is rejected before repository
discovery, API calls or cleanup. Install a current Bash explicitly, then use its
directory for just this invocation (replace the example path):

```sh
env PATH="/absolute/path/to/new-bash/bin:$PATH" gh sweep branches --dry-run
```

This does not change shell configuration or saved `PATH`. The extension does not
install Bash or modify either for you.
`gh-sweep` never installs a dependency, invokes `gh-poi`, fetches/prunes refs,
or prunes repository-wide worktree metadata, including during preview.

## Commands

| Command | Scope |
| --- | --- |
| No command | Branches, orphans, caches, runs, notifications |
| `branches` | Merged local/remote branches and their clean linked worktrees |
| `local` | Merged local branches and clean linked worktrees |
| `remote` | Merged remote branches |
| `orphans` | Local branches with no PR, upstream or remote head |
| `runs` | Older eligible workflow runs after retention |
| `caches` | Caches for absent branches or closed PRs |
| `notifications` | Unread notifications for discovered repositories |
| `comments <pr>` | Unresolved review threads on a PR |

Literal positional `all` is not a command. Bare invocation selects a full sweep;
`--all` is a flag that broadens eligible authors/conclusions, not a safety bypass.

## Flags

| Flag | Meaning |
| --- | --- |
| `--dry-run` | Display the exact plan without executing effects |
| `--auto` | Display the plan and execute without waiting for input |
| `--user LOGIN` | Restrict run actors and branch PR authors; skip unsupported categories |
| `--keep-runs N` | Keep newest N eligible runs per workflow; default 5, positive integers only |
| `--include-failed` | Independently opt failed-family runs into eligibility and retention |
| `--all` | Include all remote branch authors and other known non-failed run conclusions |
| `--depth N` | Discover repositories N directory levels down; default 0 (current repo) |
| `--verbose` | Accepted for scripts; exact candidates and safety diagnostics are always shown |
| `--version`, `--help` | Version or usage |

```sh
gh sweep runs --user alice --dry-run
gh sweep runs --include-failed --keep-runs 10 --dry-run
gh sweep --user alice --all --dry-run
gh sweep branches --depth 2 --dry-run
gh sweep comments 42 --dry-run
```

## Run Retention

Run attribution is **`actor.login`**, the original initiator, never
`triggering_actor`, which can differ for a rerun. Login comparisons are
case-insensitive. Explicit null attribution is excluded; missing or malformed
required evidence invalidates the entire plan. This applies even without
`--user`, so unattributed runs cannot become actionable through broad flags.

Only known `completed` runs enter conclusion selection. Active runs with a null
conclusion are valid exclusions. Unknown states/conclusions and completed/null
records invalidate the plan instead of deleting a valid subset.

| Flags | Eligible conclusions |
| --- | --- |
| Neither | `success` |
| `--include-failed` | `success`, `failure`, `timed_out`, `startup_failure` |
| `--all` | `success`, `cancelled`, `neutral`, `skipped`, `action_required`, `stale` |
| Both | All nine known conclusions above |

**Changed from the previous version:** `--all` alone does not include failed
runs. The failed-family opt-in is independent and never bypasses retention.

After attribution/status/conclusion filtering, each repository's runs are
partitioned by `workflow_id`, not branch, name or rerun attempt. Each workflow's
newest N eligible runs are retained in descending `created_at` order, then
descending numeric run ID for ties. The opted-in union consumes the same slots:
a recent failed run within the newest five stays kept. Every retained and
candidate run ID is displayed, together with total/retained/skipped counts.

Listings are unfiltered on the server to avoid GitHub's 1,000-result filtered
search cap. All pages must succeed, have valid schemas and stable totals, and
reconcile to the exact unique run count. A changing/incomplete inventory fails
closed. Required fields are run ID, workflow ID, attempt, creation timestamp,
status, conclusion, and actor structure. Triggering actor and display names
are not required selection evidence.

## Attribution Boundaries

With `--user`, caches, notifications, orphan branches, unsupported comments and
repository-wide worktree metadata are explicitly marked **not enumerated**,
with individual missing-attribution reasons. They are not reported as zero
discovered resources. These notices also appear for empty plans and standalone
requests, before confirmation and in dry runs. `--all` and `--auto` cannot
reenable them.

Branch cleanup reads complete PR inventories directly, rather than delegating
to `gh-poi`. A merged PR must belong to the origin repository and bind the
exact branch tip SHA. PR author, workflow actor and commit author are different
identities. Conflicting/null PR authors or an open PR prevent deletion.
Remote branches default to the authenticated user's PRs; local branches default
to all PR authors. Explicit `--user` restricts both scopes, even with `--all`.

`main`, `master`, `develop`, the repository default branch, gh-poi locked or
protected local branches, sweep-root worktrees and dirty/locked/unreadable
worktrees are protected.
Untracked files are checked explicitly regardless of `status.showUntrackedFiles`;
the removal command also forces that guard so a late file is not hidden by config.
Origin must be a verifiable github.com SSH/HTTPS URL matching the selected
repository. Unsupported origins fail closed.
Push URLs must be a single matching destination; a distinct push URL fails closed.
Squash merges work because selection uses the merged PR's head SHA, not git ancestry.
Local ref deletion checks the captured old OID atomically; remote deletion
uses an explicit old-OID lease. No broad delegate can add unseen branches.
Git hooks and fsmonitor hooks are disabled for all invocations, including reads.

Repository-wide metadata pruning is now skipped in **all modes**, not just
user mode: Git's broad prune cannot promise to touch only the displayed records.
Stale metadata is left intact for a separate explicit maintenance operation.

## Preview And Execution

All requested repositories/categories are enumerated and validated before any
effect, including in a full sweep. Candidates are rendered as escaped JSON
identities. Confirmation defaults to no; EOF/refusal has no effects.
Noninteractive execution requires explicit `--auto`. No matches is explicit.

After confirmation, the whole inventory is revalidated before the first effect.
Only unchanged captured candidates may proceed; the new inventory may narrow
the plan but never add unseen candidates. Run details and local branch/worktree
safety are checked again at their effect boundary. This is not an atomic GitHub
snapshot: concurrent changes can invalidate a candidate, and the tool skips it
or reports a failed conditional effect rather than promising a transaction.

Results report completed, skipped and failed candidates. Failures return nonzero,
even after partial work. A notification is one candidate with two effects
(PATCH read, then DELETE done); a failed second effect is still a failed
candidate and may leave it read. No rollback or complete-success claim is made.

## Development

Flox is optional inside Coop containers. Tests and lint can use the container's
supported tools directly, with their versions recorded in the evidence.
The repository-owned Flox manifest remains available for local development and
contains only Bash, coreutils, findutils, Git, `gh`, `jq` and ShellCheck.
Activation has no hooks or services. All GitHub,
delegate and cleanup effects in safety tests are exact-argv mocks. The existing
discovery suite creates and removes only its own temporary git fixtures.

```sh
bash tests/check.sh
# Optional local development environment:
flox activate -- bash tests/check.sh
```

The extension tests use an installed `gh` to dispatch a private copied extension,
with product GitHub/Git calls mocked. Set `SWEEP_TEST_GH_CLI` to an absolute CLI
path if `gh` on `PATH` is a wrapper. Set `SWEEP_TEST_LEGACY_BASH` to an already
installed Bash 3.2 to reproduce the library failure and verify early rejection.
Without it, the suite labels that check skipped; the synthetic version-gate
test is not macOS or Bash 3.2 execution evidence.

The matching `.flox/env/manifest.lock` is recorded. Activation uses that lock;
changing or resolving dependencies may require FloxHub catalog authentication.

See
[implementation evidence](docs/retention-preview-evidence.md) for the source pin,
API/delegate contracts, fixture oracles, exact commands and current limitations.

## License

MIT
