# monitor-pr

A Claude skill for monitoring PRs, keeping their pipelines green, moving them out of draft, managing their reviews, and merging them when ready.

## Monitoring

You should check the PR every 10 minutes and perform the logic outlined below.

## Logic

### General

This applies to draft and non-draft PRs.

#### Base Branch Changes

If the base branch of the PR has new changes, merge the base branch into the feature branch.
If there are conflicts, ensure that both sets of changes are kept.

#### Pipeline Failure

If the most recent CI pipeline run failed, diagnose the issue.

If the failure is transient and/or flaky, rerun the pipeline. The idp CLI tool might be the easiest way to do this.
If you cannot rerun the pipeline, merge the base branch into the feature branch to trigger a new pipeline run.
If there are no new changes in the base branch to merge in, push up a no-op commit followed by an undo commit to trigger new pipeline runs.

If the failure is not transient, attempt to fix the issue and push up.
If there are session-archives for this PR, update them.

#### New Review Comments

For all new review comments:
Only consider the comment if it is suggesting changes (or if a reply comment in the same thread suggests changes).
Other comments should be ignored.
Resolved comments should also be ignored.
Never respond to any comments.

If there are new review comments from ren (renaudchauret-toast), make all suggested changes and push up.

If there are new review comments from anyone else (human or bot):
1. If ren reacted to the comment with a thumbs up emoji, make the suggested change.
2. If ren responded to the comment indicating he would make the suggested change, make the suggested change.
3. If ren has not reacted to, replied to, or resolved any of the comments from 1 review, that indicates he has likely not seen the review. Notify him of the review.

In all cases where you made changes:
1. Resolve each comment for which you made changes.
2. Do not resolve comments for which you did not make changes.
3. Do not respond to any comments.
4. If there are session-archives for this PR, update them.

### Draft PR

If the PR is a draft PR, there are 2 skill modes with different logic:

#### Unsafe Mode

Once the PR's most recent pipeline run passed, move the PR out of draft.

Do not use unsafe mode unless you are told to by ren.

#### Safe Mode

If BOTH of these 2 conditions are met, move the PR out of draft:
1. The PR's most recent pipeline run passed.
2. ren has approved the PR.

If neither mode is specified by ren, safe mode is the default.

### Non-draft PR

If the PR is not a draft PR, squash and merge it if ALL the following conditions are met:
1. The most recent CI pipeline run passed.
2. The PR has been approved by a human other than ren.
3. The PR has been approved by all humans who previously requested changes.
4. All human approvals did not leave any comments requesting changes. Note that if 1 person approved the PR multiple times, only their most recent approval must meet this condition.

If all the conditions are met, but Github is preventing you from squash-merging the PR, notify ren.
