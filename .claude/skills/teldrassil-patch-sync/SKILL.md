---
name: teldrassil-patch-sync
description: Keep teldrassil's patch stack (templates/patches) and world-database files (templates/sql) equal to kalimdor after kalimdor PRs merge - one patch per merged PR, in merge order, the whole stack proven against kalimdor main. Use when a kalimdor PR has merged, when teldrassil's build says a patch does not apply, or when the user asks whether teldrassil is in step with kalimdor.
---

# teldrassil-patch-sync

teldrassil builds a cmangos server two ways: from kalimdor itself
(`SOURCE_REPO`, or `SOURCE_DIR` on a kalimdor clone - `PROVENANCE.md` at its
root tells teldrassil the tree commits its own changes, so nothing is
applied), or from the **pinned upstreams plus teldrassil's patches**, applied
in order by `build`. On that second path the patches must give exactly
kalimdor's tree - someone building from scratch applies them in order and
must end with what kalimdor ships. Kalimdor's `sql/` (routes, item rarity,
stats tables) is not code: teldrassil carries copies in `templates/sql/`,
which `start` applies (Kamino 298; `templates/sql/` and `tests/test-world-sql.sh` arrive with
`fix/kalimdor-tree`, 290/298).

Scripts beside this file; run them from anywhere:

- `stack-test.sh <kalimdor> <teldrassil> [ref] [import]` - applies every
  patch in order to kalimdor's untouched import (`5ade959`) in a temporary
  worktree and compares both trees with `ref` (default `origin/main`).
  Read-only for both repositories.
- `new-patch.sh <kalimdor> <teldrassil> <merge commit> <slug>` - writes the
  next-numbered patch(es) for one merged PR: the merge against its first
  parent, per tree, `--binary --relative=<tree>`; a tree it did not touch
  gets none.

## After kalimdor merges

1. `git -C <kalimdor> fetch -q`, and in teldrassil a branch from
   `origin/main` (or onto an unmerged sync branch, said in Kamino).
2. List what merged since the stack's last commit:
   `git -C <kalimdor> log --oneline --first-parent <last>..origin/main`
   (`<last>` is the commit the README says the stack equals). Follow
   kalimdor's merge order in Kamino's kalimdor Next.
3. For each merge, oldest first: `new-patch.sh ... <merge> <slug>`. A PR
   whose fix needed a follow-up PR (a build fix) may share one patch: diff
   from the first merge's parent to the follow-up's merge instead
   (`git diff --binary --relative=<tree> A B -- <tree>`).
4. `stack-test.sh <kalimdor> <teldrassil>` - both trees **identical** to
   kalimdor `origin/main`. A patch that does not apply, or a tree that
   differs, is fixed before anything else.
5. `sql/`: `diff <(ls <kalimdor>/sql/*.sql | xargs -n1 basename) <(ls templates/sql)`
   and `cmp` each; copy new or changed `.sql` files (not the generators).
6. `tests/run-all.sh` - at least `test-patching.sh` and `test-world-sql.sh`
   pass (`test-cli.sh` and parts of others fail on a Mac: BSD `stat`, not
   teldrassil - compare with the commit before yours when unsure).
7. README: the count line ("teldrassil carries N changes to playerbots ...
   and M to the core") and "the stack ... gives kalimdor `<sha>`", and a
   bullet per new patch, newest first: what it does in plain words, then
   "(kalimdor #PR, Kamino N, date.)".
8. Commit as `malahmen` (the repo's local config), push, open the PR; record
   it with the kamino-item skill in teldrassil's todo (and kalimdor's
   "Filed elsewhere").

## When a build says a patch does not apply

`_applied` (lib/provision.sh) checks the stack last-first; a gap counts as
none applied, and `_patch` then fails on the first patch's forward check.
Usual causes: kalimdor merged PRs the stack lacks (sync as above), or the
sources are kalimdor itself without `PROVENANCE.md` at their root.
