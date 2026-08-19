---
title: Vocabulary
description: Generated NeoAnki local API operations for vocabulary.
audience: api
contract_digest: sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674
parent: Local API reference
permalink: /api/vocabulary/
---

# Vocabulary

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `POST /v1/vocabulary-pack-imports`

Create vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `createVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `201` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** [CreateVocabularyPackImportInput]({{ '/api/schemas/#schema-createvocabularypackimportinput' | relative_url }})
- **Success headers:** `ETag`, `Location`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/vocabulary-pack-imports/{id}`

Delete vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `deleteVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
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
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-pack-imports/{id}`

Get vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `getVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/vocabulary-pack-imports/{id}/commits`

Commit vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `commitVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`, `Location`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}/commits' \
  --header 'Authorization: Bearer <token>'
```
## `PUT /v1/vocabulary-pack-imports/{id}/files/{fileId}`

Upload vocabulary pack file through the loopback-only NeoAnki API.

- **Operation ID:** `uploadVocabularyPackFile`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Success headers:** `ETag`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `fileId` — path; required. Staged file identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request PUT \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}/files/{fileId}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/vocabulary-pack-imports/{id}/validations`

Validate vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `validateVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}/validations' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs`

List vocabulary packs through the loopback-only NeoAnki API.

- **Operation ID:** `listVocabularyPacks`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [VocabularyPackCollection]({{ '/api/schemas/#schema-vocabularypackcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs' \
  --header 'Authorization: Bearer <token>'
```
## `DELETE /v1/vocabulary-packs/{id}`

Delete vocabulary pack through the loopback-only NeoAnki API.

- **Operation ID:** `deleteVocabularyPack`
- **Authorization:** Bearer token with `vocabulary.write`
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
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}`

Get vocabulary pack through the loopback-only NeoAnki API.

- **Operation ID:** `getVocabularyPack`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [VocabularyPack]({{ '/api/schemas/#schema-vocabularypack' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}/entries`

Search vocabulary entries through the loopback-only NeoAnki API.

- **Operation ID:** `searchVocabularyEntries`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [LexicalEntryCollection]({{ '/api/schemas/#schema-lexicalentrycollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `query` — query; required. Search text.
- `mode` — query; optional. The mode query parameter.
- `limit` — query; optional. Maximum number of results to return.
- `language` — query; optional. The language query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/entries' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}/entries/{entryId}`

Get vocabulary entry through the loopback-only NeoAnki API.

- **Operation ID:** `getVocabularyEntry`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [LexicalEntry]({{ '/api/schemas/#schema-lexicalentry' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `entryId` — path; required. The entryId path parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/entries/{entryId}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}/media`

Download vocabulary media through the loopback-only NeoAnki API.

- **Operation ID:** `downloadVocabularyMedia`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Request body:** None
- **Success headers:** `Accept-Ranges`, `Content-Length`, `Digest`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `path` — query; required. The path query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/media' \
  --header 'Authorization: Bearer <token>'
```
## `HEAD /v1/vocabulary-packs/{id}/media`

Head vocabulary media through the loopback-only NeoAnki API.

- **Operation ID:** `headVocabularyMedia`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with no response body
- **Request body:** None
- **Success headers:** `Accept-Ranges`, `Content-Length`, `Digest`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `path` — query; required. The path query parameter.

### Example request

```bash
curl --request HEAD \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/media' \
  --header 'Authorization: Bearer <token>'
```

Contract digest: `sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674`.

_Generated from the runtime endpoint registry; do not edit by hand._
