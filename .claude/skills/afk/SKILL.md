---
name: afk
description: |
  Use when ren says he's stepping away, going AFK, will be back later, or when he invokes /afk.
  Puts the agent into "away mode": blocking questions get relayed to ren in his #ren-claude Slack channel and the agent waits for a threaded reply instead of stalling in the terminal.
  Also handles returning (ren sends any message in the terminal) to exit away mode.
---

# AFK Slack Relay

Lets you reach ren when he has stepped away.
While in **away mode**, instead of stalling on a question in the terminal,
you relay it to ren in his dedicated Slack channel **#ren-claude** and wait for his threaded reply before continuing.

You drive the existing Slack MCP tools (`mcp__plugin_slack_slack__*`).

## Core idea: the `AskUserQuestion` interception

Normally, when you have a decision for ren you call the `AskUserQuestion` tool, which
renders an interactive arrow-key picker in the terminal. This skill changes *where
that question goes* based on mode:

- **When ren is present (away mode OFF):** ask normally via `AskUserQuestion` — the
  interactive terminal picker. This is the default.
- **When ren is AFK (away mode ON):** do NOT call `AskUserQuestion`. Instead take that
  same question + options and relay it to #ren-claude (see below), wait for his threaded
  reply, apply it, and continue. The Slack message is the stand-in for the picker.

So the mental rule is: *in away mode, every time you would have called
`AskUserQuestion`, post to #ren-claude instead.* When ren returns, go back to
`AskUserQuestion`.

## Entering away mode

Enter away mode when ren invokes `/afk` OR says something like "I'm stepping away",
"going afk", "reach me on Slack", "I'll be back in an hour", "brb", etc.

On entry:

1. Resolve the **#ren-claude** channel ID so you can post there:
   - Call `mcp__plugin_slack_slack__slack_search_channels` with `query: "ren-claude"`
     and `channel_types: "private_channel,public_channel"` (it's a **private** channel,
     so you MUST include `private_channel` — the default is public-only and will miss
     it). Match the result named exactly `ren-claude` and grab its channel ID.
   - Do this **once** on entry and remember the channel ID for the session. If you can't
     find it, tell ren you couldn't locate #ren-claude and stay in normal mode.
2. Confirm to ren in the terminal: "Away mode on — I'll post blocking questions to
   #ren-claude and wait for your reply."

Remember for the rest of the session that away mode is ON until ren returns.

## Behavior while in away mode

Follow these three rules on every question that arises:

### 1. Keep making progress first

Before relaying anything, check: is there other useful work I can do **without** this
answer? If yes, do that work and defer the question. Only relay when you are genuinely
blocked and there's nothing productive left to do without an answer.

### 2. When truly blocked, relay to Slack and wait

This is what you do *instead of* calling `AskUserQuestion` while in away mode. Take
the question and the options you would have put in the picker and send them to Slack.

**Send** a message with `mcp__plugin_slack_slack__slack_send_message` to the #ren-claude
channel ID from entry. One message per question (each gets its own thread).
Label each option with the number-word emoji that matches the reaction you'll seed (option 1 → 1️⃣, option 2 → 2️⃣, …),
so the poll and the list line up. Send it exactly in this shape:

```
# 🤖 Decision needed — [<repo or session context>]

**Working on:** <one sentence describing the task you're doing>

**Question:** <the question>

**Recommended:** _<your pick>_ — <one-line why>

**Options:**
1️⃣ *<label>* — <description>
2️⃣ *<label>* — <description>
```

Remember the sent message's timestamp/thread ID and which question it maps to. If you
have multiple pending questions, send a separate message for each and track all mappings.

**Seed the poll.** Right after sending, add one reaction per option with
`mcp__plugin_slack_slack__slack_add_reaction` using the number-word emoji names —
`one`, `two`, `three`, `four`, … (no colons) — matching the emoji you listed. Because
the MCP acts *as ren*, these reactions are attributed to ren, so **ren votes by tapping
one, which REMOVES it.** The emoji that goes missing is his pick.
Remember the exact set of emojis you seeded for this message.

**Wait** by parking cheaply — do NOT tight-poll:

- Run a `Bash` `sleep` to park at near-zero token cost. IMPORTANT: `Bash` has a
  default 2-minute timeout, so pass an explicit `timeout` on the call that matches the
  sleep (e.g. `sleep 300` with `timeout: 310000`) — otherwise the command errors at
  120s with exit 143. Start at ~120s and back off to 300s.
- Then check **both** answer channels for that question, thread first:
  1. One `mcp__plugin_slack_slack__slack_read_thread` call — a **text reply always
     wins** (it carries the most nuance); if present, use it and ignore the poll.
  2. Else one `mcp__plugin_slack_slack__slack_get_reactions` call — compare against the
     set you seeded. If **exactly one** seeded emoji is now missing (removed), that
     option is his pick. If all are still present, he hasn't voted yet; if more than
     one is missing, it's ambiguous — keep waiting (or post a brief in-thread nudge).
- If no answer either way, sleep again with backoff (120s → 300s, capped at 300s) and re-check.
- Repeat until an answer arrives or the timeout is hit.

**On answer:** for a text reply, parse flexibly — "go with your rec", "option 2",
"yes", or free text. For a poll vote, map the removed emoji back to its option.
Interpret in context, apply the decision, then acknowledge in-thread with
`slack_send_message` (thread reply), e.g. "👍 got it, proceeding with X". Continue work.

If several questions are outstanding, you may check each thread + poll per cycle and
apply answers as they come in, in any order.

### 3. Timeout

If **1 hour** passes with no reply to a question, stop polling it. Post a final
in-thread note ("⌛ no reply in an hour — I'll wait for you back in the terminal"),
then revert to normal behavior for that question: stall/wait in the Claude Code
terminal as usual. Do this per question.

### 4. Notify when finished and awaiting new input

When you finish the work you were doing and have nothing left to do except wait for
new instructions from ren — i.e. you're about to go idle in the terminal — post to
#ren-claude letting him know, so he doesn't have to keep checking. Send this as a **new
top-level message** (not a thread reply). Format:

```
# ✅ Done for now — [<repo or session context>]

Awaiting your next instructions.

**Was working on:** <one sentence describing what you finished>
```

Send this only once per idle point (don't repeat it while continuing to wait), and
only in away mode.

**Then watch this message's thread for an hour, exactly like a question relay** — ren
may reply in-thread with what he wants done next. Remember the sent message's
timestamp/thread ID, then park-and-poll using the same cheap `sleep` + single
`slack_read_thread` loop from rule 2 (120s → 300s backoff, capped at 300s). If a reply
arrives, treat it as new instructions: acknowledge in-thread ("👍 on it") and start the
work — you're back to being busy. If **1 hour** passes with no reply, stop polling and
go idle in the terminal as usual (no timeout note needed). If you were already parked
polling other pending questions, just add this thread to the set you check each cycle.

**This loops.** When you finish those new instructions and again have nothing left to
do, send **another** done message (a fresh top-level message) and watch it the same way.
Keep repeating this back-and-forth — finish work → post done → poll for the next reply →
do it → post done again — for as long as ren stays away. Away mode only ends when ren
returns (see below), not when a batch of work finishes.

## Exiting away mode

**Any message ren sends in the terminal means he's back — exit away mode by default.**
Don't wait for an explicit "I'm back"; the fact that he's typing in the terminal is the
signal that he's returned.

**Exception:** if that terminal message itself says he's still away (e.g. "still afk,
just a quick one", "one-off while away, back to gone after this"), treat it as a single
instruction to handle, stay in away mode, and keep relaying afterward.

On exit: stop relaying to Slack and stop polling. Resume asking questions normally via
`AskUserQuestion` (the interactive terminal picker). Optionally confirm: "Welcome back
— away mode off, I'll ask here from now on." If there were unanswered relayed
questions, re-ask them now via `AskUserQuestion` in the terminal.

## Failure handling

- If resolving #ren-claude fails on entry, or a `slack_send_message` fails when you
  need to relay, do **not** silently hang. Tell ren (in the terminal) that the relay
  is unavailable and fall back to normal terminal waiting.
- Post only to #ren-claude — never relay questions to any other channel or DM.
