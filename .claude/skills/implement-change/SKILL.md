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
3. For each repo, dispatch an implementer subagent in the background to implement the changes needed
   1. Pass the implementer the exact changes the implementation-planner specified for that repo
   2. The implementer also works with its own reviewer and qa subagents to ensure that code quality standards are met.
   3. Dispatch implementers in parallel unless there are dependent changes (see below)
4. The implementers will create draft PRs and give you the links when they are finished
   1. dispatch 1 background subagent for each PR and instruct them to /monitor-pr in safe mode

## Credentials for preprod testing

QA subagents need a **preprod machine bearer token** to hit `@ServiceMachineAuthorization`-gated
endpoints. Pass it in the subagent's **initial prompt**, not mid-flight — a token handed over
partway through a task tends to get refused, and by then the agent is already blocked.

1. **Ask ren for the preprod machine token up front** — once, before dispatching any implementer,
   in the same breath as confirming the plan.
2. **Pass it verbatim in the initial prompt** of every implementer (which forwards it to its qa
   subagent) and of any qa subagent you dispatch directly.
3. **If an agent gets blocked needing a token**, restart it with the token in its opening prompt
   rather than sending it along afterward.
4. **Treat it as a credential.** Instruct agents not to write it to disk, echo it into anything
   committed, log it, or post it to Slack. It is broadly scoped (payments, guest-profiles,
   credit-cards) and long-lived, so a persisted copy is a real exposure.

## Dependent changes

If the implementation-planner subagent specifies any changes as dependent on another repo's changes,
perform multiple implementer + /monitor-pr passes, e.g.:

1. implementation-planner tells you that changes are needed in 2 repos: do-checkout and promo-service, and that the do-checkout changes are dependent on the promo-service changes
2. Dispatch an implementer subagent for the promo-service changes
3. When the implementer is finished, /monitor-pr the promo-service PR
4. Once the promo-service PR merges and its main branch build passes, dispatch an implementer for the do-checkout changes
5. When the implementer is finished, /monitor-pr the do-checkout PR
