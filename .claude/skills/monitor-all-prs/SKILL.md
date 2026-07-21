---
name: monitor-all-prs
description: |
  Use when ren wants a single agent to watch ALL of his open PRs at once —
  "monitor all my PRs", "watch my PRs", or /monitor-all-prs.
  Every 10 minutes it finds all of ren's unmerged authored PRs, runs the analyze-pr logic on each tracked one,
  and maintains a yml list of which PRs to monitor (and their safe/unsafe mode).
  Wraps the analyze-pr skill (the same per-PR engine monitor-pr wraps).
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, AskUserQuestion, mcp__plugin_slack_slack__slack_send_message, mcp__plugin_slack_slack__slack_search_channels, mcp__atlassian__editJiraIssue, mcp__atlassian__transitionJiraIssue, mcp__atlassian__getTransitionsForJiraIssue
---

# Monitor All PRs

Run **one** agent that watches every open PR ren authored. Every 10 minutes it discovers his unmerged authored PRs,
reconciles them against a tracking file, and runs the full **`analyze-pr`** logic on each PR it's told to monitor.

This skill is the fleet manager; **`analyze-pr` is the per-PR engine.** For what to do to any single PR — base-branch
merges, pipeline failures, review comments, draft/merge decisions — **follow the `analyze-pr` skill** (the same engine
`monitor-pr` wraps). This skill only adds discovery, the tracking file, and the per-PR loop around it.

## The tracking file

`~/Documents/monitored-prs.yml` — the durable list of ren's open PRs and how to treat each. You maintain it with your
own Read/Write/Edit tools (there is no `yq`/`yaml` CLI on this machine — do not shell out to one). Keep it flat and
simple. One list entry per PR:

```yaml
prs:
  - url: https://github.toasttab.com/toasttab/toastweb/pull/27580  # the PR key; repo + number derive from it
    monitor: true                  # true = run analyze-pr on it; false = ren declined, skip & don't re-ask
    mode: safe                     # safe | unsafe — only meaningful for draft PRs; omit/ignore for non-drafts
    ticket: https://toasttab.atlassian.net/browse/DOCT-1234  # link to the associated JIRA ticket; omit if none (see below)
    exceptions: ""                 # documented deviations from the normal analyze-pr rules (see below); usually empty
```

**`url` is the only identifying field** — the owner/repo and PR number are parsed from it
(`.../<owner>/<repo>/pull/<number>`). Match open-set PRs to yml entries by URL, and derive `<owner/repo>` and
`<number>` from the URL whenever a `gh` command needs them.

**`ticket`** — a link to the PR's associated JIRA ticket (see [Deriving the ticket](#deriving-the-ticket)). **Omit the
field entirely when no ticket can be derived** — don't write `ticket: ""` or a guessed key. Set it once when the PR is
first recorded; a later pass may fill it in if a ticket appears that wasn't derivable before.

**`exceptions`** — a free-text field, **omitted in most cases**, documenting any PR-specific deviation from the standard
`analyze-pr` rules so future agents/sessions honor it. Examples of what belongs here:
"don't merge base into feature — this PR intentionally lags behind main";
"ignore the failing `flaky-e2e` check, known-broken on this branch";
"do not squash-merge even when approved — ren will merge this one manually".
It's populated when ren tells you an exception for a PR; omit it otherwise.
**Never invent exceptions** — only record ones ren actually stated.

Create the file (with an empty `prs: []`) if it doesn't exist.

## Deriving the ticket

When recording a PR (or filling in a missing `ticket` on a later pass), try to derive its JIRA ticket, in this order —
stop at the first that yields a key:

1. **Branch name.** ren names branches `<ticket-number>/<title>` (e.g.
   `DOCT-1234/improve-tests`). Fetch the head branch (`gh pr view <number> --repo
   <owner/repo> --json headRefName`) and match a leading JIRA key —
   `^([A-Z][A-Z0-9]+-\d+)` — case-insensitively, uppercasing the result.
2. **PR body.** Scan the body (already fetched as part of the new-PR marker check, or
   `gh pr view <number> --repo <owner/repo> --json body`) for a JIRA key or a
   `browse/<KEY>` link — e.g. a `https://toasttab.atlassian.net/browse/DOCT-1234` URL or a bare `DOCT-1234`. Take the
   first plausible key.

Store it as the full browse URL: `https://toasttab.atlassian.net/browse/<KEY>`. **If neither yields a key, omit the
`ticket` field** — never guess one. A false ticket would send the transition steps at the wrong issue.

## The loop

Every **10 minutes**, run one full pass (below), then park cheaply with a `Bash`
`sleep 600` and an explicit `timeout: 610000` on the call (Bash's default 120s timeout would kill a bare `sleep 600`).
Keep looping until ren stops it.

### Each pass

1. **Fetch all open authored PRs** (org-wide, one call):
   ```
   GH_HOST=github.toasttab.com gh search prs --author "@me" --state open --limit 100 \
     --json number,title,url,isDraft,repository
   ```
   Call this the **open set**. Match each entry to the yml by its `url`; `number`,
   `title`, and `repository` are only for the ask/marker steps below and are not stored.

2. **Reconcile the tracking file against the open set** (see [Reconciliation](#reconciliation)).

3. **Run an `analyze-pr` pass** on every tracked entry with `monitor: true` (see
   [Per-PR monitoring](#per-pr-monitoring)).

## Reconciliation

Do all three before monitoring, so the tracked list is accurate for this pass.

### New PRs (in open set, not in yml)

For each PR in the open set whose `url` has no yml entry, first check for an **opt-in or opt-out marker**; only PRs
without one go to the batched ask.

**Markers** let ren pre-decide monitoring in a label name **or** anywhere in the body, so no ask is needed:

- `claude-no-monitor` → **do not monitor** (opt-out): record `monitor: false`, no mode.
- `claude-monitor-unsafe` → monitor in **unsafe** mode.
- `claude-monitor` → monitor in **safe** mode (the mode only matters for drafts).

**Fetching, interpreting, and removing markers is delegated to
[`pr-markers.sh`](#the-marker-script).** Run it once per new PR (by URL). It fetches the labels and body, applies the
priority rules (no-monitor > unsafe > safe, handling the
`claude-monitor` / `claude-monitor-unsafe` substring overlap), strips every marker present so the PR isn't reprocessed,
and prints a JSON decision. Do **not** re-implement the matching or `gh pr edit` removal by hand.

Read the JSON `decision` field and write the yml entry (`url`, `monitor`, `mode`,
`exceptions`) accordingly:

- `"no-monitor"` → `monitor: false` (omit/ignore `mode`).
- `"unsafe"` → `monitor: true`, `mode: unsafe`.
- `"safe"` → `monitor: true`, `mode: safe`.
- `"none"` (no marker) → fall through to the batched ask below.

The script already removed the marker(s) as part of its run (unless you passed
`--dry-run`); `removed_labels` / `body_updated` in its output tell you what it stripped.

A `claude-no-monitor`–recorded entry behaves exactly like a declined one: `monitor:
false` means it's **never re-asked** and skipped every pass while it stays in the open set. If a PR carries both an
opt-out and an opt-in marker, the script's **opt-out wins**
(and it strips all markers), so you'll see `decision: "no-monitor"`.

### The marker script

`skills/monitor-all-prs/pr-markers.sh <pr-url>` — the one place that fetches, interprets, and removes a PR's monitor
markers. Usage:

```
pr-markers.sh <pr-url>              # fetch, decide, and strip markers; print JSON
pr-markers.sh --dry-run <pr-url>    # fetch and decide only; remove nothing
```

`<pr-url>` is the entry's canonical `url`; the script parses owner/repo, number, and the
`gh` host from it (no need to set `GH_HOST` yourself). It prints one JSON object to stdout (diagnostics go to stderr):

```json
{
  "url": "…",
  "marker_found": true,
  "decision": "unsafe",
  "monitor": true,
  "mode": "unsafe",
  "removed_labels": [
    "claude-monitor"
  ],
  "body_updated": true,
  "dry_run": false
}
```

`decision` is `no-monitor | unsafe | safe | none`. A non-zero exit means the fetch or a
`gh` call failed — treat it like any transient per-PR error (note it, skip this PR this pass, retry next). It's
idempotent: a re-run on an already-cleaned PR returns `decision: "none"` and changes nothing.

**PRs with no marker → batched ask.** Ask ren whether to monitor each — and for **draft**
PRs, safe or unsafe. **Batch the ask**: one `AskUserQuestion` (or, in away mode, one Slack message per the
afk/analyze-pr relay) listing all remaining new PRs at once — never a prompt per PR (the first run may surface a dozen).
Then write each entry:

- Monitor + (draft) mode chosen → `monitor: true`, `mode: safe|unsafe`.
- Declined → `monitor: false` (so it's **never re-asked**; it stays until it leaves the open set).
- Non-draft PRs don't need a mode; `analyze-pr` treats non-drafts via its merge-decision step regardless.

If ren is unreachable (away mode, no reply within the afk timeout), leave the *unmarked*
new PR **out** of the yml for now and re-surface it next pass — do not silently start monitoring something he didn't opt
into. (Marked PRs are already opted in, so record them regardless of reachability.)

Also **derive the `ticket`** for each new entry (see [Deriving the ticket](#deriving-the-ticket)); omit the field if
none can be derived. On later passes, if a tracked entry has no `ticket`, retry the derivation and fill it in if a key
now appears (a ticket may have been linked in the body since it was recorded).

### Departed PRs (in yml, not in open set)

A tracked PR whose `url` is missing from the open set is no longer open. **Confirm and drop it** (derive `<owner/repo>`
and `<number>` from the entry's `url`):

```
gh pr view <number> --repo <owner/repo> --json state,mergedAt
```

Remove the entry from the yml if `state` is `MERGED` **or** `CLOSED` (any non-open state — merged or closed-unmerged
both get removed; a later reopen is just re-detected as new). If the lookup fails transiently, leave the entry and retry
next pass.

### Self-merged PRs

When an `analyze-pr` pass reports a `merged` outcome for a PR during a pass, **remove its yml entry immediately** (don't
wait for the next reconciliation).

## Per-PR monitoring

For each tracked entry with `monitor: true`, run **one `analyze-pr` pass** on that PR, following the `analyze-pr`skill's
steps in order. Feed it these inputs from the entry:

- **PR** — parse `<owner/repo>` and `<number>` from the entry's `url`
  (`.../<owner>/<repo>/pull/<number>`); pass the `url` itself as the PR reference.
- **mode** — the entry's `mode` (drives the draft decision).
- **session-archives** — whether they exist for this PR.
- **change context** — a **throwaway worktree** (the shared checkout may be in use by another agent).
  See [Isolate changes in a throwaway worktree](#isolate-changes-in-a-throwaway-worktree).
- **exceptions** — the entry's `exceptions` field. `analyze-pr` reads this first and lets a documented deviation
  override any step it conflicts with. Do not re-derive or diverge from `analyze-pr`'s logic here; this skill delegates
  that behavior wholesale.

Then use the pass's reported outcome (`readied`, `merged`, etc.) to drive
[Ticket transitions](#ticket-transitions) and [Self-merged PRs](#self-merged-prs).

If, while working a PR, ren gives you a new standing exception for it, **record it in that entry's `exceptions` field**
so it persists for future passes and agents.

Process PRs one at a time within a pass. If one PR errors, note it and continue to the next — one bad PR must not stall
the whole fleet.

### Ticket transitions

Two `analyze-pr` outcomes on a PR should move that PR's JIRA **ticket** — but only once the ticket has **no remaining
PRs in the relevant state**. Both transitions are gated on the sibling PRs that share the same `ticket`, so they belong
here (after the per-PR pass), not inside `analyze-pr`.

**Only act when the entry has a `ticket`.** No `ticket` field → skip both transitions silently; there's nothing to move.
Transition **automatically, then notify** ren (per
[Notifying ren](#notifying-ren)) — do not wait for approval. This is separate from the squash-merge itself, which has
its own merge conditions.

**Sibling PRs = every tracked yml entry whose `ticket` matches this one** (same browse URL / key), the just-acted PR
included. Judge each sibling's *current* draft/open state from fresh `gh` data this pass, not from the yml.

1. **After a `readied` outcome** (`analyze-pr` ran `gh pr ready`): if **zero** of the ticket's sibling PRs are still
   drafts, move the ticket to **Code Review**. If any sibling is still a draft, leave the ticket alone.

2. **After a `merged` outcome** (`analyze-pr` squash-merged the PR): if **zero** of the ticket's sibling PRs are still
   open — draft or non-draft — set the ticket's fix version to **n/a**
   and move it to **Closed** (many projects require a fix version to close — see **Fix version** below). The just-merged
   PR no longer counts as open (it's merged); check the others. If any sibling is still open, leave the ticket alone.
    - Remember the just-merged PR's `ticket` **before** removing its yml entry (see
      [Self-merged PRs](#self-merged-prs)) — you need it to find the siblings and to run this transition.

**How to transition** (`<KEY>` is the ticket key from the browse URL):

- **Fix version = n/a** (Closed only) — set it **before** the status transition, since a project may block closing
  without one. `acli … edit` has no fix-version flag, so set it via the Atlassian MCP (`editJiraIssue` with
  `fixVersions: [{name: "n/a"}]`). This assumes the ticket's project already has an `n/a` version (DOCT does); if it
  doesn't, don't create one — close without it, or notify ren if the close is then blocked.
- **Status** → move to the target status by name (`Code Review`, `Closed`). Confirm the exact status name is available
  for that issue first (`getTransitionsForJiraIssue`, or
  `acli jira workitem transition --key <KEY> --status "<name>" --yes`); board columns vary by project, so if there's no
  exact `Code Review`/`Closed` transition, notify ren rather than guessing a near-match.

Both transitions are idempotent-ish in effect but not in action: only fire each once, at the moment its triggering
action happens. Don't re-transition a ticket already in the target status. If the transition call fails, note it and
keep going — a failed JIRA move must not stall the PR loop (same isolation rule as a per-PR error).

### Isolate changes in a throwaway worktree

Other agents may be actively working in `~/toast/git-repos/<repo>`, so **never make changes directly in the main
checkout.** Whenever a pass needs to modify a repo — a base-branch merge, a fix/commit, a no-op-commit pipeline
retrigger — **follow the
`throwaway-git-worktree` skill**: create a detached worktree at the PR head, do all analyze-pr change work there, push
back with an explicit refspec, and delete the worktree when done with that PR (success or failure). Read-only steps
(fetching PR state, checking CI, reading review threads, `gh pr ready`, `gh pr merge`) do **not** need a worktree.

Do this per PR that needs changes, then move to the next PR.

## Notifying ren

Same as `analyze-pr`: in away mode relay to **#ren-claude** via `slack_send_message`; else surface in the terminal.
Notify, don't block the loop.

## Quick reference

| Need                                  | Command                                                                                                                                            |
|---------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| All open authored PRs                 | `GH_HOST=github.toasttab.com gh search prs --author "@me" --state open --limit 100 --json number,title,url,isDraft,repository`                     |
| Confirm a departed PR's fate          | `gh pr view <number> --repo <owner/repo> --json state,mergedAt`                                                                                    |
| Fetch/interpret/remove a PR's markers | `skills/monitor-all-prs/pr-markers.sh <pr-url>` (`--dry-run` to decide without removing) → JSON `{decision, monitor, mode, …}`                     |
| Derive a PR's ticket                  | `gh pr view <number> --repo <owner/repo> --json headRefName,body` → key from `headRefName` (`^[A-Z0-9]+-\d+`) or a `browse/<KEY>` link in the body |
| List a ticket's transitions           | `acli jira workitem transition --key <KEY> --status "<name>" --yes` (or `getTransitionsForJiraIssue` to check names first)                         |
| Set fix version to n/a (before Close) | Atlassian MCP `editJiraIssue` with `fixVersions: [{name: "n/a"}]` (acli edit has no fix-version flag)                                              |
| Tracking file                         | `~/Documents/monitored-prs.yml` (maintain with Read/Write/Edit — no yq/yaml CLI; entries keyed by `url`)                                           |
| Repo checkouts                        | `~/toast/git-repos/<repo>` (shared — never change directly)                                                                                        |
| Make a change in a repo               | Follow the `throwaway-git-worktree` skill (detached worktree → push refspec → remove)                                                              |

## Common mistakes

- **Closing without the n/a fix version.** Many projects block a close without a fix version — set `n/a` (via
  `editJiraIssue`) *before* the Closed transition, not after.
- **Shelling out to a YAML tool.** None is installed; edit the yml with your file tools.
- **Changing the shared checkout directly.** Another agent may be in `~/toast/git-repos/
  <repo>` — always make changes via the `throwaway-git-worktree` skill and delete the worktree when done.
- **Not checking review comments every pass.** Always check if there are new review comments to address.
- **Not checking base branch every pass.** Always check if the feature branch has fallen behind the base branch.
- **Not resolving comments after making changes.** Always resolve a review comment you made a change for.
