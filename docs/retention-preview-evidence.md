# Retention And Preview Evidence

Status: author implementation validation passes with the recorded supported
tools on Linux aarch64. The retained Flox environment is optional inside Coop.
Independent engineering review and exact-artifact
QA remain required; this document does not claim their clearance or delivery.
QA environment revision: `gh-sweep-attributable-retention-preview-hermetic-v1`.

## Source And Contract

Before engineering, `git ls-remote origin refs/heads/main` and local HEAD both
identified `de9b32cace62e9a97b3ed86428fc17bc62338993`. The complete tracked tree
had the executable, README, LICENSE and discovery tests, with no repository
instructions, Flox environment, dependency lock or CI workflow. The prior
executable SHA256 was
`a0c4eade7433b749c46e018cbd134dc818b466336e326f1b6de2310208aebdc6`.

| Contract | Pinned Baseline | Implementation / Evidence |
| --- | --- | --- |
| Actor/status/conclusion filtering before per-workflow union retention | `gh-sweep` 811-879 omitted actor/status/workflow/retention | `lib/runs.jq`; exact-ID and per-conclusion matrix |
| Strict selectors, default five and explicit tie order | Parser 62-110 had no user/keep/failed flags | Entrypoint parser; descending creation time then numeric ID; invalid selector fixtures |
| Complete fail-closed enumeration before effects | Filtered listing 824-829 could cap at 1,000 | Unfiltered paginated/slurped runs, schema/total/uniqueness validation; up to 1,005-run fixtures and interrupted/malformed pages |
| No installs/fetch/prune/delegate effects in preview | 112-134 installed; 983-999 fetched; 539 delegated unbounded cleanup | No reachable delegate/install/fetch/prune path; exact-argv mock allowlist and effect ledger |
| Bounded user exclusions at all entry points | Caches 694-793, notifications 898-965, orphans 319-389, metadata 423-457/542/1066-1072 and comments 604-692 were unscoped | Planner emits each exclusion/reason before discovery/effects; standalone/full/empty/auto/all fixtures |
| Exact candidate plan before confirmation | Full sweep 1106-1125 confirmed before enumeration | Whole-request captured JSON plan and narrowing-only revalidation |
| Failures are not successful complete cleanup | Several old loops returned success after failed mutations | Explicit completed/skipped/failed summary and nonzero execution failures, including notification PATCH and GraphQL |
| Existing protected-resource/root safety | Protected-branch/delegate and worktree checks | Direct SHA-bound PR selection, typed lock flags, protected default branch, root/dirty/locked fixtures, conditional local/remote effects |

## External Evidence

- [GitHub actor documentation at immutable docs revision](https://github.com/github/docs/blob/33b1f4a6fec2d9b6fd3d374afa56bcd9f0875b57/content/actions/reference/workflows-and-actions/contexts.md): actor is the original initiator; triggering actor may differ for reruns. The matching [triggering-actor explanation](https://github.com/github/docs/blob/33b1f4a6fec2d9b6fd3d374afa56bcd9f0875b57/data/reusables/actions/github-triggering-actor-description.md) distinguishes those identities and privileges.
- [Pinned GitHub CLI conclusion constants](https://github.com/cli/cli/blob/9490d204a2ba95434153dedce99898ce9f281426/pkg/cmd/run/shared/shared.go): all nine known conclusions, including `startup_failure`. GitHub's pinned [GraphQL schema](https://github.com/github/docs/blob/33b1f4a6fec2d9b6fd3d374afa56bcd9f0875b57/src/graphql/data/ghes-3.20/schema.docs-enterprise.graphql) independently defines startup failure. REST search enums are not an exhaustive response vocabulary.
- [List workflow runs](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-repository): max 100 per page and a 1,000-result cap for searches filtered with actor/branch/check_suite_id/created/event/head_sha/status. `--paginate` does not remove that cap. This implementation sends only `per_page`, validates the returned total across pages, and fails closed on count/identity disagreement. Pagination transport relies on the explicit successful `gh --paginate --slurp` contract; it does not infer completeness from one successful page.
- Pinned [gh-poi revision `26bdd2c3185969f324fb12bcbe41200a198a61e9`](https://github.com/seachicken/gh-poi/tree/26bdd2c3185969f324fb12bcbe41200a198a61e9): `main.go`, `cmd/root.go` and `conn/command.go` show cleanup/checkout/fetch/prune effects and normal dry-run guards; lock commands write git config. Crucially, its `gh-poi` shell launcher builds `gh-poi.out` **before** passing arguments, including help/dry-run. Static pinned source is not installed executable parity. The new product invokes no gh-poi executable, so neither unknown installed behavior nor binary/source equivalence is trusted at any protected boundary.
- Pinned public raw gh-sweep source, local tracked entry and workspace baseline shared Git blob `f4aa017962dc7c5b64f55dec6a7578a3db727a98`. The baseline is a shell extension without a build/distribution pipeline; latest-release API returned 404. This verifies source/script distribution parity, not an arbitrary installed extension or an unobserved release binary. No install was performed to obtain evidence.

## Hermetic Fixtures

`tests/test-safety.sh` builds private synthetic inventories; `tests/mock-bin/gh`
and `git` accept exact argv routes only. The test PATH has no real gh/git or
install fallback. Every attempted boundary call is written in order to JSONL,
including unknown calls, which are refused and conservatively marked effectful.
The ledger retains both raw argv and logical argv (with the fixed Git hook/
fsmonitor disabling prefix separated for route matching). Every CLI fixture
also asserts that each Git invocation has that protection. Known effect routes
include DELETE, PATCH, GraphQL mutations, worktree removal,
old-OID ref deletion and remote leased deletion. Install/fetch/prune/delegate
calls have no product allowlist route. Preview/refusal/error fixtures require
both known routes and zero effects. Temporary fixture data is removed afterward.

The run matrix covers 0/1/5/6/23/205/1,005 runs, multiple workflows and users,
all nine conclusions and all/failed/user/auto combinations; actor versus
triggering actor; explicit null versus absent/malformed fields; active/null
versus completed/null; timestamp ties and rerun attempts; invalid keep values;
duplicate/interrupted/malformed pages and API/auth failures. Exact retained and
candidate identities are repository-qualified, not just counts.

The separately named reconstructed `example/widgets` 14-record discriminator
keeps its identities distinct from `example/tools`. With user Alice/default
five, success-only candidates are `{106}` and retained are
`{101,102,103,104,105,112,114}`. With failed opt-in, candidates are
`{105,106,107}` and retained are `{101,102,103,104,111,112,114}`. Recent failure
111 stays kept; newer Bob run 113 does not consume Alice's slots; workflow 20's
112/114 remain independently retained. A separate nine-conclusion matrix
distinguishes the failed family from other terminal conclusions.

`tests/test-branches.sh` covers local/remote/branches/full-sweep combinations,
selected user/all/auto, exact OIDs and leased effects, protected branches,
locks, dirty worktrees, root preservation, worktree inventory order, PR schema
and attribution failures, later-category enumeration failure and narrowing.
Two-repository fixtures verify that each captured action retains its own default
branch identity, and that an API failure in repository B prevents effects in A.
The original discovery suite retains bare-layout/depth/submodule/root checks.
It also uses real Git only in private disposable fixtures to reject hidden
untracked data, inject an untracked file between the clean status check and
removal, and verify that the removal command itself refuses rather than deleting
that file. A clean-removal control still succeeds. No fixture accesses user
workspaces or performs live GitHub cleanup.

## Review Fixes

[Hawk's independent review of fa6f231](https://github.com/sarcasticbird/gh-sweep/pull/9#pullrequestreview-5724719173)
identified two defects. Both were reproduced before the product fix: the real
Git suite failed two new safety checks, and branch fixtures failed 12 assertions
for orphan names colliding with remote `topic-extra` or `topic/child` refs.

The fix makes untracked enumeration explicit during `local_safe` and forces
`status.showUntrackedFiles=all` on the removal command independently. It also
matches the complete remote ref at a record boundary, not a prefix. The branch
matrix covers standalone orphans and full sweeps, previews and execution, no
remote ref, both prefix collisions, and an exact ref as either the first or last
record. Only the exact ref excludes the orphan candidate. The new head requires
renewed independent review and separate QA; author red/green checks are not
those clearances.

## Validation Status

The following supported-tool command passes Bash syntax, ShellCheck, all nine
disposable-Git/discovery/root checks, 741 safety assertions (including the
repository-qualified and reconstructed-14-record oracles), and 628 branch
assertions. `git diff --check` also passes. No hosted CI workflow existed at the
pinned baseline, and this slice does not claim a hosted CI result.

```sh
PATH="$PWD/.flox/run/aarch64-linux.gh-sweep-dev/bin:$PATH" bash tests/check.sh
PATH="$PWD/.flox/run/aarch64-linux.gh-sweep-dev/bin:$PATH" bash -c 'bash --version; git --version; gh --version; jq --version; shellcheck --version; uname -sm'
sha256sum .flox/env/manifest.toml .flox/env/manifest.lock gh-sweep lib/sweep.sh lib/runs.jq
git diff --check
```

The initial unauthenticated catalog-resolution refusal was resolved by an
operator-generated matching lock using authenticated Flox 1.19.1 and the exact
unchanged manifest. No credentials were transferred and no lock entries were
hand-authored. Initial validation used guest Flox 1.18.1-gf264cf2. The current
launcher instead selects an older Flox that rejects this lock schema; this fix
uses the already-materialized repository tools directly, without activation,
resolution or provisioning. The owner clarified that Flox is optional inside
Coop and supported container tools with recorded versions suffice. No manifest,
lock, activation hook or product dependency machinery changed for this fix.
No product code provisions tools or invokes Flox. The direct test runner also
works wherever the listed tools are available on PATH.

| Tool | Tested Version |
| --- | --- |
| Bash | 5.3.20 |
| Git | 2.56.0 |
| GitHub CLI | 2.103.3 |
| jq | 1.8.2 |
| ShellCheck | 0.11.0 |
| coreutils | 9.12 (locked) |
| findutils | 4.11.0 (locked) |

The lock has 21 entries: seven packages across aarch64 Linux, x86_64 Linux and
Apple Silicon macOS, all at Flox nixpkgs revision
`1c89083e451e891152365b799595cf7790a43325`. Only Linux aarch64 was executed;
the other two systems are resolved, **not tested**. No live GitHub/user-workspace
cleanup, release, deployment, restart or merge was used as a test. Independent
exact-head review and QA remain separate gates using the PR source artifact,
never an older build.

| Source / Environment File | SHA256 |
| --- | --- |
| `.flox/env/manifest.toml` | `3d2f963fe4ab0ca5008539dc1e916137c0474bf28175ba18afa8cca3b8363f12` |
| `.flox/env/manifest.lock` | `c1bc569e5a2afc811ec14c78957cacf1a76879426650ac6144f2bf36f9bd2bf4` |
| `gh-sweep` | `1f16468d3d35443c72af9bab07191ded9e6e4682b849777086a99186293b17ba` |
| `lib/sweep.sh` | `204c6aede3e927f7aec2d2d5905421dbfec65a3e55626da8447edcab1e1987fb` |
| `lib/runs.jq` | `588d0b7577fc78ed65817f4f3376a42d9c8167f10b2665386c1f4b514804b559` |

The interactive refusal fixture uses `script` only when available and otherwise
prints an explicit platform skip. Linux validation exercised it with util-linux
`script` 2.39.3, the host PTY utility outside the seven-package lock. This PTY
adapter is a disclosed platform limit, not a product dependency; gh/git/effects
remain mocked inside the spawned process. Noninteractive refusal is always
tested without it.
