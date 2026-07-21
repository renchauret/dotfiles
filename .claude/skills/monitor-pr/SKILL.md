---
name: monitor-pr
description: |
  Use when ren asks to monitor, watch, babysit, or keep an eye on a pull request —
  keeping its CI pipeline green, merging base-branch changes into it, handling review comments, moving it out of draft when ready, and squash-merging it once fully approved.
  Runs on a repeating interval until stopped. Triggers on "monitor this PR", "babysit PR #123", "watch this PR", or /monitor-pr.
user-invocable: true
disable-model-invocation: false
argument-hint: "<PR number or URL> [safe|unsafe]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, AskUserQuestion, mcp__plugin_slack_slack__slack_send_message, mcp__plugin_slack_slack__slack_search_channels
---

# Monitor PR

Babysit a PR on a repeating interval: keep its pipeline green, keep it current with its
base branch, act on review comments, move it out of draft when ready, and squash-merge it
once it's fully approved.

This skill is the **scheduler**; the per-PR check-and-act logic is the **`analyze-pr`**
skill. This skill only adds setup and the 10-minute loop around it — for everything done
to the PR each pass (base-branch merges, pipeline failures, review comments, draft/merge
decisions), **follow the `analyze-pr` skill**.

You drive `gh` (GitHub) and `idp` (Toast CI builds) via `Bash`.

## Setup (once, before the loop)

1. **Resolve the PR** from the argument (number or URL):
   `gh pr view <pr> --json number,isDraft,baseRefName,headRefName,url,mergeable,reviewDecision`.
2. **Determine mode** (draft PRs only): **safe** (default) or **unsafe**. Use unsafe ONLY
   if ren explicitly said so — never default to it.
3. **Check for session-archives** for this PR (see ren's session-archives convention).
   Remember whether they exist — `analyze-pr` updates them "if they exist".
4. Confirm to ren: which PR, which mode, 10-minute interval.

## The loop

Every **10 minutes**, run one full pass, then park cheaply until the next:

- **Run one `analyze-pr` pass** on this PR, passing its `mode` and whether session-archives
  exist. `analyze-pr` does the fresh state fetch, base-branch check, pipeline check,
  review-comment check, and the draft/merge decision — in that fixed order. Make changes
  directly in the PR's checkout (no worktree needed; this skill watches a single PR).
- **Park** with a `Bash` `sleep 600` and an explicit `timeout: 610000` on the call (Bash
  defaults to a 120s timeout and would kill a bare `sleep 600` at exit 143).

Stop the loop when `analyze-pr` reports `merged`, or when ren tells you to stop.

## Notifying ren

Delegated to `analyze-pr` (away mode → **#ren-claude** via `slack_send_message`; else the
terminal). Notify, don't block the loop.

## Common mistakes

- **Stopping after one pass.** This is a loop — keep going until merged or told to stop.
- **Defaulting to unsafe mode.** Safe mode is the default; unsafe requires ren's word.
- **Re-deriving per-PR logic here.** All check-and-act behavior lives in `analyze-pr` —
  follow it; don't reinvent it in this skill.
