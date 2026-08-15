---
title: Items and tags
description: Generated NeoAnki local API operations for items and tags.
audience: api
contract_digest: sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098
parent: Local API reference
permalink: /api/items-and-tags/
---

# Items and tags

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /v1/items`

List items through the loopback-only NeoAnki API.

- **Operation ID:** `listItems`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [ItemCollection]({{ '/api/schemas/#schema-itemcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `cursor` — query; optional. Opaque cursor returned by the preceding page.
- `limit` — query; optional. Maximum number of results to return.
- `deckId` — query; optional. The deckId query parameter.
- `includeDescendants` — query; optional. The includeDescendants query parameter.
- `itemTypeId` — query; optional. The itemTypeId query parameter.
- `tag` — query; optional. The tag query parameter.
- `text` — query; optional. The text query parameter.
- `schedulePhase` — query; optional. The schedulePhase query parameter.
- `dueBefore` — query; optional. The dueBefore query parameter.
- `createdAfter` — query; optional. The createdAfter query parameter.
- `updatedAfter` — query; optional. The updatedAfter query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/items' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/items`

Create item through the loopback-only NeoAnki API.

- **Operation ID:** `createItem`
- **Authorization:** Bearer token with `items.write`
- **Success:** `201` with [Item]({{ '/api/schemas/#schema-item' | relative_url }})
- **Request body:** [CreateItemInput]({{ '/api/schemas/#schema-createiteminput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/items' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/items/bulk`

Bulk items through the loopback-only NeoAnki API.

- **Operation ID:** `bulkItems`
- **Authorization:** Bearer token with `items.write`
- **Success:** `200` with [BulkItemsResult]({{ '/api/schemas/#schema-bulkitemsresult' | relative_url }})
- **Request body:** [BulkItemsInput]({{ '/api/schemas/#schema-bulkitemsinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/items/bulk' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/items/validate`

Validate item through the loopback-only NeoAnki API.

- **Operation ID:** `validateItem`
- **Authorization:** Bearer token with `items.write`
- **Success:** `204` with no response body
- **Request body:** [CreateItemInput]({{ '/api/schemas/#schema-createiteminput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/items/validate' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/items/{id}`

Delete item through the loopback-only NeoAnki API.

- **Operation ID:** `deleteItem`
- **Authorization:** Bearer token with `items.write`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request DELETE \
  'http://127.0.0.1:8766/v1/items/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/items/{id}`

Get item through the loopback-only NeoAnki API.

- **Operation ID:** `getItem`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [Item]({{ '/api/schemas/#schema-item' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/items/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `PUT /v1/items/{id}`

Replace item through the loopback-only NeoAnki API.

- **Operation ID:** `replaceItem`
- **Authorization:** Bearer token with `items.write`
- **Success:** `200` with [Item]({{ '/api/schemas/#schema-item' | relative_url }})
- **Request body:** [ReplaceItemInput]({{ '/api/schemas/#schema-replaceiteminput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request PUT \
  'http://127.0.0.1:8766/v1/items/{id}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/items/{id}/duplicate-checks`

Duplicate checks through the loopback-only NeoAnki API.

- **Operation ID:** `duplicateChecks`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [DuplicateCheckResult]({{ '/api/schemas/#schema-duplicatecheckresult' | relative_url }})
- **Request body:** [EmptyObject]({{ '/api/schemas/#schema-emptyobject' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/items/{id}/duplicate-checks' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/tag-renames`

Rename tag through the loopback-only NeoAnki API.

- **Operation ID:** `renameTag`
- **Authorization:** Bearer token with `items.write`
- **Success:** `200` with [MutationCount]({{ '/api/schemas/#schema-mutationcount' | relative_url }})
- **Request body:** [RenameTagInput]({{ '/api/schemas/#schema-renametaginput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/tag-renames' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/tags`

List tags through the loopback-only NeoAnki API.

- **Operation ID:** `listTags`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [TagCollection]({{ '/api/schemas/#schema-tagcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `cursor` — query; optional. Opaque cursor returned by the preceding page.
- `limit` — query; optional. Maximum number of results to return.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/tags' \
  --header 'Authorization: Bearer <token>'
```
## `DELETE /v1/tags/{encodedTag}`

Remove tag through the loopback-only NeoAnki API.

- **Operation ID:** `removeTag`
- **Authorization:** Bearer token with `items.write`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `encodedTag` — path; required. The encodedTag path parameter.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request DELETE \
  'http://127.0.0.1:8766/v1/tags/{encodedTag}' \
  --header 'Authorization: Bearer <token>'
```

Contract digest: `sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098`.

_Generated from the runtime endpoint registry; do not edit by hand._
