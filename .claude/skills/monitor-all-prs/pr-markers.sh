#!/usr/bin/env bash
#
# pr-markers.sh — fetch, interpret, and remove monitor-all-prs opt-in/opt-out
# markers on a single PR.
#
# Markers (in a label name OR anywhere in the PR body):
#   claude-no-monitor      -> opt-out: do not monitor
#   claude-monitor-unsafe  -> monitor in unsafe mode
#   claude-monitor         -> monitor in safe mode
#
# Priority (which decision wins when several are present): no-monitor beats
# unsafe beats safe. claude-monitor is a substring of claude-monitor-unsafe, so
# the longer token is always tested/stripped first.
#
# Removal: every marker present (label and/or body token) is stripped, so a PR
# is never reprocessed — regardless of which one won the decision.
#
# Usage:
#   pr-markers.sh <pr-url>
#   pr-markers.sh --dry-run <pr-url>   # report the decision, remove nothing
#
# <pr-url> is the canonical PR URL, e.g.
#   https://github.toasttab.com/toasttab/toast-do-checkout/pull/123
# owner/repo, number, and the gh host are all parsed from it.
#
# Output: a single JSON object on stdout, e.g.
#   {"url":"…","marker_found":true,"decision":"unsafe","monitor":true,
#    "mode":"unsafe","removed_labels":["claude-monitor-unsafe"],
#    "body_updated":false,"dry_run":false}
# decision is one of: no-monitor | unsafe | safe | none
# Diagnostics go to stderr; only the JSON goes to stdout.

set -euo pipefail

die() { echo "pr-markers: $*" >&2; exit 1; }

DRY_RUN=false
URL=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) die "unknown flag: $arg" ;;
    *) URL="$arg" ;;
  esac
done

[[ -n "$URL" ]] || die "usage: pr-markers.sh [--dry-run] <pr-url>"

# Parse https://<host>/<owner>/<repo>/pull/<number> (trailing path/query tolerated).
if [[ "$URL" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  HOST="${BASH_REMATCH[1]}"
  OWNER="${BASH_REMATCH[2]}"
  REPO="${BASH_REMATCH[3]}"
  NUMBER="${BASH_REMATCH[4]}"
else
  die "could not parse PR url: $URL"
fi
export GH_HOST="$HOST"
SLUG="$OWNER/$REPO"

# ---- Fetch labels + body -----------------------------------------------------
JSON="$(gh pr view "$NUMBER" --repo "$SLUG" --json labels,body)" \
  || die "gh pr view failed for $SLUG#$NUMBER"

BODY="$(jq -r '.body // ""' <<<"$JSON")"

# ---- Detect each marker (label exact-match OR body substring) ----------------
# label_has: exact-match a label name against the fetched JSON (bash 3.2: no
# arrays/mapfile — query the JSON with jq each time).
label_has() {  # $1 = exact label name
  jq -e --arg want "$1" 'any(.labels[].name; . == $want)' <<<"$JSON" >/dev/null
}

# Body detection must respect the substring overlap: a plain claude-monitor is
# only "present" if one remains after removing every claude-monitor-unsafe.
body_stripped_of_unsafe="${BODY//claude-monitor-unsafe/}"

has_no_monitor=false; has_unsafe=false; has_safe=false
if label_has "claude-no-monitor"     || [[ "$BODY" == *"claude-no-monitor"* ]];                 then has_no_monitor=true; fi
if label_has "claude-monitor-unsafe" || [[ "$BODY" == *"claude-monitor-unsafe"* ]];             then has_unsafe=true; fi
if label_has "claude-monitor"        || [[ "$body_stripped_of_unsafe" == *"claude-monitor"* ]]; then has_safe=true; fi

# ---- Decide (priority: no-monitor > unsafe > safe) ---------------------------
DECISION="none"; MONITOR="false"; MODE="null"
if $has_no_monitor; then
  DECISION="no-monitor"; MONITOR="false"; MODE="null"
elif $has_unsafe; then
  DECISION="unsafe"; MONITOR="true"; MODE="\"unsafe\""
elif $has_safe; then
  DECISION="safe"; MONITOR="true"; MODE="\"safe\""
fi

MARKER_FOUND=false
[[ "$DECISION" != "none" ]] && MARKER_FOUND=true

# ---- Remove every marker present ---------------------------------------------
removed_labels=()
body_updated=false

if $MARKER_FOUND && ! $DRY_RUN; then
  # Drop marker labels (only those actually attached).
  for m in claude-no-monitor claude-monitor-unsafe claude-monitor; do
    if label_has "$m"; then
      if gh pr edit "$NUMBER" --repo "$SLUG" --remove-label "$m" >&2; then
        removed_labels+=("$m")
      else
        echo "pr-markers: warning: failed to remove label $m" >&2
      fi
    fi
  done

  # Strip body tokens (longest first so claude-monitor doesn't chew the others).
  NEW_BODY="$BODY"
  NEW_BODY="${NEW_BODY//claude-monitor-unsafe/}"
  NEW_BODY="${NEW_BODY//claude-no-monitor/}"
  NEW_BODY="${NEW_BODY//claude-monitor/}"
  if [[ "$NEW_BODY" != "$BODY" ]]; then
    if gh pr edit "$NUMBER" --repo "$SLUG" --body "$NEW_BODY" >&2; then
      body_updated=true
    else
      echo "pr-markers: warning: failed to update body" >&2
    fi
  fi
fi

# ---- Emit JSON ---------------------------------------------------------------
removed_json="$(printf '%s\n' "${removed_labels[@]:-}" | jq -R . | jq -sc '[.[] | select(. != "")]')"
jq -nc \
  --arg url "$URL" \
  --argjson marker_found "$MARKER_FOUND" \
  --arg decision "$DECISION" \
  --argjson monitor "$MONITOR" \
  --argjson mode "$MODE" \
  --argjson removed_labels "$removed_json" \
  --argjson body_updated "$body_updated" \
  --argjson dry_run "$DRY_RUN" \
  '{url:$url, marker_found:$marker_found, decision:$decision, monitor:$monitor,
    mode:$mode, removed_labels:$removed_labels, body_updated:$body_updated, dry_run:$dry_run}'
