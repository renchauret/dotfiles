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

1. If only a description of the desired changes was given, and you were prompted directly by a user ask if the user would like to create a ticket
   1. If yes:
      1. Create a DOCT JIRA ticket
      2. Put it in the active sprint
      3. Assign the current user to it
      4. Move it to In Development
2. Use an implementation-planner subagent to plan the code changes needed. Pass them the ticket or a description of the requested changes
3. implementation-planner will return a list of repos and code changes necessary in each repo
   1. It also saves this information in the JIRA ticket description, if a ticket was provided
4. For each repo, dispatch an implementer subagent in the background to implement the changes needed
   1. Pass the implementer the exact changes the implementation-planner specified for that repo
   2. The implementer also works with its own reviewer and qa subagents to ensure that code quality standards are met.
   3. Dispatch implementers in parallel unless there are dependent changes (see below)
5. The implementers will create draft PRs and give you the links when they are finished
   1. Dispatch 1 background subagent for each PR and instruct them to /monitor-pr in safe mode
6. Once all PRs have merged (all /monitor-pr subagents have finished), if there is a JIRA ticket for this work, move it to Closed, with Fix version set to "n/a"
   1. This fix version should already exist in the DOCT project

## Dependent changes

If the implementation-planner subagent specifies any changes as dependent on another repo's changes,
perform multiple implementer + /monitor-pr passes, e.g.:

1. implementation-planner tells you that changes are needed in 2 repos: do-checkout and promo-service, and that the do-checkout changes are dependent on the promo-service changes
2. Dispatch an implementer subagent for the promo-service changes
3. When the implementer is finished, /monitor-pr the promo-service PR
4. Once the promo-service PR merges and its main branch build passes, dispatch an implementer for the do-checkout changes
5. When the implementer is finished, /monitor-pr the do-checkout PR
