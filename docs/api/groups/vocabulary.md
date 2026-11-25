---
title: Vocabulary
description: Generated NeoAnki local API operations for vocabulary.
audience: api
contract_digest: sha256:1be510cbd46743c222b83c8249fe93e1acd3965702b2d3bb880ca1dd755f6fb5
parent: Local API reference
permalink: /api/vocabulary/
---

# Vocabulary

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /v1/known-words`

List known words through the loopback-only NeoAnki API.

- **Operation ID:** `listKnownWords`
- **Authorization:** Bearer token with `known-words.read`
- **Success:** `200` with [KnownWordCollection]({{ '/api/schemas/#schema-knownwordcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `language` — query; optional. The language query parameter.
- `limit` — query; optional. Maximum number of results to return.
- `cursor` — query; optional. Opaque cursor returned by the preceding page.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/known-words' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/known-words/judgments`

Record vocabulary judgment through the loopback-only NeoAnki API.

- **Operation ID:** `recordVocabularyJudgment`
- **Authorization:** Bearer token with `known-words.write`
- **Success:** `200` with [VocabularyJudgmentChange]({{ '/api/schemas/#schema-vocabularyjudgmentchange' | relative_url }})
- **Request body:** [VocabularyJudgmentInput]({{ '/api/schemas/#schema-vocabularyjudgmentinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/known-words/judgments' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
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
## `POST /v1/vocabulary-sets`

Create vocabulary set through the loopback-only NeoAnki API.

- **Operation ID:** `createVocabularySet`
- **Authorization:** Bearer token with `items.write`
- **Success:** `201` with [VocabularySetReceipt]({{ '/api/schemas/#schema-vocabularysetreceipt' | relative_url }})
- **Request body:** [VocabularySetInput]({{ '/api/schemas/#schema-vocabularysetinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-sets' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```

Contract digest: `sha256:1be510cbd46743c222b83c8249fe93e1acd3965702b2d3bb880ca1dd755f6fb5`.

_Generated from the runtime endpoint registry; do not edit by hand._
