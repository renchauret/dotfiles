---
name: toastweb-restaurant-session
description: |
  Use when a preprod toastweb admin route or restaurant-scoped admin call returns 403 even
  though the bearer token is valid — a Toast admin bearer carries no restaurant context, so you
  need a customer-access session at the target restaurant. Covers diagnosing a restaurant-scoped
  403 (vs. an annotation 403), creating a session via policy-administration customer-sessions,
  and listing/extending/terminating one. Triggers on "403 on the admin form", "start a toastweb
  session at <restaurant>", "customer access session", "my session expired".
  Do NOT use for prod — this is a preprod tool.
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash, Read, Skill, WebFetch
---

# ToastWeb Restaurant Session

Get a **preprod** toastweb customer-access session at a target restaurant, so restaurant-scoped
admin routes stop 403ing. Prerequisite for driving any toastweb admin form — see
**/modify-restaurant-configs**.

**Do this first, before any admin-form GET.** A Toast admin bearer carries no restaurant
context, so without a session at your target restaurant the admin routes **403** even though
the token is perfectly valid. This is PCR customer access, not a broken token.

## Diagnosing the 403

The tell is that the 403 is *restaurant-scoped, not route-scoped*: the same route returns 200
at a restaurant you already have a session at and 403 at one you don't.
`/restaurants/admin/dashboard` returns 200 either way, so it is **not** a useful probe —
use a payments admin route to test.

Distinguish this from an **annotation** 403: endpoints tagged only
`@ServiceMachineAuthorization` reject a user token at *every* restaurant, so no session will
help. Session 403s fail only where you lack a session. Check which you're facing before
rewriting the request.

## Creating the session

**Get your bearer token from the /toastweb-token skill** — it vends a preprod toastweb user
token via OAuth2 PKCE with cached silent refresh, so don't ask the user to paste one and don't
hand-roll the auth flow. The same token is used for every call here and for the admin forms
afterward; a session 403 never means you need a new token.

No browser and no fresh token are needed — two API calls:

```bash
# Token via the /toastweb-token skill
TOKEN=$(python3 .../toastweb-token/toastweb_token.py token preprod 2>/dev/null)
RX=f86294ec-3c79-4f23-bd41-c71b525f3bd6
G=https://ws-preprod-api.eng.toasttab.com

# 1. Management set GUID (the session is scoped to the management set, not the restaurant)
curl -s -H "Authorization: Bearer $TOKEN" -H "Toast-Restaurant-External-ID: $RX" \
  "$G/config/v2/restaurantConfigs"        # -> restaurant.managementSet.guid

# 2. Create the session
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Toast-Restaurant-External-ID: $RX" \
  -d '{"managementSet":"<mgmtSetGuid>","businessJustification":"preprod testing","restaurant":"'$RX'"}' \
  "$G/policy-administration/v1/customer-sessions"
```

Returns the session: `{"id":...,"managementSet":...,"expiration":<epoch secs>,"justification":...,"restaurant":...}`.
The previously-403ing routes return 200 **immediately** — the existing token starts working
as soon as the session exists.

## Managing sessions

All `@AdminAuthorization`, so a user token works:

| Call | Purpose |
|---|---|
| `GET /policy-administration/v1/customer-sessions` | list your active sessions — check here first |
| `POST /policy-administration/v1/customer-sessions` | create (needs `ACCESS_ANY_RESTAURANT_BIT`) |
| `PATCH /policy-administration/v1/customer-sessions/{id}` | extend (resets to a fresh hour) |
| `DELETE /policy-administration/v1/customer-sessions/{id}` | terminate |

## Notes and gotchas

* Sessions last **~1 hour**. On a long task, re-check `GET` and `PATCH` to extend rather than
  re-diagnosing a sudden 403 mid-run.
* When a session lapses, the admin GET still returns a **200-looking HTML body** — it's the
  `<title>Forbidden</title>` page, ~28 KB versus ~130 KB for a real form. Your scrape then
  fails with `AttributeError: 'NoneType'` on the regex, which looks like a parsing bug but
  is an auth problem. Check the page title before blaming the scrape.
* `businessJustification` is free text and gets normalized (spaces to underscores:
  `preprod testing` → `preprod_testing`). It's logged for compliance — write something true.
* `POST .../customer-sessions/restricted` is the variant for users *without*
  `ACCESS_ANY_RESTAURANT_BIT`; it additionally requires you to already be a `RestaurantUser`
  there. Prefer the plain `POST`.
* The equivalent human flow is Toast Administration (`/toast/admin`) → request customer
  access; toastweb's own routes for it are `GET /toast/admin/customer-access` (Salesforce
  case/project deep-link) and `GET /toast/admin/render/customer-access/switch/{ruleGuid}`
  (switch into an existing session). You don't need either when driving the API directly.
* Don't bother trying to log into `preprod.eng.toasttab.com` with Playwright: the bearer
  already authenticates toastweb's HTML routes, and the SSO path dead-ends on an
  organization-name prompt.
* Host note: toastweb UI is `preprod.eng.toasttab.com`; `ws-preprod-api.eng.toasttab.com` is
  the API gateway. Hitting toastweb UI routes on the gateway host 401s/404s.

## Behaviors

* **Preprod only.** Don't run these against prod.
* **Get the bearer token from /toastweb-token**, not from the user.
* **Check for an existing session before creating one**
  (`GET /policy-administration/v1/customer-sessions`). Doing this first avoids misreading a
  session 403 as a wrong endpoint or a bad token.
* Reuse the token you already have — a session 403 never means you need to re-mint the bearer.
