---
name: modify-restaurant-configs
description: |
  Use when a task needs a preprod restaurant to have a different configuration — create,
  edit, or archive a service charge, alternate payment method (other payment type / APM),
  dining option, discount, or any other restaurant config — and then publish it so the
  change is live. Covers finding a usable endpoint (toastweb admin form vs. an
  @AdminAuthorization/@CustomerAuthorization service endpoint), the toastweb CSRF/session
  dance, publishing via quickApplyConfigChanges, and verifying against published config.
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

## Finding an endpoint you can actually call

Your bearer is a **toastweb user token** (`/toastweb-token`, or `/call-toast-api` which
fetches one internally). That token can reach exactly two kinds of surface:

1. A **toastweb endpoint or admin form** (`preprod.eng.toasttab.com`).
2. A **non-toastweb endpoint or GraphQL mutation** tagged `@CustomerAuthorization` or
   `@AdminAuthorization`.

Endpoints tagged **only** `@ServiceMachineAuthorization` are unreachable — a user token
403s on them, including their GETs. Note this is a *different* 403 from the missing-session
one below: annotation 403s fail at every restaurant, session 403s fail only where you lack a
session. Check which you're facing before rewriting the request. Check the
resource class's annotations on Sourcegraph *before* building a request: a class-level
`@ServiceMachineAuthorization` with no admin/customer annotation beside it means look
elsewhere, not that your request is malformed.

Use Sourcegraph to locate the config's write path. Search the entity name (e.g.
`AlternatePaymentType`, `ServiceCharge`) across `*Resource.kt|java` for the service path,
and across `conf/routes` + `app/controllers` in `toastweb` for the admin form. When a
service's REST API is machine-only, **toastweb's admin form is usually the only
user-authorized way to write the config** — and it writes through toastweb's own JPA
path, which is the same thing the human UI does.

## Starting a preprod toastweb session at the restaurant

**Do this first, before any admin-form GET.** A Toast admin bearer carries no restaurant
context, so without a session at your target restaurant the admin routes **403** even though
the token is perfectly valid. This is PCR customer access, not a broken token.

The tell is that the 403 is *restaurant-scoped, not route-scoped*: the same route returns 200
at a restaurant you already have a session at and 403 at one you don't.
`/restaurants/admin/dashboard` returns 200 either way, so it is **not** a useful probe —
use a payments admin route to test.

No browser and no fresh token are needed — two API calls:

```bash
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

Managing sessions (all `@AdminAuthorization`, so a user token works):

| Call | Purpose |
|---|---|
| `GET /policy-administration/v1/customer-sessions` | list your active sessions — check here first |
| `POST /policy-administration/v1/customer-sessions` | create (needs `ACCESS_ANY_RESTAURANT_BIT`) |
| `PATCH /policy-administration/v1/customer-sessions/{id}` | extend (resets to a fresh hour) |
| `DELETE /policy-administration/v1/customer-sessions/{id}` | terminate |

Notes:
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
TOKEN=$(python3 .../toastweb-token/toastweb_token.py token preprod 2>/dev/null)
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
  charges), and services' own partial-publish paths are `@ServiceMachineAuthorization`-only.
* `POST /restaurants/admin/quickPublish` looks like the right route but **403s** with a
  bearer token. Use `quickApplyConfigChanges`.
* `POST /restaurants/admin/applyConfigChanges` takes the same params but publishes
  **asynchronously** (`{"message":"Publishing has started..."}`) — you'd have to poll.
  Prefer `quickApplyConfigChanges` so you know when it's done.
* All are gated on `PUBLISHING_BIT`. A 403 usually means you have no customer-access session
  at that restaurant (or it expired) — create one per the session section above and retry
  with the **same** token. No need to re-mint.

## Verifying

Always verify against the **published** config read, not the saved/staged one, and not the
admin HTML you just posted to. For alternate payment types, via `/call-toast-api`:

```
GET https://ws-preprod-api.eng.toasttab.com/config/v2/alternatePaymentTypes
    Toast-Restaurant-External-ID: <restaurantGuid>
```

The `config` service's `v2` config reads are `@AdminAuthorization`/`@CustomerAuthorization`,
so a user token works on them even when the owning service's write API doesn't.
`GET /config/v2/restaurantConfigs` returns the restaurant's core config (name, numeric id,
management set GUID) and is a handy sanity check.

## Alternate payment methods (APMs / other payment types)

An APM is an `AlternatePaymentType`, called an "other payment type" in the POS UI. There is
**no user-authorized REST API to create one.** `toast-payments-config`'s
`AlternatePaymentTypeResource` (`POST /payments-config/v1/alternatePaymentType`) is
`@ServiceMachineAuthorization`-only — even its GET 403s with a user token. Nor is there any
other path: order-routing's create is `@AdminAuthorization` but only mints its own
"Paid at …" type for routing-enabled restaurants; toast-pms-provider handles hotel
*mappings*, not the APT; payments-config's GraphQL subgraph has mutations only for GFD
config. Use toastweb's admin form.

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

### Creating an APM

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
* **Check for a customer-access session at the target restaurant before anything else**
  (`GET /policy-administration/v1/customer-sessions`) and create one if it's missing. Doing
  this first avoids misreading a session 403 as a wrong endpoint or a bad token.
* Confirm with the user before any mutating call, showing the resolved URL, headers (token
  redacted), and exact body.
* **Never send a mutating request you've described as a probe, dry run, or aborted.** If you
  don't intend it to execute, don't run it — a config write that "was just a test" leaves a
  real row behind at the restaurant.
* Change only the fields the task calls for; send the form's own defaults for the rest.
* Always publish after writing, and always verify against published config.
* If you create something by mistake, archive it and say so plainly in your report.
