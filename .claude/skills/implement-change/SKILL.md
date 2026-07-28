---
name: implement-change
description: Implements a given change or set of changes by spawning and managing subagents
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, AskUserQuestion
---

# Implement Change

Given a requested change, often a JIRA ticket, plan it and implement it using subagents.

## Process

1. Use an implementation-planner subagent to plan the code changes needed. Pass them the ticket or a description of the requested changes
2. implementation-planner will return a list of repos and code changes necessary in each repo
   1. It also saves this information in the JIRA ticket description, if a ticket was provided
3. For each repo, use an implementer subagent to implement the changes needed
   1. Pass the implementer the exact changes the implementation-planner specified for that repo
   2. The implementer performs works with its own subagents: reviewer(s) and tester(s) to ensure that code quality standards are met.
4. The implementers will create draft PRs and give you the links when they are finished
   1. /monitor-pr safe mode all of these PRs

## Dependent changes

If the implementation-planner subagent specifies any changes as dependent on another repo's changes,
perform multiple implementer + /monitor-pr passes, e.g.:

1. implementation-planner tells you that changes are needed in 2 repos: do-checkout and promo-service, and that the do-checkout changes are dependent on the promo-service changes
2. Dispatch an implementer subagent for the promo-service changes
3. When the implementer is finished, /monitor-pr the promo-service PR
4. Once the promo-service PR merges and its main branch build passes, dispatch an implementer for the do-checkout changes
5. When the implementer is finished, /monitor-pr the do-checkout PR

## Guest auth

The implementer subagent may need to request an `otp` code for guest authentication.
If it does, relay that request to your parent agent or to the user, and pass their response into the implementer subagent which requested the code.
