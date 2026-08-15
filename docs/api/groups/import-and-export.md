---
title: Import and export
description: Generated NeoAnki local API operations for import and export.
audience: api
contract_digest: sha256:d1af897ec9d7e74241218073d7da8ff3b6a56cf62f9130a315e54338cb4c588b
parent: Local API reference
permalink: /api/import-and-export/
---

# Import and export

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `POST /v1/exports`

Create export through the loopback-only NeoAnki API.

- **Operation ID:** `createExport`
- **Authorization:** Bearer token with `library.export`
- **Success:** `201` with [ExportJob]({{ '/api/schemas/#schema-exportjob' | relative_url }})
- **Request body:** [CreateExportInput]({{ '/api/schemas/#schema-createexportinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/exports' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/exports/{id}`

Delete export through the loopback-only NeoAnki API.

- **Operation ID:** `deleteExport`
- **Authorization:** Bearer token with `library.export`
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
  'http://127.0.0.1:8766/v1/exports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/exports/{id}`

Get export through the loopback-only NeoAnki API.

- **Operation ID:** `getExport`
- **Authorization:** Bearer token with `library.export`
- **Success:** `200` with [ExportJob]({{ '/api/schemas/#schema-exportjob' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/exports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/exports/{id}/content`

Export content through the loopback-only NeoAnki API.

- **Operation ID:** `exportContent`
- **Authorization:** Bearer token with `library.export`
- **Success:** `200` with [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/exports/{id}/content' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/imports`

Create import through the loopback-only NeoAnki API.

- **Operation ID:** `createImport`
- **Authorization:** Bearer token with `library.import`
- **Success:** `201` with [ImportJob]({{ '/api/schemas/#schema-importjob' | relative_url }})
- **Request body:** [CreateImportInput]({{ '/api/schemas/#schema-createimportinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/imports' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/imports/{id}`

Delete import through the loopback-only NeoAnki API.

- **Operation ID:** `deleteImport`
- **Authorization:** Bearer token with `library.import`
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
  'http://127.0.0.1:8766/v1/imports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/imports/{id}`

Get import through the loopback-only NeoAnki API.

- **Operation ID:** `getImport`
- **Authorization:** Bearer token with `library.import`
- **Success:** `200` with [ImportJob]({{ '/api/schemas/#schema-importjob' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/imports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/imports/{id}/commits`

Commit import through the loopback-only NeoAnki API.

- **Operation ID:** `commitImport`
- **Authorization:** Bearer token with `library.import`
- **Success:** `200` with [ImportJob]({{ '/api/schemas/#schema-importjob' | relative_url }})
- **Request body:** [CommitImportInput]({{ '/api/schemas/#schema-commitimportinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/imports/{id}/commits' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `PUT /v1/imports/{id}/files/{fileId}`

Upload import file through the loopback-only NeoAnki API.

- **Operation ID:** `uploadImportFile`
- **Authorization:** Bearer token with `library.import`
- **Success:** `204` with no response body
- **Request body:** [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `fileId` — path; required. Staged file identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request PUT \
  'http://127.0.0.1:8766/v1/imports/{id}/files/{fileId}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/imports/{id}/validations`

Validate import through the loopback-only NeoAnki API.

- **Operation ID:** `validateImport`
- **Authorization:** Bearer token with `library.import`
- **Success:** `200` with [ImportJob]({{ '/api/schemas/#schema-importjob' | relative_url }})
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/imports/{id}/validations' \
  --header 'Authorization: Bearer <token>'
```

Contract digest: `sha256:d1af897ec9d7e74241218073d7da8ff3b6a56cf62f9130a315e54338cb4c588b`.

_Generated from the runtime endpoint registry; do not edit by hand._
