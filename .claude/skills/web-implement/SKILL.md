---
name: web-implement
description: End-to-end workflow for implementing a front-end/web change from a Jira ticket and/or Figma design — analyze, plan, implement, review against Figma via a live preview (Storybook), screenshot, open/update a PR, and update session archives. Use when asked to build or change a UI component that has a Jira ticket or a Figma node. Do NOT use for backend-only work or changes with no visual surface.
user-invocable: true
disable-model-invocation: false
argument-hint: "<jira-key and/or figma-url>"
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Task, AskUserQuestion, TaskCreate, TaskUpdate
---

# Web Implement

Implement a web/UI change end to end, from ticket/design to a reviewed PR. This
skill is the orchestration layer; it delegates design review to the
**`figma-design-reviewer`** agent and follows the repo's existing conventions for
tests, PRs, and archives.

Create a todo per phase below so progress is visible. Work the phases in order, but
skip cleanly past any that don't apply (e.g. no Figma link → skip pixel review,
fall back to functional verification).

## 1. Analyze the ticket and/or Figma

- If given a Jira key, read the ticket (summary, description, acceptance criteria,
  linked designs, feature flags). Extract the **Figma node URL** if present.
- Read the Figma node with the Figma MCP: `get_design_context` for reference code +
  exact tokens (colors, fonts, spacing, sizes), and `get_screenshot` for the visual.
  Note the frame's natural dimensions.
- **Check `~/Documents/session-archives/`** for prior context on this project/ticket
  (per the user's global convention) — read the project README, the ticket dir, and
  any `hook/<TICKET>/` captures. Sibling components already built are the best guide
  to conventions.
- Identify the target component and how to preview it (see Phase 4).

## 2. Plan the changes

- List the concrete edits: which files, which shared components vs. step-specific
  code, new assets, translations, tests.
- **Prefer extending shared components** over duplicating, but weigh it: a shared
  prop that only one consumer uses (and that later gets scrapped) is churn. If a
  treatment is genuinely one-off, keep it local. (Learned the hard way — see
  Learnings.)
- Decide asset handling. SVGs exported from Figma often include page chrome (a
  background rect, a named frame group with huge off-canvas coords); strip those and
  crop the `viewBox` to the art. Embedded PNG textures make exports large — note it,
  revisit only if a bundle-size check flags it.
- For anything non-obvious or user-facing, confirm the approach with the user before
  building (brainstorm first if the change is open-ended).

## 3. Implement

- **Branch first.** If not already on a branch matching `<ticket-id>/<short-title>`
  (e.g. `DOCT-9876/change-button-colors`), create one off the latest `main`
  (`git checkout main && git pull`, then `git checkout -b <ticket-id>/<short-title>`).
  Derive `<short-title>` as a few kebab-case words from the ticket summary. If
  already on a correctly-named branch for this work, stay on it.
- Follow the surrounding code's idioms, naming, and structure.
- **Write tests for the change** (repo convention). Don't mock data classes —
  instantiate them.
- Add translations/strings through the repo's i18n path, not hardcoded.
- Run the repo's full gate as you go: tests, typecheck, lint, build. All must pass.

## 4. Review against Figma via a live preview

- **Launch the preview.** For component-level work this is almost always Storybook
  (`yarn storybook` or the repo equivalent) — check `package.json` scripts. Find or
  add a story that renders the target component.
- **Reach the target state.** Note the click-path to get there and the stable
  selectors (e.g. `[data-testid="..."]`). If the component is only reachable behind
  a trigger that doesn't exist yet, temporarily wire an existing trigger to it so it
  can be exercised — see the **temporary-link pattern** in Learnings.
- **Dispatch the `figma-design-reviewer` agent** (via Task) with: the preview URL,
  the exact click-path + selectors, the Figma node id + file key, and — if you want
  a *specific* change graded — a precise description of just that change and what to
  ignore. The agent does eyes-first (overlay + rubric) then scoped measurement, and
  returns findings by category/severity with a PASS / CHANGES NEEDED verdict.
- **Iterate** on CHANGES NEEDED findings, re-review, until it PASSes (or reaches the
  bar you set, e.g. ≥95). Fix real findings; don't chase sub-perceptual nits.
- **Know when to self-verify instead.** For small, well-scoped tweaks (a color, a
  margin, one added element) where you can confirm correctness yourself with a
  couple of `browser_evaluate` measurements, do that rather than paying for a full
  agent round. Reserve the agent for genuinely ambiguous or high-surface changes.
  (See Learnings — the agent is thorough but has real latency.)

## 5. Screenshot for the PR

- With the component in its final state, take a clean screenshot.
- **Save it OUTSIDE the repo** (e.g. `/tmp/<ticket>-shots/pr-screenshot.png`) and
  remove any stray screenshot artifacts and the `.playwright-mcp/` dir from the repo
  before committing. Never commit screenshots.

## 6. Create or update the PR

- **Restore any temporary preview link to its real state before opening the PR.**
  The existing tests that assert real routing will pass again once it's reverted —
  that's your check the revert is clean (diff should be a no-op on that file).
- Commit with a clear message ending in the required trailer. On the default branch,
  branch first.
- Follow the **repo's PR template** exactly (check `.github/`), and mirror how
  sibling PRs filled it in (Storybook preview URL pattern, screenshot placement).
- **Default to a draft PR** unless told otherwise (user convention).
- Embedding the screenshot: **GitHub Enterprise can't take image uploads via
  CLI/API** — the body gets a `<!-- SCREENSHOT -->` placeholder, and the user drags
  the saved PNG in manually. Reveal it for them (`open -R <path>`) unless they've
  asked you to stop opening things in their browser.
- If updating an existing PR, edit the body/commits rather than opening a new one.

## 7. Update session archives

- Write a handoff-quality session file under
  `~/Documents/session-archives/<project>/<ticket>/` per that README's conventions
  (YAML frontmatter; goal, decisions + *why*, gotchas, commit SHAs, what's next).
  Create/refresh the ticket README and project index.
- **Record dead ends, not just the final state** — an approach that was tried and
  reverted is exactly what saves the next session from repeating it.

## Learnings (from building the retention-engine confirmation steps)

- **Temporary-link pattern.** To preview a component not yet reachable in the app,
  temporarily point an existing trigger at it, then revert before the PR. If you
  want to keep an exercisable version accessible, land the temp link in one commit
  and the revert in a separate follow-up commit (the user asked for this the first
  time; later waived it). The revert should leave a **no-op diff** on the trigger
  file — that plus the routing tests passing confirms it's clean.
- **The Figma reviewer agent is the completeness safety net, but it has latency.**
  Early on, a too-shallow review let whole categories slip (a missing divider, art
  not reaching an edge). Later, an over-thorough review (hand-decoding PNGs pixel by
  pixel) burned 10–20 min/round. The `figma-design-reviewer` agent is now tuned for
  eyes-first + scoped measurement, but still: match the tool to the change — trivial
  tweaks are faster to self-verify.
- **Design vs. fidelity is a judgment split.** The reviewer checks "does the build
  match the design." It will NOT make design decisions for you (e.g. "drop this
  background band," "extend the sleeve with a rectangle vs. stretch the SVG"). Those
  are yours / the user's; don't expect the reviewer to surface them.
- **Tailwind arbitrary values can be silently overridden.** `border-black/[0.08]`
  computed to `rgba(0,0,0,0.12)` because the design system's base CSS clobbered the
  opacity var. Prefer the design-system's own token/utility (e.g. `border-light`)
  and verify the *computed* value, not the class name.
- **Don't distort art to fit.** Stretching an SVG to fill a width warps it. If the
  design shows art running off an edge, extend it with a matching shape (e.g. a
  solid rectangle continuing a sleeve) rather than scaling the artwork.
- **Verify by driving the real thing.** `getBoundingClientRect` / `getComputedStyle`
  in `browser_evaluate` give exact positions, sizes, and colors — far more reliable
  than eyeballing, and cheap. `getBBox()` on a complex SVG lies (grain masks / clip
  frames report huge off-canvas bounds); scan rendered pixels on a canvas instead
  when you truly need art bounds.
- **Run the full verification gate every round** (tests + typecheck + lint + build),
  and remember the pre-push hook may rerun the whole suite — keep it green.
- **Exported SVGs carry chrome AND boundary artifacts.** Beyond the page-background
  rect + named frame group (strip those), Figma exports often include a stroked
  "frame" rect and content sitting flush to the viewBox edge, which renders as a
  stray hairline/gray sliver at the art's edge. `overflow-hidden` on a wrapper does
  NOT clip inside the SVG's own box. What works: crop the **viewBox** inward a unit
  or two (e.g. `0 0 556 239` → `1 1 554 237`). Don't delete the white fill rects —
  they're often structural; if the diagram goes blank, restore from your cleaned copy.
- **buffet Modal renders a scrollbar gutter even when nothing overflows.**
  `overflowBehavior` defaults to `'body'`; both `'body'` and `'modal'` apply
  `overflow-auto` (a visible track on "always show scrollbars" OSes). For fixed-size
  modal content that never scrolls, pass `overflowBehavior='none'`.
- **"Hide the element to isolate it" beats guessing.** When a stray visual artifact's
  source is unclear and `elementFromPoint`/overflow scans are inconclusive, toggle
  `el.style.visibility='hidden'` via `browser_evaluate` and re-screenshot — if the
  artifact disappears, it belonged to that element. (This is how the "scrollbar" was
  traced to the diagram SVG, not the modal.)
- **Time-box cosmetic rabbit holes.** A ~5px edge artifact on a decorative asset is
  not worth 30 minutes. Fix it if quick; otherwise note it and move on.
- **A subagent can die mid-response (API error).** Resume it with SendMessage (it
  keeps its context) rather than restarting from scratch — you'll usually just need
  it to finish the last check.
- **Merging main mid-flight: sibling steps collide predictably.** When several
  people build parallel steps in the same flow, expect conflicts in the shared
  registry files (step-union type, the modal's `switch`, the entrypoint router, the
  translations bundle). Resolution is almost always **keep both** — union both
  members, keep both `switch`/`else if` branches, keep both translation blocks.
  After resolving, a **newly-required prop you added** (e.g. `onConfirmOff`) will
  break the incoming branch's test render-helpers via tsc — fix those, and update
  any test whose copy assertion your change invalidated. Let tsc + tests drive the
  cleanup; they catch exactly these.
- **Prefer required over optional for core callbacks.** Making `onConfirmOff`
  required surfaced every un-wired call site at compile time instead of failing
  silently at runtime. tsc becomes your checklist.
