---
title: Decks
description: Generated NeoAnki local API operations for decks.
audience: api
contract_digest: sha256:d1af897ec9d7e74241218073d7da8ff3b6a56cf62f9130a315e54338cb4c588b
parent: Local API reference
permalink: /api/decks/
---

# Decks

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `POST /v1/deck-deletion-plans`

Create deck deletion plan through the loopback-only NeoAnki API.

- **Operation ID:** `createDeckDeletionPlan`
- **Authorization:** Bearer token with `decks.write`
- **Success:** `201` with [DeckDeletionPlan]({{ '/api/schemas/#schema-deckdeletionplan' | relative_url }})
- **Request body:** [CreateDeckDeletionPlanInput]({{ '/api/schemas/#schema-createdeckdeletionplaninput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/deck-deletion-plans' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/deck-deletion-plans/{id}/commits`

Commit deck deletion plan through the loopback-only NeoAnki API.

- **Operation ID:** `commitDeckDeletionPlan`
- **Authorization:** Bearer token with `decks.write`
- **Success:** `200` with [DeckDeletionCommitResult]({{ '/api/schemas/#schema-deckdeletioncommitresult' | relative_url }})
- **Request body:** [ConfirmInput]({{ '/api/schemas/#schema-confirminput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/deck-deletion-plans/{id}/commits' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/deck-reset-plans`

Create deck reset plan through the loopback-only NeoAnki API.

- **Operation ID:** `createDeckResetPlan`
- **Authorization:** Bearer token with `study.review`
- **Success:** `201` with [DeckResetPlan]({{ '/api/schemas/#schema-deckresetplan' | relative_url }})
- **Request body:** [DeckIdentifierInput]({{ '/api/schemas/#schema-deckidentifierinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/deck-reset-plans' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/deck-reset-plans/{id}/commits`

Commit deck reset plan through the loopback-only NeoAnki API.

- **Operation ID:** `commitDeckResetPlan`
- **Authorization:** Bearer token with `study.review`
- **Success:** `200` with [DeckResetCommitResult]({{ '/api/schemas/#schema-deckresetcommitresult' | relative_url }})
- **Request body:** [RequiredConfirmInput]({{ '/api/schemas/#schema-requiredconfirminput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/deck-reset-plans/{id}/commits' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/decks`

List decks through the loopback-only NeoAnki API.

- **Operation ID:** `listDecks`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [DeckCollection]({{ '/api/schemas/#schema-deckcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `cursor` — query; optional. Opaque cursor returned by the preceding page.
- `limit` — query; optional. Maximum number of results to return.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/decks' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/decks`

Create deck through the loopback-only NeoAnki API.

- **Operation ID:** `createDeck`
- **Authorization:** Bearer token with `decks.write`
- **Success:** `201` with [Deck]({{ '/api/schemas/#schema-deck' | relative_url }})
- **Request body:** [CreateDeckInput]({{ '/api/schemas/#schema-createdeckinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/decks' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/decks/{id}`

Get deck through the loopback-only NeoAnki API.

- **Operation ID:** `getDeck`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [Deck]({{ '/api/schemas/#schema-deck' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/decks/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `PATCH /v1/decks/{id}`

Update deck through the loopback-only NeoAnki API.

- **Operation ID:** `updateDeck`
- **Authorization:** Bearer token with `decks.write`
- **Success:** `200` with [Deck]({{ '/api/schemas/#schema-deck' | relative_url }})
- **Request body:** [UpdateDeckInput]({{ '/api/schemas/#schema-updatedeckinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request PATCH \
  'http://127.0.0.1:8766/v1/decks/{id}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/decks/{id}/item-type-policy`

Deck item type policy through the loopback-only NeoAnki API.

- **Operation ID:** `deckItemTypePolicy`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [ItemTypePolicy]({{ '/api/schemas/#schema-itemtypepolicy' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/decks/{id}/item-type-policy' \
  --header 'Authorization: Bearer <token>'
```

Contract digest: `sha256:d1af897ec9d7e74241218073d7da8ff3b6a56cf62f9130a315e54338cb4c588b`.

_Generated from the runtime endpoint registry; do not edit by hand._
