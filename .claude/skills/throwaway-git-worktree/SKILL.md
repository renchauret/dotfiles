---
name: throwaway-git-worktree
description: |
  Use when an agent needs to modify a git repo (base-branch merge, fix/commit, no-op-commit
  pipeline retrigger, or any working-tree change) but the repo's main checkout may be in use by
  another agent — make the change in a temporary detached worktree, push it, then delete it.
  Triggers when a task must commit or push to a shared checkout under ~/toast/git-repos without
  disturbing it. Invoked by monitor-pr / monitor-all-prs whenever a PR needs changes.
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash
---

# Throwaway Git Worktree

Other agents may be actively working in the shared checkout at `~/toast/git-repos/<repo>`, so
**never make changes directly in the main checkout.** Whenever you need to modify a repo — a
base-branch merge, a fix/commit, a no-op-commit pipeline retrigger — do it in a temporary git
worktree, then delete it.

## When to use

- **Use a worktree** for anything that touches the working tree or creates commits: merges,
  edits, builds/tests against files, pushes.
- **Skip it** for read-only steps (fetching PR state, checking CI, reading review threads,
  `gh pr ready`, `gh pr merge`) — those never touch the working tree.

## The procedure

Let `WT=~/toast/git-worktrees/<repo>-<headRefName>` (the branch being changed).

1. **Create a DETACHED worktree at the branch head**, under the dedicated worktrees dir
   (keeps them out of `git-repos`):
   ```
   mkdir -p ~/toast/git-worktrees
   git -C ~/toast/git-repos/<repo> worktree remove --force "$WT" 2>/dev/null || true   # clear any stale one
   git -C ~/toast/git-repos/<repo> fetch origin
   git -C ~/toast/git-repos/<repo> worktree add --detach "$WT" origin/<headRefName>
   ```
   **Use `--detach` at `origin/<headRefName>`, NOT `worktree add <path> <branch>`.** git
   refuses to check out a branch that's already checked out elsewhere — and the head
   branch is very likely checked out in the main directory another agent is using, which
   would make a plain branch-checkout worktree fail. A detached worktree has no such
   conflict. (Verified: plain checkout errors `'<branch>' is already used by worktree at
   …`; `--detach` succeeds.)
2. **Do all change work inside `$WT`** — `git -C "$WT" …` for merges/commits, and run
   edits/builds/tests against files there, not the main checkout. Because HEAD is
   detached, **push back with an explicit refspec**:
   ```
   git -C "$WT" push origin HEAD:<headRefName>
   ```
   (For a base-branch merge, merge `origin/<baseRefName>` into the detached HEAD, then
   push as above.)
3. **Always delete the worktree when done**, success or failure:
   ```
   git -C ~/toast/git-repos/<repo> worktree remove --force "$WT"
   ```
   Mandatory cleanup — run it even if the change failed or you're bailing, so worktrees
   never accumulate.

Because worktrees share the repo's git objects, the main checkout another agent is using
is never touched — only a separate detached working tree in its own directory.

## Quick reference

| Need | Command |
|------|---------|
| Repo checkouts (shared — never change directly) | `~/toast/git-repos/<repo>` |
| Make a change worktree (detached) | `git -C ~/toast/git-repos/<repo> worktree add --detach ~/toast/git-worktrees/<repo>-<branch> origin/<branch>` |
| Push from detached worktree | `git -C ~/toast/git-worktrees/<repo>-<branch> push origin HEAD:<branch>` |
| Delete it when done | `git -C ~/toast/git-repos/<repo> worktree remove --force ~/toast/git-worktrees/<repo>-<branch>` |

## Common mistakes

- **Changing the shared checkout directly.** Another agent may be in
  `~/toast/git-repos/<repo>` — always make changes in a throwaway worktree.
- **Using a plain branch-checkout worktree.** `worktree add <path> <branch>` fails when the
  branch is already checked out elsewhere; use `--detach` at `origin/<branch>`.
- **Forgetting the explicit refspec on push.** A detached HEAD has no upstream; push with
  `HEAD:<branch>`.
- **Leaking worktrees.** Remove the worktree even on failure/bail; never let them pile up.
