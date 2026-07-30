---
name: modify-restaurant-configs
description: |
  Use when a task needs a preprod restaurant to have a different configuration — create,
  edit, or archive a service charge, alternate payment method (other payment type / APM),
  dining option, discount, or any other restaurant config — and then publish it so the
  change is live. Covers finding a usable endpoint (toastweb admin form vs. a service endpoint,
  including @ServiceMachineAuthorization ones via an M2M token), the toastweb CSRF/cookie-jar
  dance, publishing via quickApplyConfigChanges, and verifying against published config.
  Authenticate every request via the authenticate-request skill.
  Triggers on "create an other payment type at <restaurant>", "add a service charge in
  preprod", "archive that payment method", "publish this config change".
  Do NOT use for prod — this is a preprod tool.
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash, Read, Skill, WebFetch
---

# Modify Restaurant Configs

Change a **preprod** restaurant's configuration and publish it. The end state is a config
that is live on the POS — not merely saved/staged.

Trident (GUID `326fa596-0d90-48f3-b3ee-12862841ef8a`, numeric id `254000000000000`) is
usually a good test restaurant.

## Finding an endpoint to call

Three surfaces can write config. Pick by what the resource is annotated with, then
authenticate it via **/authenticate-request**:

1. A **service endpoint or GraphQL mutation** tagged `@CustomerAuthorization` or
   `@AdminAuthorization` — user token (session only for the customer case).
2. A **service endpoint tagged `@ServiceMachineAuthorization`** — an **M2M token**
   (`preprod-m2m bearer`). These are reachable; see below.
3. A **toastweb endpoint or admin form** (`preprod.eng.toasttab.com`) — user token + a
   customer-access session at the restaurant.

Use Sourcegraph to locate the config's write path. Search the entity name (e.g.
`AlternatePaymentType`, `ServiceCharge`) across `*Resource.kt|java` for the service path,
and across `conf/routes` + `app/controllers` in `toastweb` for the admin form. **Read the
annotation on the resource class and method before building a request** — it tells you which
token to mint, and a method-level annotation entirely replaces the class-level one.

### Machine-only endpoints are reachable with an M2M token

A class-level `@ServiceMachineAuthorization` with no admin/customer annotation beside it does
**not** mean look elsewhere. Mint an M2M token instead:

```bash
curl -s -H "Authorization: Bearer $(preprod-m2m bearer)" \
  -H "Toast-Restaurant-External-ID: $RX" \
  "https://ws-preprod-api.eng.toasttab.com/<service>/v1/<path>"
```

Machine tokens carry **per-scope** grants, so a 403 here is usually a **missing scope, not the
wrong token type**. Read the annotation's `scopes` and check the token actually holds it before
concluding the endpoint is closed — the granularity is per-verb, so holding a `:create` scope tells
you nothing about `:read` on the same resource. Decode the token's `scope` claim to check.

If the scope is genuinely missing, ask ren to add it to his service client, then re-mint
(`preprod-m2m login`). See /authenticate-request for the details.

Prefer the machine path when it exists: it's a single request against the service's real API,
versus toastweb's scrape-and-POST. Fall back to the admin form when no scope can be granted, or
when the service has no write API at all — toastweb writes through its own JPA path, the same
thing the human UI does.

## Session for toastweb admin forms

**Do this first, before any admin-form GET.** A user bearer carries no restaurant context, so
without a session at your target restaurant the admin routes **403** even though the token is
perfectly valid. Only toastweb forms and `@CustomerAuthorization` endpoints need this — M2M and
`@AdminAuthorization` calls do not.

Use **/authenticate-request** to mint the token and create the session
(`preprod createSession --restaurant <restaurantGuid>`). It also covers listing/extending a
session and telling a session 403 apart from an annotation or scope 403.

Host note: toastweb UI is `preprod.eng.toasttab.com`; `ws-preprod-api.eng.toasttab.com` is
the API gateway. Hitting toastweb UI routes on the gateway host 401s/404s.

**When a session lapses, the admin GET still returns a 200-looking HTML body** — it's the
`<title>Forbidden</title>` page, ~28 KB versus ~130 KB for a real form. Your scrape then fails with
`AttributeError: 'NoneType'` on the regex, which looks like a parsing bug but is an auth problem.
Check the page title before blaming the scrape.

Don't try to log into `preprod.eng.toasttab.com` with Playwright: the bearer already authenticates
toastweb's HTML routes, and the SSO path dead-ends on an organization-name prompt.

## Driving a toastweb admin form

Host is toastweb's own, **not** the `ws-preprod-api` gateway (which 404s these routes):
`https://preprod.eng.toasttab.com`.

Every mutating admin form needs, beyond the bearer:
* `Toast-Restaurant-External-ID: <restaurantGuid>` header
* an `authenticityToken` form field (Play's CSRF token)
* a `restaurantId` form field (the restaurant's **numeric** id)
* the **same cookie jar** as the GET that produced the token — `TOAST_SESSION` carries the
  session half of the CSRF pair (`___AT=<authenticityToken>`). Without the cookie the token
  won't validate.

So the pattern is always **GET the form page, scrape, POST with the same jar**:

```bash
TOKEN=$(preprod bearer)
RX=326fa596-0d90-48f3-b3ee-12862841ef8a

curl -s -c /tmp/tw.cookies -o /tmp/form.html \
  -H "Authorization: Bearer $TOKEN" -H "Toast-Restaurant-External-ID: $RX" \
  "https://preprod.eng.toasttab.com/restaurants/admin/payments/paymentType"

scrape() { python3 -c "
import re,sys
h=open('/tmp/form.html').read()
tag=re.search(r'<input[^>]*name=\"%s\"[^>]*>' % sys.argv[1], h)
print(re.search(r'value=\"([^\"]*)\"', tag.group(0)).group(1))
" "$1"; }

AT=$(scrape authenticityToken)
RID=$(scrape restaurantId)
```

**Match the tag first, then pull `value` out of it** — do *not* use a single
`name="X" value="Y"` regex. Attributes are not in a fixed order: `restaurantId` renders as
`<input ng-non-bindable type="hidden" name="restaurantId" id="restaurantId" value="…" />`,
with `id` sitting *between* `name` and `value`, so a name-then-value pattern silently finds
nothing and you'll wrongly conclude the field is absent. It is present on every admin form
page. (`authenticityToken` happens to match either way — don't let that mislead you.)

`restaurantId` is the restaurant's **numeric** id. If you ever need it without a form page,
`GET /config/v2/restaurantConfigs` → `restaurant.id`.

**Read the fetched HTML to learn the field names and their defaults** rather than guessing.
Dump every input/select with its value and `checked` state, then send the page's own
defaults and change only what you mean to change:

```bash
python3 -c "
import re
h=open('/tmp/form.html').read()
for m in re.finditer(r'<(input|select|textarea)[^>]*name=\"([^\"]+)\"[^>]*>', h):
    v=re.search(r'value=\"([^\"]*)\"', m.group(0))
    print(m.group(2), '=', v.group(1) if v else None, 'CHECKED' if 'checked' in m.group(0) else '')
"
```

A successful form POST returns **302** with an empty body (Play redirects to the editor).
302 is success, not a failure — confirm by re-reading the list page, not by the status alone.

Boolean fields render as radio pairs (`...=false` and `...=true`, one `CHECKED`); send the
single value you want. Entity rows bind per-index as `<prefix>[N].<field>`, with
`<prefix>[N].id` identifying an existing row.

## Publishing

Config writes are **saved**, not live, until published.

```
POST https://preprod.eng.toasttab.com/restaurants/admin/quickApplyConfigChanges
```

```bash
curl -s -b /tmp/tw.cookies -c /tmp/tw.cookies --max-time 300 \
  -H "Authorization: Bearer $TOKEN" -H "Toast-Restaurant-External-ID: $RX" -X POST \
  --data-urlencode "authenticityToken=$AT" --data-urlencode "restaurantId=$RID" \
  "https://preprod.eng.toasttab.com/restaurants/admin/quickApplyConfigChanges"
```

Success is JSON: `{"status":200,"message":"Configuration published successfully to <name>."}`.
It publishes **synchronously**, so a 200 means the config is live.

Notes and gotchas:
* This is a **full restaurant publish** — every pending config change at that restaurant
  goes out with yours, not just the one you made. Toastweb exposes no partial-publish route
  for general configs (only `/toast/admin/payments/servicecharge/partialPublish` for service
  charges). Services' own partial-publish paths are `@ServiceMachineAuthorization`, so they are
  an option with an M2M token if you hold the scope and need to avoid a full publish.
* `POST /restaurants/admin/quickPublish` looks like the right route but **403s** with a
  bearer token. Use `quickApplyConfigChanges`.
* `POST /restaurants/admin/applyConfigChanges` takes the same params but publishes
  **asynchronously** (`{"message":"Publishing has started..."}`) — you'd have to poll.
  Prefer `quickApplyConfigChanges` so you know when it's done.
* All are gated on `PUBLISHING_BIT`. A 403 usually means you have no customer-access session
  at that restaurant (or it expired) — create one via **/authenticate-request** and retry
  with the **same** token. No need to re-mint.

## Verifying

Always verify against the **published** config read, not the saved/staged one, and not the
admin HTML you just posted to. For alternate payment types:

```
GET https://ws-preprod-api.eng.toasttab.com/config/v2/alternatePaymentTypes
    Toast-Restaurant-External-ID: <restaurantGuid>
```

The `config` service's `v2` config reads are `@AdminAuthorization`/`@CustomerAuthorization`,
so a user token works on them even when the owning service's write API doesn't. They also work
with an M2M token holding `config:read`. `GET /config/v2/restaurantConfigs` returns the
restaurant's core config (name, numeric id, management set GUID) and is a handy sanity check.

## Alternate payment methods (APMs / other payment types)

An APM is an `AlternatePaymentType`, called an "other payment type" in the POS UI. Two ways to
create one:

**Preferred — `toast-payments-config`'s REST API with an M2M token.**
`AlternatePaymentTypeResource` is `@ServiceMachineAuthorization`, so a *user* token 403s on it,
but `preprod-m2m bearer` reaches it:

| Call | Scope required |
|---|---|
| `POST /payments-config/v1/alternatePaymentType` | `payments.alternate-type:create` |
| `GET /payments-config/v1/alternatePaymentType` | `payments.alternate-type:read` |

ren's client holds both. The GET requires a non-empty `restaurantSetIds` query param — omitting it
returns 400, not 403.

**Fallback — toastweb's admin form.** Use this when you can't get the scope. No other service
path exists: order-routing's create is `@AdminAuthorization` but only mints its own "Paid at …"
type for routing-enabled restaurants; toast-pms-provider handles hotel *mappings*, not the APT;
payments-config's GraphQL subgraph has mutations only for GFD config.

Either way the write is **saved, not live** — publish and verify afterward.

### Toastweb APM routes

Routes (all under toastweb's catch-all `* /restaurants/admin/payments/{action}`):

| Action | Method | Purpose |
|---|---|---|
| `/restaurants/admin/payments/paymentTypes` | GET | list all APMs (scrape ids + CSRF here) |
| `/restaurants/admin/payments/paymentType` | GET | blank new-APM form (omit `?id=`) |
| `/restaurants/admin/payments/paymentType?id=<id>` | GET | existing APM's editor |
| `/restaurants/admin/payments/paymenttypesubmit` | POST | create (no `id`) or edit one APM |
| `/restaurants/admin/payments/paymenttypessubmit` | POST | bulk-edit the APM list (used to archive) |

Note the two distinct submit routes: singular `paymenttypesubmit` for one APM, plural
`paymenttypessubmit` for the list.

### Creating an APM via the toastweb form

GET the blank form (`/paymentType` with **no** `id`), then POST its own defaults to
`paymenttypesubmit` changing only `paymentType.name`. `paymentType.restaurantSet.id` and
`paymentType.owningSet.id` come pre-filled with the restaurant set leaf's numeric id — keep
them.

```bash
curl -s -b /tmp/tw.cookies -c /tmp/tw.cookies -o /dev/null -w "%{http_code}\n" --max-time 120 \
  -H "Authorization: Bearer $TOKEN" -H "Toast-Restaurant-External-ID: $RX" -X POST \
  --data-urlencode "authenticityToken=$AT" \
  --data-urlencode "restaurantId=$RID" \
  --data-urlencode "paymentType.name=<APM name>" \
  --data-urlencode "paymentType.restaurantSet.id=888664" \
  --data-urlencode "paymentType.owningSet.id=888664" \
  --data-urlencode "paymentType.hideOnPos=false" \
  --data-urlencode "paymentType.requiresManager=false" \
  --data-urlencode "paymentType.showOnReceipt=false" \
  --data-urlencode "paymentType.taxExempt=false" \
  --data-urlencode "paymentType.showTipDialog=true" \
  --data-urlencode "paymentType.showThankYouDialog=true" \
  --data-urlencode "paymentType.showReceiptDialog=true" \
  --data-urlencode "paymentType.allowPaidCheckStatus=false" \
  --data-urlencode "paymentType.rewardsSignup=true" \
  --data-urlencode "paymentType.allowRewardsCard=true" \
  "https://preprod.eng.toasttab.com/restaurants/admin/payments/paymenttypesubmit"
```

Those booleans are the blank form's own pre-checked values for a new type — re-scrape rather
than trusting this list, since flags are feature-flagged per restaurant (`requiresSignature`,
`useForGuestLookup`, `reportAsPrimaryPaymentType`, `combinePaymentWithTip` appear only when
their flags are on). Optional extras: `paymentType.description`,
`paymentType.providerGuid` (a tender provider, only when the Tender API feature is on).

Expect **302**. Then publish and verify.

### Archiving an APM

"Delete" in this UI is an **archive** (soft delete): set `deleted=true` on the row via the
**plural** `paymenttypessubmit`. Binding is per-row, so you only need to submit the one row
you're archiving — you do not have to round-trip the whole list:

```bash
curl -s -b /tmp/tw.cookies -c /tmp/tw.cookies -o /dev/null -w "%{http_code}\n" --max-time 120 \
  -H "Authorization: Bearer $TOKEN" -H "Toast-Restaurant-External-ID: $RX" -X POST \
  --data-urlencode "authenticityToken=$AT" \
  --data-urlencode "restaurantId=$RID" \
  --data-urlencode "paymentTypes[0].id=<numeric APM id>" \
  --data-urlencode "paymentTypes[0].name=<existing name>" \
  --data-urlencode "paymentTypes[0].restaurantSet.id=888664" \
  --data-urlencode "paymentTypes[0].owningSet.id=888664" \
  --data-urlencode "paymentTypes[0].deleted=true" \
  "https://preprod.eng.toasttab.com/restaurants/admin/payments/paymenttypessubmit"
```

Get the numeric id from the list page — each row links
`href="/restaurants/admin/payments/paymenttype?id=<numericId>"` and carries a hidden
`paymentTypes[N].id`. `name` must be non-blank or validation rejects the row.

After archiving, the APM disappears from the list page and from published
`/config/v2/alternatePaymentTypes` once you publish.

### APM gotchas

* **`<span class="archived-tag"> archived</span>` renders on every row** in the list HTML
  (CSS-hidden unless actually archived). Do **not** infer archived state from its presence —
  you'll conclude every payment type is archived. Judge by presence/absence in the list and
  in published config instead.
* Types shown with a trailing `*` (e.g. `Toast Cash *`) are `UNEDITABLE` configs
  (`editabilityLevel`), typically Toast-managed ones like Toast Cash. Their `id` renders as
  `false`, and they can't be edited through the form.
* `HIDDEN`-editability types are filtered out of the list entirely and 404 on the editor.
* Two GUIDs are in play: the toastweb **numeric id** (forms) and the published-config
  **entity GUID** (`/config/v2/alternatePaymentTypes`). They're different identifiers for
  the same APM; don't substitute one for the other.
* The restaurant set leaf is the APM's `target`/`owner`. The form pre-fills its numeric id.
  If you ever need the GUID form,
  `GET /restaurant-sets/v1/restaurant-groups/all?showLoyaltyGroups=false` with both
  `Toast-Restaurant-External-ID` and `Toast-Management-Set-GUID` headers returns
  `locations[].restaurantLeafGuid`. (`/restaurant-sets/v2/restaurantset/leaf` and
  `/v1/restaurantset/byRestaurantGuid` both 403 with a user token.) Get the management set
  GUID from `GET /config/v2/restaurantConfigs` → `restaurant.managementSet.guid`.

## Behaviors

* **Preprod only.** Don't run these against prod.
* **Authenticate via /authenticate-request.** Read the resource's annotation first, then mint the
  matching token — user (`preprod bearer`) or M2M (`preprod-m2m bearer`).
* **Before driving a toastweb form or a `@CustomerAuthorization` endpoint, get a customer-access
  session at the target restaurant.** Doing this first avoids misreading a session 403 as a wrong
  endpoint or a bad token. M2M and `@AdminAuthorization` calls don't need one.
* **On a 403 from a machine endpoint, check the scope before giving up.** `@ServiceMachineAuthorization`
  no longer means unreachable; it usually means a scope ren needs to grant.
* Confirm with the user before any mutating call, showing the resolved URL, headers (token
  redacted), and exact body.
* **Never send a mutating request you've described as a probe, dry run, or aborted.** If you
  don't intend it to execute, don't run it — a config write that "was just a test" leaves a
  real row behind at the restaurant.
* Change only the fields the task calls for; send the form's own defaults for the rest.
* Always publish after writing, and always verify against published config.
* If you create something by mistake, archive it and say so plainly in your report.
