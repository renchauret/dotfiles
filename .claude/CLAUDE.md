## General

* The user's name is ren (note the lowercase).
* When ren says he's going away or afk, use the /afk skill.
* By default, ren saves screenshots to ~/Documents/screenshots. You are also welcome to save screenshots here.

| Info | Value                             |
|------|-----------------------------------|
| Github username | renaudchauret-toast               |
| phone number | +17654327325                      |
| team | Consumer Pay (sometimes just Pay) |
| team Slack channel | #consumer-pay-priv                |
| team JIRA project | DOCT                              |

## Implementing

* Only write code comments when the code would be unclear without one. Keep code comments brief.
* Only modify en-US.json; translations are created automatically after PRs merge to main.
* When creating a new branch, if the ticket number is known, name the branch <ticket-number>/<name>, e.g. DOCT-1234/improve-tests.

## Testing

* When implementing changes in a repo, always write tests for those changes.
* When finished implementing changes and writing tests, ensure that the build and all tests pass.
* When writing tests, do not mock data classes; instead, actually instantiate them.
* If iTests are failing because colima isn't running, run `colima start`.

## Working with Preproduction

* If you need to check or set the value of a feature flag, use the flaggy CLI tool.
* If you need to check or manage builds and deployments, use the idp CLI tool.

## Creating PRs

* When creating a PR, always make it a draft unless explicitly instructed otherwise.
* When writing a PR description, always follow the repo's PR template, if it has one.
* After creating a PR, always open it in ren's browser unless explicitly instructed otherwise. Do not open existing PRs you just updated, only new PRs you just created.
* After moving a PR out of draft, move the corresponding JIRA ticket to Code Review (if there is one), unless explicitly instructed otherwise.
* Do not add screenshots to git unless explicitly instructed otherwise.

## Managing Branches

* When merging a base branch (usually main) into a feature branch, don't rebase, merge.
* When merging a feature branch into main, always squash and merge.

## Session Archives

I keep durable, handoff-oriented session notes in `~/Documents/session-archives/`.
When starting substantive work on a ticket or repo, check there first for prior
context: read `~/Documents/session-archives/README.md`, then any matching
`<project>/<ticket>/` directory and relevant `hook/<TICKET>/` raw captures. Follow
that README's conventions when writing new archives.

* If a session-archives project already exists for what you're working on, update the session archive(s) after each time you commit and push up changes.
* If a session-archives project does not exist for what you're working on, ask ren if one should be created.
