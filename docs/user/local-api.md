---
title: Local automation API
description: Enable the loopback API, approve least-privilege clients, manage access, and diagnose connections safely.
nav_order: 10
parent: User Guide
---

# Local automation API

NeoAnki's versioned API lets a program on the same Mac automate authoring,
study, media, and deck transfers. It is local automation only: it is not a
synchronization service, a remote-access server, or an AnkiConnect
compatibility endpoint.

The API is disabled on a clean installation. It listens only on IPv4 loopback
(`127.0.0.1`) after a user explicitly enables it. Do not use a proxy, tunnel,
port-forward, or firewall exception to expose it to another device.

## Enable or disable the API

1. Open **NeoAnki → Settings** and select **Local API**.
2. Turn on **Enable local automation API**.
3. Confirm that the status says **Listening on the configured loopback port**.

The default address is `http://127.0.0.1:8766`. Turning the setting off closes
the listener and active event streams immediately; it does not alter library
content or approved-client records.

For a liveness check that exposes no library information, request:

```sh
curl --fail --silent http://127.0.0.1:8766/health
```

A successful response is exactly `{"status":"ok"}`.

## Change the port

In **NeoAnki → Settings → Local API**, enter a port from `1024` through `65535`
and choose **Apply**. If the API was running, NeoAnki closes the previous
listener before trying the new port.

When another process already owns the selected port, NeoAnki leaves the API
disabled and reports that exact port conflict. It never scans for or silently
chooses another port. Either stop the conflicting process or choose a different
port, then enable the API again.

## Approve a client

A new client sends a pairing request containing its display name, requested
scopes, and—only for a browser client—its exact origin. NeoAnki displays all of
these values in **Approve Local API Client?**. Check them before choosing
**Approve**. Choose **Deny** if the request is unexpected or asks for broader
access than its purpose requires.

Approval returns an opaque bearer token to that client once. NeoAnki does not
show the token later. A pairing request expires after five minutes, and NeoAnki
shows at most one approval prompt at a time.

NeoAnki stores only a one-way verifier for each token in its private application
support directory. It does not store bearer tokens or request macOS Keychain
access. After updating from an older build that used Keychain storage, pair each
client again; NeoAnki intentionally does not read the legacy entry so the update
cannot trigger a Keychain permission prompt.

Scopes are independent permissions:

| Scope | Allows |
| --- | --- |
| `library.read` | Read decks, item types, items, cards, media, and changes |
| `items.write` | Create, replace, delete, and tag items |
| `decks.write` | Create, update, and delete decks through guarded plans |
| `schemas.write` | Create and reconcile item types and templates |
| `study.review` | Create study sessions, reserve cards, review, revert, suspend, and reset |
| `media.write` | Upload and reserve validated media bytes |
| `library.import` | Stage, validate, and commit imports |
| `library.export` | Create and download portable-deck exports |
| `vocabulary.read` | List installed vocabulary packs and read entries and declared media |
| `vocabulary.write` | Stage, validate, install, and remove vocabulary packs |

`settings.write` and `ui.control` are reserved and provide no version-1
operations. Use the smallest set of scopes that completes the integration's
job. A read-only tool normally needs only `library.read`.

## Use installed vocabulary packs

A vocabulary client can discover installed packs with
`GET /v1/vocabulary-packs`, search a selected pack with
`GET /v1/vocabulary-packs/{id}/entries`, retrieve a complete entry by ID, and
download media declared by that pack. These operations are fully offline and
require `vocabulary.read`; they neither create NeoAnki items nor grant access to
the rest of the library.

The API fully validates a pack before its first lookup. Later lookups reuse the
same read-only validated pack while its complete filesystem signature remains
unchanged; any detected change forces full validation again. There is no
authored-deck or network fallback when an installed pack is missing or invalid.

To turn a vocabulary result into a study item, request `items.write` separately
and submit the selected lexical fields through the item endpoints. To install
or remove whole immutable `.neovocab` packs, use `vocabulary.write` and the
staged `/v1/vocabulary-pack-imports` lifecycle. The API accepts declared bytes,
not local paths or remote URLs. See the
[normative vocabulary API contract]({{ '/VOCABULARY_API/' | relative_url }}) for routes, limits,
preconditions, and job states.

## Use and protect a token

Protected requests use `Authorization: Bearer <token>`. Never put a token in a
URL, query parameter, source file, screenshot, issue report, analytics event,
or command pasted into a shared shell history. Prefer an operating-system
credential store. For short local diagnostics, read it from a protected
environment variable without printing it:

```sh
curl --fail --silent \
  -H "Authorization: Bearer ${NEOANKI_API_TOKEN:?token is not set}" \
  http://127.0.0.1:8766/v1/clients/current
```

The API contract is available from `GET /v1/openapi.json`. Mutating clients
must follow its `If-Match` and `Idempotency-Key` requirements; retrying a write
without those controls can produce a revision conflict or be rejected.

## Inspect or revoke access

Approved clients appear in **NeoAnki → Settings → Local API → Approved
clients**. Each entry shows the display name and exact scopes. Choose **Revoke**
to invalidate that client's token. Revocation affects its next request and
closes an already-open event stream.

An authenticated client can inspect or revoke only itself with
`GET /v1/clients/current` and `DELETE /v1/clients/current`. Self-revocation
requires the current `ETag` in `If-Match`.

## Diagnose connection and request errors

| Symptom | Check |
| --- | --- |
| Connection refused | Confirm **Enable local automation API** is on, the status says **Listening**, and the client uses the displayed port. |
| Port unavailable | Stop the process using that port or apply another port; NeoAnki will not choose one automatically. |
| `401 unauthorized` | The bearer token is absent, malformed, expired, or revoked. Pair again if the grant was revoked. |
| `403 insufficient_scope` | Inspect the client's approved scopes and pair a separate least-privilege client if more access is genuinely required. |
| `403 invalid_host` or origin error | Use the displayed `127.0.0.1:<port>` authority. Browser clients must use the exact origin approved during pairing. |
| `412 revision_conflict` | Fetch the resource again, review the new state, and retry with its new `ETag`. |
| `428 precondition_required` | Supply the documented `If-Match` header. |
| `409 idempotency_conflict` | Do not reuse an `Idempotency-Key` for different input. Allocate a new key for a new logical operation. |
| `422 validation_failed` | Read the machine-readable `errors` pointers and correct the request; unknown members are rejected. |
| `413 payload_too_large` | Reduce the JSON, media, or staged transfer below the endpoint's documented limit. |

Errors use `application/problem+json` and include a stable `code` plus a
`requestId`. Record the request ID, app version, route, status, and approximate
time when diagnosing a problem. Do not record the authorization header or
request content that contains private study material.

## Report a security issue

Use the repository's [private vulnerability reporting
form](https://github.com/neoanki2/neoanki2/security/advisories/new) for a
suspected token, authorization, loopback, path, media, or data-disclosure flaw.
Include the NeoAnki version, macOS version, affected route, response status and
`requestId`, and minimal reproduction steps.

Never include a live bearer token, full `Authorization` header, private item or
answer content, imported deck, media bytes, local API authorization file, or
library database. Revoke the affected client before collecting diagnostics. If
a token must be represented, use a fixed placeholder such as
`<redacted-token>`.

---

**Reference:** [Normative local API requirements]({{ '/LOCAL_API/' | relative_url }})
