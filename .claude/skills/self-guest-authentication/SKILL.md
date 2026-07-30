---
name: self-guest-authentication
description: |
  Authenticate as a Toast guest end-to-end with NO human in the loop — get a guest bearer
  token by texting the OTP to the agent's own Google Voice number, which forwards into ren's
  Toast mailbox where the agent reads it with gws. Use instead of /guest-authentication
  whenever you need to sign yourself in as a guest: place an authenticated order, hit
  guest-scoped endpoints, or exercise a signed-in guest flow without asking ren for a code.
  Triggers on "sign yourself in as a guest", "authenticate as your own guest", "get a guest
  token without me", "place an authenticated order".
  Do NOT use when ren wants to authenticate HIS OWN phone number — use /guest-authentication
  for that. Preprod only.
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash, Read, Skill
---

# Self Guest Authentication

Wrapper around **`/guest-authentication`** with the human removed from the middle. Same
passwordless flow; the difference is *where the OTP goes* and *who reads it*.

```
Toast OTP ──SMS──▶ Google Voice +17652055923
                 └─▶ ren's personal Gmail
                     └─(filter: from:txt.voice.google.com)─▶ renaud.chauret@toasttab.com
                         └─▶ this skill reads it with the corporate `gws` CLI
```

Costs nothing, stores no new credentials, and touches nothing in ren's personal account
beyond the Voice messages the filter forwards.

Use this for the agent's own guest identity. Use `/guest-authentication` when the guest is
ren himself.

## Prerequisites

| Thing | Check |
|---|---|
| `gws` authenticated as the Toast account | `gws gmail users getProfile --params '{"userId":"me"}'` |
| Voice→Gmail forward still alive | `gws gmail users messages list --params '{"userId":"me","q":"from:txt.voice.google.com","maxResults":1}'` |

The agent's number lives in `AGENT_PHONE.txt` next to this skill — read it, never hardcode
it, and **never fall back to ren's personal phone**.

```bash
AGENT_PHONE=$(cat ~/.claude/skills/self-guest-authentication/AGENT_PHONE.txt)
```

## The flow

Two gateway mutations plus the mail read. Capture the timestamp **before** triggering, so a
stale code from an earlier run can't be picked up.

```bash
cd ~/.claude/skills/self-guest-authentication
AGENT_PHONE=$(cat AGENT_PHONE.txt)
GW=https://ws-preprod-api.eng.toasttab.com/do-federated-gateway/v1/graphql
SINCE=$(date +%s)

# 1 — trigger the SMS
curl -sS -X POST "$GW" \
  -H "Content-Type: application/json" \
  -H "Toast-Dev-Allow-Arbitrary-Operations: true" \
  --data "{\"query\":\"mutation P(\$input: PasswordlessLoginUnifiedInput!){ passwordlessLoginUnified(input:\$input){ ... on PasswordlessLoginUnifiedResponse{success} ... on PasswordlessAuthenticationError{code message} } }\",\"variables\":{\"input\":{\"phone\":\"$AGENT_PHONE\",\"source\":\"TOAST_SITES\"}}}"

# 2 — read the OTP out of the Toast mailbox (blocks until it lands)
OTP=$(./scripts/get_otp.py --since-epoch "$SINCE" --timeout 90)

# 3 — exchange it for the guest bearer token
curl -sS -X POST "$GW" \
  -H "Content-Type: application/json" \
  -H "Toast-Dev-Allow-Arbitrary-Operations: true" \
  --data "{\"query\":\"mutation C(\$input: PasswordlessConfirmCodeUnifiedInput!){ passwordlessConfirmCodeUnified(input:\$input){ ... on PasswordlessTokenUnifiedResponse{accessToken refreshToken expiresAtIso8601 guestGuid} ... on PasswordlessAuthenticationError{code message} } }\",\"variables\":{\"input\":{\"phone\":\"$AGENT_PHONE\",\"code\":\"$OTP\",\"source\":\"TOAST_SITES\"}}}"
```

`accessToken` is the guest bearer — use it as `Authorization: Bearer <token>`.

## Why the GraphQL gateway, not the REST endpoint

**The REST endpoint in `/guest-authentication` cannot create a new guest account.** Calling
`POST /authentication/v1/authentication/guest/passwordless/start` directly sends
`client_id=null` and fails with `400 Public signup is disabled` — *asynchronously*, after
already returning `HTTP 200`. The SMS is never sent.

The gateway route works because it carries a registered client
(`client_id=preprod-consumer-app-bff`). Use it here. `/guest-authentication` remains
accurate for a number that already has a guest account.

**A `success:true` does NOT mean the SMS was sent** — dispatch happens afterwards in
`PASSWORDLESS_EXECUTOR`. To confirm a send, check Splunk:

```
index=preproduction_g2 sourcetype=g2_svc "passwordless"
```

A clean send logs `status=passwordless_account_created` with no following
`PASSWORDLESS_EXECUTOR` error. Look for a trailing
`AuthenticationProviderException` to see the real reason a text never arrived.

## `get_otp.py`

| Flag | Default | Meaning |
|---|---|---|
| `--since-epoch N` | now | ignore older mail; **always pass this** |
| `--timeout N` | 90 | seconds before giving up |
| `--poll N` | 5 | seconds between Gmail polls |
| `--min-digits` / `--max-digits` | 4 / 8 | expected code length |
| `--text "..."` | — | parse a literal string instead of Gmail (testing) |

Exit codes: **0** code on stdout · **1** timed out · **2** `gws`/plumbing broken.

Prefers a digit run next to code-ish wording, strips phone-number-shaped noise first (so the
sending number is never mistaken for the code), filters on Gmail's `internalDate` with a 2s
grace window, and falls back to the message snippet if MIME decoding yields nothing.

## Behaviors

- **Never** use ren's personal number, and never ask him to relay a code — reading it
  yourself is the entire point. If it doesn't arrive, debug or report; don't silently fall
  back to asking.
- Always `--since-epoch $(date +%s)` captured *before* step 1. Codes are **single-use**; a
  reused or stale one returns `WRONG_PHONE_NUMBER_OR_CODE`.
- Use the identical `+`-prefixed E.164 string in steps 1 and 3.
- Observed latency is **9–30s**; 90s of timeout is ample headroom.
- Exit **2** is a `gws` problem, not a missing text — check `gws` auth before retrying.
- On exit **1**, the first suspect is the **Gmail filter on ren's personal account**. If it
  was removed or Voice forwarding was disabled, nothing will ever arrive.
- The token is short-lived (~30 min) — don't echo it unless asked, mint fresh per session.
- Tokens currently come back with `profile_created: false` — the guest exists but has no
  profile. Saved cards / profile work needs that resolved first (open item).
- Hand the token to **`/place-off-prem-order`** or **`/rearch-closeout`** as the guest bearer.

## Verified

Full chain confirmed 2026-07-29 across three runs — trigger → forwarded mail → autonomous
read → token, e.g. `guestGuid: 7bc060b1-1311-40bb-9f45-b7259d27e6cf`. Unlike Twilio (which
redacts inbound OTPs, error 30038), Google Voice forwards the code intact.
