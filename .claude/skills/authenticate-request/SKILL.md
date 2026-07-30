---
name: authenticate-request
description: |
  Use when you need to authenticate a request to a Toast REST endpoint or GraphQL
  query/mutation in preprod — pick the right token type for the endpoint's authorization
  annotation (@AdminAuthorization, @CustomerAuthorization, @ServiceMachineAuthorization,
  @GuestAuthorization), mint it, and attach the required headers. Covers which annotations
  need a restaurant session and which don't, the headers each one requires, and diagnosing a
  401 vs. a 403. Triggers on "authenticate this request", "what token do I need for this
  endpoint", "I'm getting a 403 on a preprod endpoint", "mint a preprod bearer token",
  "how do I call this @CustomerAuthorization endpoint".
  Do NOT use for prod — this is a preprod tool.
user-invocable: true
disable-model-invocation: false
---

# Authenticate a Preprod Request

Pick the token type from the endpoint's authorization annotation, mint it, attach the right
headers. **Read the annotation on the resource class and method first** — it determines
everything else. Guessing the token type and retrying is the slow path.

## Which annotation?

Find the annotation on the resource method, then fall back to the class. **A method-level
annotation entirely replaces the class-level one — they do not merge.**

If an endpoint has **multiple** annotations, any one of them working is sufficient. This matters
more than it sounds: see [Dual-annotated endpoints](#dual-annotated-endpoints).

| Annotation | Token source | Restaurant session? |
|---|---|---|
| `@AdminAuthorization` | `preprod bearer` | **No** |
| `@CustomerAuthorization` | `preprod bearer` + session | **Yes** |
| `@ServiceMachineAuthorization` | `preprod-m2m` | No |
| `@GuestAuthorization` | /self-guest-authentication | No |

## @AdminAuthorization

Mint a token with the `env-auth-cli` (https://github.toasttab.com/toasttab/env-auth-cli):

```bash
TOKEN=$(preprod bearer)
```

If `preprod bearer` fails, run `preprod login` — it prompts ren to log in via his browser.

**No restaurant session is needed, and no restaurant headers are needed.** `AdminAuthorization`
authorizes off a pure bitmask check against the `toast_permissions` claim in your JWT — it makes
no network calls and never looks at restaurant context. A session cannot help such an endpoint
and its absence cannot hurt it.

## @CustomerAuthorization

Same token as above, **plus** a customer-access session at the target restaurant:

```bash
preprod createSession --restaurant <restaurantGuid>
```

It resolves the management set from the restaurant GUID and prints the headers to use. You can
pass `--managementSet <guid>` explicitly to skip the lookup.

Then send **both** headers — the token and session alone are not enough:

```bash
curl -sS "https://ws-preprod-api.eng.toasttab.com/<service>/v1/<path>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Toast-Restaurant-External-ID: <restaurantGuid>" \
  -H "Toast-Management-Set-Guid: <managementSetGuid>"
```

**Omitting `Toast-Management-Set-Guid` returns 403 even with a valid session** — indistinguishable
from a session failure, and a common time sink. If a `@CustomerAuthorization` call 403s, check
this header before re-minting anything.

Unlike the admin path, this path calls out to `CheckPermissionsClient` and `PolicyDecisionClient`;
it's `policyDecisionClient.toastUserAccess(...)` throwing `ForbiddenException` that produces the
403 when you have no session.

### Managing sessions

Sessions last **4 hours**. `env-auth-cli` only creates them; to list, extend, or terminate use
the REST API directly (all `@AdminAuthorization`, so the same bearer works):

| Call | Purpose |
|---|---|
| `GET /policy-administration/v1/customer-sessions` | list active sessions — check here first |
| `POST /policy-administration/v1/customer-sessions` | create (needs `ACCESS_ANY_RESTAURANT_BIT`) |
| `PATCH /policy-administration/v1/customer-sessions/{id}` | extend (resets the clock) |
| `DELETE /policy-administration/v1/customer-sessions/{id}` | terminate |

On a long task, `GET` then `PATCH` to extend rather than re-diagnosing a sudden mid-run 403.
Terminate the sessions you create when you're done.

The session is scoped to the **management set**, not the restaurant. If you need to create one by
hand rather than via `preprod createSession`, get the management set GUID from
`GET /config/v2/restaurantConfigs` → `restaurant.managementSet.guid`, then `POST` with
`{"managementSet":…,"restaurant":…,"businessJustification":…}`. Previously-403ing routes return
200 **immediately** once the session exists — no new token needed.

`businessJustification` is free text, normalized to underscores (`preprod testing` →
`preprod_testing`). It's logged for compliance, so write something true.

`POST .../customer-sessions/restricted` is the variant for users *without*
`ACCESS_ANY_RESTAURANT_BIT`; it additionally requires you to already be a `RestaurantUser` there.
Prefer the plain `POST`.

### Diagnosing a restaurant-scoped 403

The tell is that the 403 is *restaurant-scoped, not route-scoped*: the same route returns 200 at a
restaurant you have a session at and 403 at one you don't.
`/restaurants/admin/dashboard` returns 200 either way, so it is **not** a useful probe — use a
payments admin route to test.

## @ServiceMachineAuthorization

Use the `preprod-m2m` CLI (https://github.toasttab.com/zwalsh-toast/preprod-m2m) to mint a bearer
token.

If the token is missing the scope(s) you need, ask ren to add the new scope to his service client;
you must fetch a new token after he has done that.

A user token is rejected at **every** restaurant on an endpoint tagged only
`@ServiceMachineAuthorization` — no session or restaurant header will help. If a call fails
identically everywhere, check for this annotation before blaming your token.

## @GuestAuthorization

Use /self-guest-authentication to sign in with your own Toast guest account.
Also use it for any test case that requires a signed-in guest, even if the endpoint isn't guest-tagged.

## Dual-annotated endpoints

An endpoint carrying **both** `@CustomerAuthorization` and `@AdminAuthorization` **does not need a
session** when you're authenticating as an internal user. The filter branches on token type: an
internal-user token on a resource with `@AdminAuthorization` routes to the admin path and never
reaches the session check.

So `@CustomerAuthorization` being present does **not** imply "needs a session" — check whether an
`@AdminAuthorization` sits alongside it. `ExternalFeedbackResource` is an example of this shape.

This applies to internal-user tokens, which is what `preprod bearer` vends. A restaurant user's
token has no `TOAST_ADMIN` role and would take the customer path regardless.

## Diagnosing a failure

Distinguish these before changing anything:

* **401** — the token itself is bad or expired. Re-mint (`preprod bearer`; `preprod login` if that
  fails). This is the only case where a new token helps.
* **403 everywhere, every restaurant** — annotation mismatch. You're likely sending a user token at
  a `@ServiceMachineAuthorization`-only endpoint. A session won't fix it.
* **403 at one restaurant, 200 at another** — session-scoped. Create a session at the failing
  restaurant.
* **403 with a valid session** — usually the missing `Toast-Management-Set-Guid` header. Check that
  before anything else. Otherwise your JWT may lack the annotation's `permissionBits`.
* **A non-403 error (400/404/500)** — authorization **passed**; the failure is downstream in
  business logic or routing. Stop debugging auth and go to Splunk.

A session 403 never means you need a new bearer token. Reuse the token you have.

## Handling tokens safely

**Treat every token as a credential:** never write it to a file, echo it into anything you commit,
log it, or post it to Slack. These tokens carry broad payment/PII scopes and are long-lived, so any
persisted copy is a real exposure. Keep it in an environment variable or inline in the request.

`env-auth-cli` stores its tokens in the macOS login keychain, not on disk — don't copy them out.

## Behaviors

* **Preprod only.** Don't run any of this against prod.
* **Read the annotation before minting a token.** It determines the token type, whether you need a
  session, and which headers to send.
* **Check for an existing session before creating one**
  (`GET /policy-administration/v1/customer-sessions`).
* **Never ask ren to paste a token** — mint it. The only thing he does by hand is the browser step
  of `preprod login` and adding M2M scopes.
