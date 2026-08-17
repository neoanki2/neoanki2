---
title: Item types
description: Generated NeoAnki local API operations for item types.
audience: api
contract_digest: sha256:b8d1671781abe659c6515747087c057789606e89c9a5b738c3f7c2468c280ec8
parent: Local API reference
permalink: /api/item-types/
---

# Item types

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /v1/item-types`

List item types through the loopback-only NeoAnki API.

- **Operation ID:** `listItemTypes`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [ItemTypeCollection]({{ '/api/schemas/#schema-itemtypecollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `cursor` — query; optional. Opaque cursor returned by the preceding page.
- `limit` — query; optional. Maximum number of results to return.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/item-types' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/item-types`

Create item type through the loopback-only NeoAnki API.

- **Operation ID:** `createItemType`
- **Authorization:** Bearer token with `schemas.write`
- **Success:** `201` with [ItemType]({{ '/api/schemas/#schema-itemtype' | relative_url }})
- **Request body:** [ItemTypeInput]({{ '/api/schemas/#schema-itemtypeinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/item-types' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/item-types/validate`

Validate item type through the loopback-only NeoAnki API.

- **Operation ID:** `validateItemType`
- **Authorization:** Bearer token with `schemas.write`
- **Success:** `204` with no response body
- **Request body:** [ItemTypeInput]({{ '/api/schemas/#schema-itemtypeinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/item-types/validate' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/item-types/{id}`

Delete item type through the loopback-only NeoAnki API.

- **Operation ID:** `deleteItemType`
- **Authorization:** Bearer token with `schemas.write`
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
  'http://127.0.0.1:8766/v1/item-types/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/item-types/{id}`

Get item type through the loopback-only NeoAnki API.

- **Operation ID:** `getItemType`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [ItemType]({{ '/api/schemas/#schema-itemtype' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/item-types/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `PUT /v1/item-types/{id}`

Replace item type through the loopback-only NeoAnki API.

- **Operation ID:** `replaceItemType`
- **Authorization:** Bearer token with `schemas.write`
- **Success:** `200` with [ItemType]({{ '/api/schemas/#schema-itemtype' | relative_url }})
- **Request body:** [ItemTypeInput]({{ '/api/schemas/#schema-itemtypeinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.
- `NeoAnki-Impact-Token` — header; optional. Confirmation token returned after inspecting a destructive schema edit.

### Example request

```bash
curl --request PUT \
  'http://127.0.0.1:8766/v1/item-types/{id}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/item-types/{id}/duplicate`

Duplicate item type through the loopback-only NeoAnki API.

- **Operation ID:** `duplicateItemType`
- **Authorization:** Bearer token with `schemas.write`
- **Success:** `201` with [ItemType]({{ '/api/schemas/#schema-itemtype' | relative_url }})
- **Request body:** [DuplicateItemTypeInput]({{ '/api/schemas/#schema-duplicateitemtypeinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/item-types/{id}/duplicate' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```

Contract digest: `sha256:b8d1671781abe659c6515747087c057789606e89c9a5b738c3f7c2468c280ec8`.

_Generated from the runtime endpoint registry; do not edit by hand._
