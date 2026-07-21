---
name: analyze-pr
description: |
  Use to run ONE analysis-and-action pass over a single pull request — check base-branch
  drift, diagnose pipeline failures, act on new review comments, and move the PR out of
  draft or squash-merge it when its conditions are met. This is the per-PR engine that
  monitor-pr and monitor-all-prs both wrap; it does not loop. Triggers on /analyze-pr or
  when a wrapper skill needs the full per-PR check run once.
user-invocable: true
disable-model-invocation: false
argument-hint: "<PR number or URL> [safe|unsafe]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, AskUserQuestion, mcp__plugin_slack_slack__slack_send_message, mcp__plugin_slack_slack__slack_search_channels
---

# Analyze PR

Run **one** pass over a single PR: bring it current with its base branch, keep its
pipeline green, act on review comments, and move it out of draft or squash-merge it when
ready. This skill runs the steps **once** and stops — the looping, discovery, and
scheduling live in the wrapper (`monitor-pr`, `monitor-all-prs`).

## Run EVERY step, in order, every time

Do steps 1→6 below **in order, every pass. Never skip one.** A passing pipeline does not
excuse skipping the base-branch check; a fresh approval does not excuse skipping the
review-comment or pipeline checks. Each step is independent — finish it and record its
outcome before moving to the next. The single most common failure is laser-focusing on
one signal (a new approval) and silently skipping the others.

## Inputs (from your wrapper)

- **PR** — repo + number, or URL.
- **mode** — `safe` (default) or `unsafe`; matters only for draft PRs (step 5).
- **session-archives** — whether they exist for this PR (several steps update them "if they exist").
- **change context** — where you make changes. `monitor-pr` works in the PR's checkout
  directly; `monitor-all-prs` requires a throwaway worktree — **follow the
  `throwaway-git-worktree` skill** there. Every "push" below happens in that context.
- **exceptions** — optional PR-specific overrides your wrapper tracks. If present, read
  them first; a documented exception **overrides any step below where it conflicts** (e.g.
  skip the base merge, ignore a named failing check, don't auto-merge).

## The steps

### 1. Fetch the PR's full current state — fresh

Never act on a previous pass's snapshot; approvals and checks change between (and mid-)
passes. Capture draft status, base/head refs, mergeability, and review/approval state:

```
gh pr view <pr> --json number,isDraft,baseRefName,headRefName,url,mergeable,reviewDecision,reviews
```

Parse `<owner/repo>` and `<number>` from the PR URL when a command needs them.

### 2. Base-branch check

Determine whether the base branch has commits the feature branch lacks
(`git fetch origin` then compare `origin/<baseRefName>` to the feature branch).

- **Feature is behind** → **merge base into feature** (merge, never rebase — ren's convention):
  `git merge origin/<baseRefName>`. On conflicts, resolve by **keeping BOTH sides** — never
  drop either — then push.
- **Feature is current** → nothing to do.

**Exception — `toastweb`/`toastmobile` on base `development`:** do NOT merge every pass
(`development` moves so fast that merging restarts CI before it can finish, trapping the
loop). Instead merge only to *detect conflicts*: `git merge --no-commit --no-ff
origin/development`.
- **Conflicts** → resolve keeping BOTH sides, commit, and push (the only case you push a
  base merge for these repos).
- **No conflicts** → `git merge --abort`; leave the branch as-is.

This exception applies ONLY to those two repos on base `development`. Every other repo —
and those two on any other base — follows the default rule above.

### 3. Pipeline check

Check the most recent CI run: `gh pr checks <pr>` (for Toast build detail/logs use
`idp builds list <repo> --branch <headRefName> --status failed` and
`idp builds logs <repo> <id>`). If the most recent run **failed**, diagnose it:

- **Transient / flaky** → rerun: `idp builds trigger <repo> --branch <headRefName>`.
  - Can't rerun directly? → merge base into feature (step 2) to trigger a fresh run.
  - No base changes to merge? → push a **no-op commit followed by an undo commit** to force
    a new run (empty `git commit --allow-empty`, or add-then-remove a throwaway line).
- **Real failure** → fix the issue and push. Update session-archives if they exist.

### 4. Review-comment check

Fetch review threads and approval state — `gh api graphql` for `reviewThreads` (with
`isResolved`, and each comment's `author`, `body`, and `reactions`) and `reviews` (for
approval / changes-requested state).

**Filter to actionable comments:**
- Keep only a comment **suggesting a change** (or whose thread has a reply suggesting one).
  Ignore praise, questions, FYIs.
- Ignore **resolved** threads.
- **Never respond to any comment.**

**For each actionable comment, decide by author:**
1. **From ren** (`renaudchauret-toast`) → **make the change.**
2. **From anyone else (human or bot)** → **make the change** if ren reacted 👍 to it OR
   replied indicating he'd make it.
3. **Otherwise** (someone else's comment, no 👍/reply from ren) → check whether ren has
   reacted to, replied to, or resolved **any** comment in that same review:
   - **Yes, he's engaged with that review** → **skip it** (he's seen it and chose not to act).
   - **No engagement anywhere in that review** → he likely hasn't seen it → **notify ren**
     (step "Notifying ren"). Don't guess; just notify.

**After making any changes:**
1. Push the changes (in your change context).
2. **Resolve each thread you made a change for** (`gh api graphql` resolveReviewThread).
3. Do **not** resolve threads you didn't change.
4. Do **not** respond to any comment.
5. Update session-archives if they exist.

### 5. Draft decision (draft PRs only)

If the PR is **not** a draft, skip to step 6.

- **Safe mode (default):** move it out of draft (`gh pr ready <pr>`) once **BOTH** hold:
  1. the most recent pipeline run passed, **and**
  2. ren has signed off. **Sign-off = any ONE of** (many repos block self-approval, so a
     formal approval isn't always possible):
     1. a GitHub PR **approval** from ren (`renaudchauret-toast`);
     2. a comment from ren saying **"approve"/"approved"** or a ✅ (`:white_check_mark:` /
        `:heavy_check_mark:`) as a review comment;
     3. ren **telling you directly** he approves.
- **Unsafe mode:** move it out of draft as soon as the most recent pipeline run passed.
  **Only if ren explicitly set unsafe** — never default here.

### 6. Merge decision (non-draft PRs only)

Squash-merge (`gh pr merge <pr> --squash`) only if **ALL** hold:
1. the most recent CI pipeline run passed;
2. approved by a **human other than ren**;
3. approved by **all humans who previously requested changes**;
4. no human approver left comments requesting changes — counting only each person's **most
   recent** review if they reviewed more than once.

- If all conditions hold but GitHub blocks the squash-merge (branch protection, required
  checks, etc.) → **notify ren**; don't force it.
- If all conditions hold but the auto-mode classifier denies the merge → **ask ren** for
  explicit approval; don't give up and tell him to merge it himself.

## Report the pass outcome

End the pass by stating what happened this pass, so a wrapper can act on it (e.g.
`monitor-all-prs` drives JIRA ticket transitions off `readied` and `merged`):

- `base-merged` — merged base into feature and pushed.
- `pipeline-rerun` — retriggered CI (transient failure).
- `changes-pushed` — pushed a fix or review-comment change.
- `readied` — moved the PR out of draft (`gh pr ready`).
- `merged` — squash-merged the PR.
- `notified` — notified ren (and why).
- `no-op` — nothing needed this pass.

More than one can apply. Be explicit; a wrapper must not have to infer what you did.

## Notifying ren

"Notify ren" adapts to whether the afk skill's away mode is active:
- **Away mode ON** → post to **#ren-claude** via `slack_send_message` (resolve the channel
  per the afk skill), with a one-line summary of the PR and why you're pinging.
- **Away mode OFF** → surface a clearly-marked message in the terminal.

Notify, then continue — don't block waiting on a reply.

## Quick reference

| Need | Command |
|------|---------|
| PR state (fresh) | `gh pr view <pr> --json number,isDraft,baseRefName,headRefName,url,mergeable,reviewDecision,reviews` |
| CI status | `gh pr checks <pr>` |
| Toast build detail / logs | `idp builds list <repo> --branch <br> --status failed` / `idp builds logs <repo> <id>` |
| Rerun pipeline | `idp builds trigger <repo> --branch <br>` |
| Merge base → feature | `git fetch origin && git merge origin/<base>` |
| Review threads (resolved, reactions) | `gh api graphql` on `reviewThreads` |
| Resolve a thread | `gh api graphql` resolveReviewThread mutation |
| Out of draft | `gh pr ready <pr>` |
| Squash-merge | `gh pr merge <pr> --squash` |

## Common mistakes

- **Skipping a step because another looks more urgent.** Run steps 1→6 every pass; a new
  approval does not excuse skipping the pipeline or review-comment checks.
- **Relying on a stale read.** Re-fetch state (step 1) at the start of every pass;
  approvals and checks can land mid-pass.
- **Rebasing the base branch.** ren merges base into feature — never rebase.
- **Dropping a side in a conflict.** Keep both sets of changes.
- **Merging `development` every pass on toastweb/toastmobile.** Merge only to resolve
  conflicts, else the loop never sees CI finish.
- **Responding to comments.** Never reply; only make changes and resolve.
- **Resolving threads you didn't change.** Only resolve what you fixed.
- **Defaulting to unsafe mode.** Safe is the default; unsafe requires ren's word.
