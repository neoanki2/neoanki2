---
title: Local API requirements
description: Normative requirements and acceptance criteria for the versioned NeoAnki local automation API.
audience: developer
parent: Developer Guide
---

# NeoAnki Local API Requirements

## 1. Status and purpose

This document is the normative requirements specification for NeoAnki local
API version 1. It defines externally observable behavior, mandatory acceptance
criteria, and the release gate for the implementation. The presence of a route
or passing unit test alone does not establish conformance; version 1 is
conforming only when the complete release gate in section 17 passes.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**,
and **MAY** are interpreted as in RFC 2119 and RFC 8174. A version-1 server is
conforming only when every criterion identified as `V1`, `GEN`, `SEC`, `DECK`,
`TYPE`, `ITEM`, `TAG`, `CARD`, `STUDY`, `MEDIA`, `TRANSFER`, `BATCH`, or `EVENT`
passes. Criteria identified as `POST` are explicitly deferred.

The API exists for local tools such as browser extensions, command-line
clients, companion applications, and test automation. It is not a cloud-sync
protocol and is not an AnkiConnect compatibility layer.

## 2. Product boundary

The API follows the NeoAnki domain model:

1. clients author structured `Item` values;
2. an `ItemType` declares fields and templates;
3. NeoAnki generates `Card` values from an item and its templates; and
4. only a successful review changes a card's normal memory state.

> **UI terminology:** Item Type Studio presents a persisted `Template` as a
> **Card setup**. This API specification continues to use `Template` and
> `template` because the version-1 contract and wire representation are
> unchanged.

Clients MUST NOT create or delete cards directly. Clients MUST NOT assign raw
stability, difficulty, phase, repetition, lapse, last-review, or due values.
Schema edits, card generation, scheduling, review logging, media reference
accounting, and study-day limits remain server responsibilities.

The following are version-1 non-goals:

- Anki `.apkg` or `.colpkg` compatibility;
- HTML or CSS card content;
- arbitrary SQL, file access, or code execution;
- remote-network exposure or multi-user authorization;
- cloud synchronization or conflict-free replication;
- arbitrary writes to review history; and
- a generic `invoke(action, params)` endpoint.

## 3. Architecture requirements

The HTTP server MUST be an adapter over a transport-neutral application service.
HTTP request or response types MUST NOT become NeoAnkiCore domain models.
The desktop UI and HTTP adapter MUST use the same command paths for mutations so
validation, transactions, scheduling, event production, and media accounting
cannot diverge.

**Acceptance criteria**

- **GEN-001:** Given equivalent valid item-create commands from the UI service
  and HTTP adapter, both produce domain-equivalent items and generated cards.
- **GEN-002:** Given an invalid domain value, every adapter returns failure and
  the library database, media reference counts, and change cursor remain
  unchanged.
- **GEN-003:** No public request or response includes a SQLite table name,
  database row identifier, absolute local path, Swift type discriminator, or
  encoded private persistence blob.

## 4. Transport, discovery, and versioning

The version-1 transport is HTTP/1.1 with JSON over loopback. The default
authority is `http://127.0.0.1:8766`. The application MAY allow the user to
choose another port, but it MUST NOT silently bind a non-loopback address.
The API is disabled by default. If the configured port is unavailable, NeoAnki
MUST leave the API disabled, show a local diagnostic, and MUST NOT scan for or
silently select another port.

All versioned routes begin with `/v1`. A breaking contract change requires a
new URL major version. Additive response members and capabilities do not require
a new major version. Clients MUST ignore unknown response members. Servers MUST
reject unknown request members with `validation_failed` so misspelled commands
cannot appear to succeed.

The server exposes:

| Method | Path | Authorization | Purpose |
| --- | --- | --- | --- |
| `GET` | `/health` | none | Process liveness only |
| `GET` | `/v1/meta` | none | API version and non-sensitive capabilities |
| `GET` | `/v1/openapi.json` | none | Exact version-1 OpenAPI contract |

`GET /health` returns only `{"status":"ok"}` and MUST NOT reveal library
metadata. `GET /v1/meta` returns the API major version, application version,
server instance ID, pairing availability, and capability identifiers. The
instance ID changes whenever the server process starts and is not a library or
user identifier.

JSON bodies MUST be UTF-8. Timestamps MUST be RFC 3339 UTC with millisecond
precision. UUIDs MUST use the lowercase hyphenated representation. JSON numbers
MUST be finite. A normal JSON request body is limited to 5,000,000 bytes;
endpoint-specific media and transfer limits apply instead to byte uploads. The
bundled loopback listener does not impose a lower whole-request ceiling; an
embedding application MAY configure an additional transport guard.

**Acceptance criteria**

- **GEN-004:** With the API enabled, connections to `127.0.0.1` on the
  configured port succeed and connections through every non-loopback interface
  fail.
- **GEN-005:** With the API disabled, no listener exists and no discovery or
  pairing endpoint accepts a connection.
- **GEN-006:** Every documented request and response validates against
  `/v1/openapi.json`; every route in the OpenAPI document has a contract test.
- **GEN-007:** A request containing one unknown member or an unknown enum value
  returns HTTP 422 with `validation_failed` and makes no mutation.
- **GEN-008:** A JSON body of 5,000,001 bytes returns HTTP 413 before JSON
  decoding or domain work begins.
- **GEN-009:** A server never accepts HTTP methods or unversioned aliases that
  are absent from the OpenAPI document.

## 5. Authentication, pairing, and browser security

Except for the three discovery routes in section 4 and the pairing route
defined below, every request requires an opaque bearer token in the
`Authorization` header. A token is bound to one client identity and a set of
scopes:

- `library.read`;
- `items.write`;
- `decks.write`;
- `schemas.write`;
- `study.review`;
- `media.write`;
- `library.import`;
- `library.export`;
- `vocabulary.read`;
- `vocabulary.write`;
- `settings.write`; and
- `ui.control`.

The last two scopes are reserved for post-v1 operations. A token MUST contain
at least 256 bits of cryptographically random entropy. The server stores only a
cryptographic verifier in private application-support storage; it never stores
the bearer token. Tokens MUST NOT appear in a URL, response body after initial
issuance, normal log, event, crash annotation, or analytics record.

`POST /v1/pairings` begins pairing without authorization. It accepts a client
display name of 1 to 256 UTF-8 bytes after Unicode whitespace trimming,
requested scopes, and optional browser origin. The name MUST NOT contain control
characters. The server MUST NOT issue a token until the user approves the exact
client, origin, and scopes in NeoAnki. Approval returns the token exactly once.
Denial returns `pairing_denied`. Pairing requests expire after five minutes. The
server permits at most one visible pairing prompt and five new pairing requests
per rolling minute; excess requests return HTTP 429 without displaying another
prompt.

Authenticated clients can inspect and revoke their own grant:

| Method | Path | Required scope | Purpose |
| --- | --- | --- | --- |
| `GET` | `/v1/clients/current` | any | Inspect current grant |
| `DELETE` | `/v1/clients/current` | any | Revoke current grant |

NeoAnki's client-management UI can revoke any grant. Revocation takes effect
before the revoke operation reports success.

The server MUST validate the `Host` header against its configured loopback
authority. Browser origins are denied unless the exact origin was approved for
that token. Wildcard origins are forbidden. The pairing route MAY echo the
syntactically valid requesting origin solely so the browser can complete the
user-approved pairing exchange; that exception grants no access to any other
route. All protected routes MUST return an origin only when it exactly matches
the token's approved origin. Preflight responses MUST advertise only methods
and headers required by the requested route. Cookie authentication is
forbidden.

**Acceptance criteria**

- **SEC-001:** A protected request with no token, a malformed token, an expired
  token, or a revoked token returns HTTP 401 and performs no domain or file
  mutation.
- **SEC-002:** A valid token missing one required scope returns HTTP 403 with
  `insufficient_scope`; the response identifies the required scope.
- **SEC-003:** Pairing cannot complete through HTTP alone: an integration test
  must exercise explicit user approval or the dedicated test-only approval
  seam.
- **SEC-004:** Approving three requested scopes grants exactly those scopes;
  unrequested scopes are absent.
- **SEC-005:** After revocation succeeds, the revoked token fails on the next
  protected request, including on an already-open event stream.
- **SEC-006:** Requests with a foreign `Host`, an unapproved `Origin`, origin
  `null`, or credentials in a query parameter are rejected before route
  execution.
- **SEC-007:** A repository-wide test capture of application logs during
  pairing and authenticated requests contains neither the issued token nor its
  full authorization header.
- **SEC-008:** Six pairing requests inside one minute display no more than one
  prompt at a time; at least the sixth request receives HTTP 429 and no token.
- **SEC-009:** A client name containing control characters or exceeding 256
  UTF-8 bytes is rejected before any approval prompt appears.

## 6. Common HTTP semantics

### 6.1 Resource identity and concurrency

Persisted resources use UUID identity. Names are mutable labels and MUST NOT be
accepted as substitutes for IDs. Every mutable resource representation contains
an integer `revision` beginning at 1 and increasing on each successful mutation.
The corresponding response includes an `ETag` derived from that revision.

`PUT`, `PATCH`, and destructive operations MUST require `If-Match`. A missing
header returns HTTP 428. A stale value returns HTTP 412 with
`revision_conflict`. Neither case mutates state.

Create requests MAY provide a UUID. If omitted, the server allocates one. A
provided UUID collision returns HTTP 409 unless the request is an exact replay
recognized through idempotency.

### 6.2 Idempotency

Every mutating route accepts `Idempotency-Key`. It is REQUIRED for item or media
creation, bulk operations, review submission, and import/export commits. A key
is scoped to the authenticated client and route and retained for at least 24
hours.

Replaying the same key with the same canonical request returns the original
status and logical response without repeating side effects. Reusing it with a
different request returns HTTP 409 with `idempotency_conflict`.

### 6.3 Pagination and filtering

Collection responses have this shape:

```json
{
  "data": [],
  "page": {
    "nextCursor": null,
    "limit": 50
  }
}
```

The default limit is 50 and the maximum is 200. Cursors are opaque and scoped
to the route, filters, ordering, and authenticated library. Reusing a cursor
with different query parameters returns HTTP 400 with `invalid_cursor`.
Collections MUST define deterministic ordering with UUID as the final
tie-breaker. Total counts MAY be omitted unless explicitly documented.

Version 1 supports typed query parameters for documented filters. It MUST NOT
accept Anki search expressions, SQL fragments, regular expressions, or an
undocumented generic query language.

### 6.4 Errors

Errors use `application/problem+json` and contain:

```json
{
  "type": "https://neoanki.example/problems/validation-failed",
  "title": "Request validation failed",
  "status": 422,
  "code": "validation_failed",
  "detail": "One or more fields are invalid.",
  "requestId": "01J...",
  "errors": [
    {"pointer": "/fields/0/value/text", "code": "required"}
  ]
}
```

`code` and nested error codes are stable machine identifiers. `detail` is for
humans and MUST NOT be the only way to distinguish failures. The server MUST
not return a Swift error description, stack trace, SQL text, token, media bytes,
or absolute path.

Required mappings include:

| HTTP | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_cursor` | Cursor and request do not match |
| 401 | `unauthorized` | Authentication failed |
| 403 | `insufficient_scope` | Token lacks a required scope |
| 404 | `resource_not_found` | Addressed resource does not exist |
| 409 | `idempotency_conflict` | Key was reused for different input |
| 409 | `resource_in_use` | Safe deletion is blocked |
| 409 | `study_conflict` | Card is reserved by another session |
| 410 | `cursor_expired` | Change recovery cursor is no longer retained |
| 412 | `revision_conflict` | `If-Match` is stale |
| 413 | `payload_too_large` | A byte limit was exceeded |
| 422 | `validation_failed` | Syntactically valid input violates the contract |
| 428 | `precondition_required` | Required `If-Match` is absent |
| 429 | `rate_limited` | A defensive limit was exceeded |
| 500 | `internal_error` | Unexpected server failure |

**Acceptance criteria**

- **GEN-010:** Two concurrent updates using the same revision produce exactly
  one success and one HTTP 412; the persisted resource equals the successful
  request.
- **GEN-011:** Replaying a required-idempotency request 100 times creates one
  logical mutation, one review log when applicable, and one change transaction.
- **GEN-012:** Every collection returns at most 200 records, has deterministic
  order, and can be traversed without a missing or duplicate ID while the
  collection is unchanged.
- **GEN-013:** Fault-injection tests for decoding, validation, database commit,
  and response serialization never return a partial success representation.
- **GEN-014:** Every non-2xx response validates against the problem schema and
  contains a stable `code` and `requestId`.

## 7. Deck operations

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/decks` | `library.read` | List the deck tree and summaries |
| `POST` | `/v1/decks` | `decks.write` | Create a deck |
| `GET` | `/v1/decks/{id}` | `library.read` | Read a deck |
| `PATCH` | `/v1/decks/{id}` | `decks.write` | Rename, move, or change its new-card limit |
| `POST` | `/v1/deck-deletion-plans` | `decks.write` | Preview a deletion policy |
| `POST` | `/v1/deck-deletion-plans/{id}/commits` | `decks.write` | Commit the unchanged plan |
| `POST` | `/v1/deck-reset-plans` | `study.review` | Preview a subtree progress reset |
| `POST` | `/v1/deck-reset-plans/{id}/commits` | `study.review` | Commit the unchanged reset plan |

A deck representation includes `id`, `revision`, `name`, `parentId`,
`newCardsPerDay`, direct item count, recursive item count, due count, and child
IDs. Moving a deck MUST reject cycles. `newCardsPerDay` is null for unlimited
and otherwise a non-negative integer.

A deletion plan specifies exactly one policy: `rejectIfNonempty`,
`unassignItems`, `moveItemsToParent`, or `deleteSubtreeAndItems`. The plan returns
the affected deck, item, card, review-log, and media-reference counts plus the
revisions on which it depends. `deleteSubtreeAndItems` requires a second explicit
boolean confirmation in the commit request. A plan expires after ten minutes or
as soon as an affected revision changes.

A reset plan covers one deck and all descendants. It reports exact card and
review-log counts. Commit requires `{"confirm":true}`, resets every covered card
to canonical new memory, preserves suspension and item content, and removes the
review history that produced the discarded schedules. Reset is atomic and is
not review undo.

**Acceptance criteria**

- **DECK-001:** Creating a root and child deck returns stable distinct UUIDs and
  the child appears once under its parent in the next list request.
- **DECK-002:** Attempting to move a deck beneath itself or any descendant
  returns HTTP 422 and leaves the entire tree unchanged.
- **DECK-003:** Setting a negative new-card limit returns HTTP 422; null, zero,
  and a positive integer round-trip without reinterpretation.
- **DECK-004:** Each deletion policy reports exact affected counts on the
  standard nested-deck fixture before it can commit.
- **DECK-005:** A deletion commit with an expired plan, changed dependency, or
  missing destructive confirmation fails without deleting or moving anything.
- **DECK-006:** A successful deletion plan commits deck, item, card, review-log,
  and media-reference changes atomically and emits one ordered change
  transaction.
- **DECK-007:** A reset plan reports exact affected card and review-log counts;
  commit resets precisely the deck subtree, preserves suspension and content,
  and removes its prior review logs in one transaction.

## 8. Item-type operations

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/item-types` | `library.read` | List definitions and provenance |
| `POST` | `/v1/item-types` | `schemas.write` | Create a definition |
| `POST` | `/v1/item-types/validate` | `schemas.write` | Validate without saving |
| `GET` | `/v1/item-types/{id}` | `library.read` | Read one definition |
| `PUT` | `/v1/item-types/{id}` | `schemas.write` | Replace one complete definition |
| `DELETE` | `/v1/item-types/{id}` | `schemas.write` | Delete an unused definition |
| `POST` | `/v1/item-types/{id}/duplicate` | `schemas.write` | Create an independent copy |
| `GET` | `/v1/decks/{id}/item-type-policy` | `library.read` | Read effective authoring policy |

Item-type writes are whole-definition operations. Field, template, and
component order is semantic. Templates expose `layout` plus semantic
`components`; `prompt` and `answer` remain compatibility projections for API v1
readers and writes. Field, template, and component references use UUIDs. Validation MUST apply
the same invariants as the native editor.

When a replacement removes or changes a field or template used by persisted
items or cards, the server returns HTTP 409 with
`impact_confirmation_required`, a complete impact summary, and a short-lived
impact token. Retrying the same replacement with `NeoAnki-Impact-Token` commits
only if all dependent revisions remain unchanged. Surviving generated cards
retain memory and review history; obsolete cards are removed; newly generated
cards begin in the new phase.

**Acceptance criteria**

- **TYPE-001:** Validation and creation accept and reject the same definition
  fixtures, and validation never changes the database or change cursor.
- **TYPE-002:** A field rename preserving its UUID preserves every item value
  and card ID that does not otherwise change.
- **TYPE-003:** Removing a referenced field or template cannot succeed without
  a valid impact token containing exact affected item and card counts.
- **TYPE-004:** After confirmed template reconciliation, unaffected card memory
  and review-log IDs are byte-for-byte unchanged, obsolete cards are absent,
  and new cards have new UUIDs and new memory.
- **TYPE-005:** Deleting a type with one or more items returns
  `resource_in_use`; deleting an unused type removes only that definition.
- **TYPE-006:** Duplication allocates new type, field, and template UUIDs and
  rewrites every internal reference to the duplicated IDs without changing any
  original resource.

## 9. Item and tag operations

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/items` | `library.read` | Search and paginate items |
| `POST` | `/v1/items` | `items.write` | Create one item |
| `POST` | `/v1/items/validate` | `items.write` | Validate without saving |
| `GET` | `/v1/items/{id}` | `library.read` | Read one complete item |
| `PUT` | `/v1/items/{id}` | `items.write` | Replace editable item content |
| `DELETE` | `/v1/items/{id}` | `items.write` | Delete an item and generated cards |
| `POST` | `/v1/items/{id}/duplicate-checks` | `library.read` | Find likely duplicates |
| `GET` | `/v1/tags` | `library.read` | List tags and usage counts |
| `POST` | `/v1/tag-renames` | `items.write` | Rename or merge a tag atomically |
| `DELETE` | `/v1/tags/{encodedTag}` | `items.write` | Remove a tag from every item |

An item includes `id`, `revision`, `itemTypeId`, `deckId`, ordered field values,
normalized unique tags, created timestamp, updated timestamp, and generated card
IDs. A tag is normalized by trimming Unicode whitespace and converting to
Unicode NFC. Tag identity is case-sensitive after normalization; exact
duplicates are removed while preserving first occurrence order. A normalized
tag is 1 to 1,024 UTF-8 bytes, and an item has at most 256 tags. Field values
use an explicit tagged union: `empty`, `text`, `rich`, `media`, `cloze`, or
`number`. They MUST NOT contain HTML or an arbitrary URL for local media.

`GET /v1/items` supports only documented filters: `deckId`,
`includeDescendants`, `itemTypeId`, `tag`, `text`, `schedulePhase`, `dueBefore`,
`createdAfter`, and `updatedAfter`. Text search uses the same
case/diacritic-insensitive behavior as native browsing. Filters combine with
logical AND. Repeated `tag` values mean all tags are required.

`itemTypeId` is immutable after item creation in version 1. Updating fields,
tags, or deck assignment reconciles cards in the same transaction. A media
value must reference a stored asset and, for a newly uploaded unreferenced
asset, a live reservation.

Duplicate checks are advisory. They return candidate item IDs and documented
reason codes but MUST NOT block creation unless the client separately requests
validation policy that does so.

**Acceptance criteria**

- **ITEM-001:** Creating an item with every supported content type persists an
  equivalent structured value and creates exactly the cards allowed by its
  templates and generation conditions.
- **ITEM-002:** Missing required fields, unknown field IDs, duplicate field IDs,
  field/value type mismatches, non-finite numbers, invalid cloze ranges, and
  unresolved media references each return a pointer-specific HTTP 422 without
  creating an item or card.
- **ITEM-003:** Updating item content changes the rendered content of every
  surviving card while preserving each surviving card ID, memory state, and
  review history.
- **ITEM-004:** Moving an item to a deck updates every generated card's deck in
  the same transaction and does not change card memory.
- **ITEM-005:** Deleting an item removes its generated cards and active review
  history atomically, decrements media references exactly once, and never
  removes an asset still referenced by another item.
- **ITEM-006:** Every supported item filter returns the same item ID set as the
  equivalent native browse operation on the contract fixture.
- **ITEM-007:** Renaming tag `a` to existing tag `b` leaves every affected item
  with exactly one normalized `b`; removing a tag changes no fields, cards, or
  scheduling state.
- **TAG-001:** Tag names round-trip in Unicode NFC, compare according to the
  documented case-sensitive normalization rule, and reject empty or over-limit
  values.
- **TAG-002:** Global rename and removal are atomic across all affected items
  and emit no event for an item that did not change.

## 10. Card operations

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/cards` | `library.read` | Query card metadata and memory |
| `GET` | `/v1/cards/{id}` | `library.read` | Read one card |
| `GET` | `/v1/cards/{id}/content` | `library.read` | Resolve layout, components, and prompt/answer projections |
| `GET` | `/v1/cards/{id}/review-preview` | `library.read` | Preview all rating outcomes |
| `PATCH` | `/v1/cards/{id}` | `study.review` | Change suspension only |
| `POST` | `/v1/cards/{id}/resets` | `study.review` | Reset progress after confirmation |

Card queries support `itemId`, `deckId`, `includeDescendants`, `templateId`,
`phase`, `isSuspended`, and `dueBefore`. A card representation includes its
item, template, deck, cloze group, skill, suspension, and memory state. The API
MUST identify memory units explicitly; stability and intervals are in days.

Resolved content returns ordered native `ResolvedSlot` equivalents with tagged
content values and presentation metadata. Answer content MAY be read by an
authorized client, but list endpoints MUST NOT include it implicitly.

Card `PATCH` accepts only `isSuspended`. Reset requires `If-Match`, an
idempotency key, and `{"confirm":true}`. It resets the card to canonical new
memory, removes that card's prior review logs, records an auditable reset event,
and does not fabricate a review log.

**Acceptance criteria**

- **CARD-001:** No version-1 route can create a card, delete one independently,
  change its item/template identity, or directly set memory fields.
- **CARD-002:** Resolved components and prompt/answer projections match NeoAnkiCore resolution for
  reveal, type, choose, record, audioSubmission, cloze, and arrange fixture templates.
- **CARD-003:** Suspending a due card removes it from due counts and new study
  reservations; unsuspending it restores eligibility without changing memory.
- **CARD-004:** Review previews are pure: calling the endpoint repeatedly does
  not change memory, logs, due counts, or the change cursor.
- **CARD-005:** A reset returns the card to canonical new memory, preserves the
  item, template, and suspension state, removes its prior review logs, and is
  exactly reversible only through a future explicit backup/restore mechanism,
  not review undo.

## 11. Study sessions and reviews

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `POST` | `/v1/study-sessions` | `study.review` | Start a scoped session |
| `GET` | `/v1/study-sessions/{id}` | `study.review` | Inspect session state |
| `POST` | `/v1/study-sessions/{id}/next` | `study.review` | Reserve the next eligible card |
| `POST` | `/v1/study-sessions/{id}/skips` | `study.review` | Release and skip the current card |
| `DELETE` | `/v1/study-sessions/{id}` | `study.review` | End and release the session |
| `POST` | `/v1/reviews` | `study.review` | Grade the reserved card |
| `POST` | `/v1/reviews/{reviewLogId}/reverts` | `study.review` | Compensate one review |

A session scope is all decks, unassigned items, or one deck with an explicit
`includeDescendants` flag. The server owns queue order, daily-new limits,
study-day rollover, and eligibility. Calling `next` reserves at most one card
for that session. A card MUST NOT be reserved simultaneously by the native UI
and an API session or by two API sessions.

A review request contains only `sessionId`, `cardId`, a rating of `again`,
`hard`, `good`, or `easy`, and a non-negative `durationMs`. Ordinary review
submission MUST use server time and MUST NOT accept a caller-supplied review
time, due date, phase, or memory value.

Successful submission updates memory and appends one review log in one database
transaction. It returns `reviewLogId`, previous and resulting phases, resulting
memory, and the change cursor. Only the returned active `reviewLogId` can be
reverted. Revert is a compensating operation: it marks the log reverted and
restores the exact pre-review memory only if no later active review exists for
that card.

**Acceptance criteria**

- **STUDY-001:** Sessions for all four scope variants return only cards eligible
  under the corresponding native scope, descendant, suspension, due, and
  daily-new rules.
- **STUDY-002:** One hundred concurrent `next` requests across sessions never
  produce the same active card reservation twice.
- **STUDY-003:** Submitting `again`, `hard`, `good`, and `easy` against fixed
  scheduler fixtures produces exactly the NeoAnkiCore scheduler results and one
  log each.
- **STUDY-004:** Replaying a successful review with its idempotency key returns
  the same review-log ID and memory without adding another log or schedule
  transition.
- **STUDY-005:** A review for an unreserved, skipped, expired, suspended,
  deleted, or differently reserved card returns a stable conflict error and
  leaves scheduling unchanged.
- **STUDY-006:** Ending a session releases its reservation before success is
  returned; the card can then be reserved by another eligible session.
- **STUDY-007:** Reverting the latest active review restores the exact previous
  memory and daily-new accounting. Reverting a missing, already reverted, or
  non-latest review fails without changing any log or card.
- **STUDY-008:** Killing the process after the database commit but before the
  HTTP response and retrying the request records exactly one review.

## 11A. Persistent study responses

Persistent spoken responses require scopes that are independent of
`library.read` and `study.review`. Existing grants MUST NOT receive them during
upgrade.

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/study-responses` | `study.responses.read` | Filter and page newest-first response metadata |
| `GET` | `/v1/study-responses/{id}` | `study.responses.read` | Read one response |
| `GET`, `HEAD` | `/v1/study-responses/{id}/content` | `study.responses.read` | Stream exact validated M4A bytes |
| `DELETE` | `/v1/study-responses/{id}` | `study.responses.delete` | Conditionally and idempotently delete one response |

The collection accepts `cardId`, `itemId`, `tag`, and `createdAfter` plus a
signed submitted-time/UUID keyset cursor. A representation includes revision,
live card and item IDs, source title, asset hash, content type, extension, byte
size, duration, capture time, and submission time. It has no review-log ID.

Content responses MUST preserve the stored bytes and expose hash verification.
Generic media endpoints MUST return 404 for a hash with no ordinary-content
reference. Response-only media changes MUST be hidden from `library.read`.
`studyResponse` create/delete events are visible only to
`study.responses.read`; event cursors still advance across hidden records.

Deletion requires `If-Match` and `Idempotency-Key`, releases exactly one media
reference, runs orphan cleanup after commit, and does not unsuspend the card.
Source mutations that would cascade a response return
`study_response_deletion_confirmation_required` with the affected count and a
revision-bound token. Strict cascades received from sync do not pause sync.

**Acceptance criteria**

- **RESPONSE-001:** Completion produces one response and suspends its card in
  one transaction without a review log or memory mutation; a stable response
  UUID makes a retry return the same result.
- **RESPONSE-002:** Read, filter, keyset pagination, authorization, conditional
  deletion, SSE/change filtering, and content hash integrity match OpenAPI.
- **RESPONSE-003:** Generic media and event routes reveal no private-only hash
  or metadata to a client lacking the response-read scope.
- **RESPONSE-004:** Response rows and response-only bytes never enter Cloud
  sync; an ordinary reference to identical bytes continues to sync normally.

## 12. Media operations

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `POST` | `/v1/media` | `media.write` | Upload and reserve an asset |
| `HEAD` | `/v1/media/{sha256}` | `library.read` | Test asset presence |
| `GET` | `/v1/media/{sha256}` | `library.read` | Download validated bytes |
| `GET` | `/v1/media/{sha256}/metadata` | `library.read` | Read safe metadata |

Upload uses a raw byte body plus declared media kind. The server detects format
from magic bytes, verifies that it matches the declared kind, selects the safe
canonical extension, enforces the existing NeoAnki media limits, computes
SHA-256, and stores bytes content-addressably.

The current limits are 20,000,000 bytes for audio, 10,000,000 for images,
15,000,000 for GIFs, and 100,000,000 for video. A successful upload returns
`assetHash`, `kind`, `fileExtension`, `byteSize`, `reservationId`, and
`reservationExpiresAt`. An item create or update adopts the reservation in its
transaction. Reservations last at least one hour. Unadopted assets eventually
become eligible for garbage collection.

The API does not expose media deletion in version 1. A download's content type
and filename derive from validated stored metadata, never request input.

**Acceptance criteria**

- **MEDIA-001:** Every supported format fixture uploads and downloads
  byte-for-byte identically with the expected lowercase SHA-256 and canonical
  extension.
- **MEDIA-002:** Wrong magic bytes, ambiguous bytes, a kind mismatch, an
  unsupported format, and each one-byte-over-limit fixture fail before durable
  adoption.
- **MEDIA-003:** Uploading identical bytes repeatedly stores one durable byte
  object but returns independently usable reservations.
- **MEDIA-004:** Creating two items from the same asset yields a reference count
  of two; deleting either item leaves the asset downloadable.
- **MEDIA-005:** No request accepts an absolute path, `file:` URL, relative
  traversal, symlink target, or external URL as a stored media reference.
- **MEDIA-006:** Range requests, when advertised as a capability, return exact
  byte ranges; otherwise every range request fails consistently rather than
  returning a misleading partial response.

## 13. Vocabulary pack operations

The local API exposes installed offline vocabulary packs through independent
`vocabulary.read` and `vocabulary.write` scopes. Clients can list packs, search
or retrieve complete lexical entries, download declared local media, stage and
validate pack installation, commit an installation atomically, and remove an
installed pack. It never accepts a client filesystem path or performs a network
dictionary lookup.

The complete normative route, lifecycle, validation, security, and acceptance
contract is defined in [Vocabulary API requirements]({{ '/VOCABULARY_API/' | relative_url }}).

## 14. Bulk and transaction operations

`POST /v1/items/bulk` with `items.write` creates, replaces, or deletes up to 500
items in one request. The request declares `atomic: true`; version 1 rejects
`atomic: false`. Client-supplied UUIDs allow items in the request to refer to
decks, item types, and media that already exist. Cross-resource creation belongs
to the authored-deck import path, not this endpoint.

The endpoint supports `dryRun: true`. A dry run performs complete decoding,
authorization, domain validation, duplicate-ID checking, generated-card
planning, and media-reservation checking, then returns the ordered results and
aggregate impact without committing or consuming reservations.

Each operation has a client-local `operationId`. Errors identify the operation
ID and JSON pointer. A committed request emits one change transaction whose
member events preserve request order where no domain dependency requires a
different order.

**Acceptance criteria**

- **BATCH-001:** A 500-item valid batch commits all items, generated cards, and
  media reference changes in one transaction.
- **BATCH-002:** A 501-item request returns HTTP 413 or 422 before domain
  mutation.
- **BATCH-003:** One invalid operation among 500 causes zero persisted changes,
  zero consumed reservations, zero events, and an error pointing to its
  `operationId`.
- **BATCH-004:** Dry-run and commit return identical planned item/card IDs when
  the client supplies IDs and no dependent revision changes between requests.
- **BATCH-005:** Replaying a committed batch returns the original logical
  results and does not regenerate cards or increment revisions.

## 15. Import and export operations

Imports and exports are asynchronous job resources. Jobs have `pending`,
`uploading`, `validating`, `ready`, `committing`, `completed`, `failed`, or
`cancelled` state. A state transition is monotonic except that a failed
validation MAY return to `uploading` after replacement of an invalid file.

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `POST` | `/v1/imports` | `library.import` | Create an import manifest |
| `PUT` | `/v1/imports/{id}/files/{fileId}` | `library.import` | Upload one declared file |
| `POST` | `/v1/imports/{id}/validations` | `library.import` | Validate and plan |
| `POST` | `/v1/imports/{id}/commits` | `library.import` | Commit the unchanged plan |
| `GET` | `/v1/imports/{id}` | `library.import` | Inspect status and report |
| `DELETE` | `/v1/imports/{id}` | `library.import` | Cancel and remove staging |
| `POST` | `/v1/exports` | `library.export` | Start a portable export |
| `GET` | `/v1/exports/{id}` | `library.export` | Inspect export status |
| `GET` | `/v1/exports/{id}/content` | `library.export` | Download completed output |
| `DELETE` | `/v1/exports/{id}` | `library.export` | Remove staged output |

Supported import formats are `json`, `csv`, `authoredDeck`, and `portableDeck`.
An authored-deck manifest declares every relative bundle file and its expected
byte size and SHA-256. The server allocates opaque file IDs; upload routes never
contain caller-supplied paths. The authored-deck rules and portable-deck rules
remain normative for their respective content. A staged import may declare up
to 4,000,000,000 bytes across its files.

Validation is complete and non-mutating. It returns exact planned counts,
warnings, conflicts, and a plan token bound to uploaded digests and destination
revisions. Commit requires that token and an idempotency key. All destination
database and media-reference changes commit atomically. Upload and output
staging is private, bounded, and removed after cancellation or expiry.

Version 1 exports only `portableDeck`. It MUST NOT claim to reconstruct authored
source. Export reads a transactionally consistent snapshot.

**Acceptance criteria**

- **TRANSFER-001:** Valid fixtures for all four import formats produce the same
  plan and committed domain state as the corresponding native import path.
- **TRANSFER-002:** Validation of every malformed, over-limit, traversal,
  symlink-equivalent, digest-mismatch, and schema-conflict fixture produces no
  library mutation or durable media adoption.
- **TRANSFER-003:** Replacing any uploaded byte invalidates the prior plan token;
  changing any destination dependency does the same.
- **TRANSFER-004:** Fault injection at every staged-media, database, and final
  file-promotion boundary leaves either the complete prior state or the complete
  new state, never a partial import or export.
- **TRANSFER-005:** Cancelling or expiring a job removes its private staged
  bytes and makes every subsequent job-content route return 404 or 410.
- **TRANSFER-006:** A completed portable export passes the portable format's
  integrity, foreign-key, digest, media, limit, and round-trip acceptance suite.

## 16. Changes and event delivery

Every resource event committed by a successful mutating transaction receives a
unique, monotonically increasing `changeCursor`. A transaction that changes
multiple resources therefore owns a contiguous cursor range. Its events share
one `transactionId` and use a zero-based `sequence`. Events are published only
after commit and never for rolled-back work. A mutation response reports the
last cursor assigned to its transaction.

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/changes?after={cursor}` | `library.read` | Page durable changes |
| `GET` | `/v1/events` | `library.read` | Stream changes using SSE |

Each event contains `cursor`, `transactionId`, `sequence`, `type`,
`resourceType`, `resourceId`, resulting revision or tombstone, and `occurredAt`.
It does not contain full field values, answer content, media bytes, tokens, or
absolute paths. Clients fetch current representations after receiving events.

The server retains an event until it is both older than 30 days and outside the
newest 100,000 events. `GET /v1/changes` returns at most 1,000 events and a next
cursor. A cursor older than retained history returns HTTP 410 with
`cursor_expired` and the current cursor, requiring a full resource refresh.

The SSE stream sends the same event schema and a heartbeat comment at least
every 30 seconds. It accepts a durable cursor through `Last-Event-ID`; tokens in
the stream URL are forbidden. Revocation and server shutdown close streams.

**Acceptance criteria**

- **EVENT-001:** Every successful create, update, delete, review, revert,
  import, bulk, and reset fixture produces its documented event set with one
  transaction ID per mutation and unique, contiguous, strictly increasing
  cursor values.
- **EVENT-002:** Validation failures, dry runs, impact plans, review previews,
  failed commits, and rolled-back transactions produce no event.
- **EVENT-003:** Disconnecting after any event, reconnecting with its cursor,
  and draining changes yields every later event exactly once in the returned
  sequence.
- **EVENT-004:** SSE and paged change recovery produce identical event objects
  for the same cursor range.
- **EVENT-005:** An expired cursor returns HTTP 410 and never silently starts at
  the oldest retained or current event.
- **EVENT-006:** Event serialization and application logs contain no item field
  content, resolved answer, token, or media bytes.

## 17. Deferred operations

The following are intentionally deferred and do not gate version 1:

- **POST-001:** aggregate review, retention, workload, and forecast statistics;
- **POST-002:** safe settings reads and updates, including study-day rollover;
- **POST-003:** UI navigation such as showing an item or starting study;
- **POST-004:** historical review import with separate elevated authorization;
- **POST-005:** optional HTTP byte-range media delivery;
- **POST-006:** remote transport, mobile discovery, or cloud synchronization;
- **POST-007:** backups and explicit restore; and
- **POST-008:** an optional AnkiConnect adapter that remains outside the core
  version-1 contract.

Adding one of these capabilities requires its own normative operations,
permission analysis, resource limits, failure semantics, and acceptance tests.

## 18. Version-1 release gate

A version-1 implementation is ready to ship only when all of the following are
true:

- **V1-001:** Every required criterion in this document has an automated test
  and passes in a clean build.
- **V1-002:** OpenAPI request and response conformance tests cover every success
  status, every documented error status, authentication, scope denial,
  pagination, concurrency, and idempotent replay.
- **V1-003:** Fault-injection tests cover every multi-resource database/media
  transaction and prove rollback at each injected failure point.
- **V1-004:** A security suite covers loopback binding, Host validation, CORS,
  pairing approval, token entropy, token redaction, scope isolation, revocation,
  payload limits, path traversal, and hostile media.
- **V1-005:** A concurrency suite covers stale revisions, duplicate creates,
  simultaneous study reservations, repeated reviews, event ordering, and client
  revocation during an active stream.
- **V1-006:** Restart tests prove idempotency records, committed reviews, media
  adoption, imports, exports, and durable change cursors survive process
  termination at every documented commit boundary.
- **V1-007:** On the reference CI Mac with a 100,000-item fixture, the 95th
  percentile latency is at most 100 ms for `/health` and `/v1/meta`, 500 ms for
  a 200-item collection page, and 500 ms for review submission over 100 warm
  sequential requests. Import and export job duration is excluded.
- **V1-008:** Disabling the API, revoking all clients, and uninstalling NeoAnki
  leave no listener, bearer token at rest, usable token verifier, staged upload,
  staged export, or world-readable discovery artifact.
- **V1-009:** User documentation identifies how to enable the API, approve and
  revoke clients, inspect scopes, change the port, diagnose connection errors,
  and report a security issue without disclosing a token.
- **V1-010:** The shipped app and documentation describe the API as local
  automation, not synchronization, Anki compatibility, or remote access.
- **V1-011:** A clean first launch has no API listener until the user explicitly
  enables it; enabling and disabling it take effect without changing library
  content.
- **V1-012:** If another process owns the configured port, NeoAnki reports that
  exact conflict locally, creates no listener on another port, and does not
  disclose or mutate library data.

Passing only unit tests, returning syntactically valid JSON, or exposing the
underlying `ItemStore` methods does not satisfy this release gate.

Reproducible commands and criterion-to-suite traceability are maintained in
[Local API acceptance evidence]({{ '/reference/local-api-acceptance/' | relative_url }}). That record
is evidence only; it does not amend the normative requirements above.
