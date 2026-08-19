---
title: Responses and media
description: Generated NeoAnki local API operations for responses and media.
audience: api
contract_digest: sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674
parent: Local API reference
permalink: /api/responses-and-media/
---

# Responses and media

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `POST /v1/media`

Upload media through the loopback-only NeoAnki API.

- **Operation ID:** `uploadMedia`
- **Authorization:** Bearer token with `media.write`
- **Success:** `201` with [MediaReservation]({{ '/api/schemas/#schema-mediareservation' | relative_url }})
- **Request body:** [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `NeoAnki-Media-Kind` — header; required. Declared kind of the uploaded media.
- `NeoAnki-Alt-Text` — header; optional. Accessible description stored with the media.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/media' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/media/{sha256}`

Download media through the loopback-only NeoAnki API.

- **Operation ID:** `downloadMedia`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `sha256` — path; required. Lowercase SHA-256 content digest.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/media/{sha256}' \
  --header 'Authorization: Bearer <token>'
```
## `HEAD /v1/media/{sha256}`

Head media through the loopback-only NeoAnki API.

- **Operation ID:** `headMedia`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with no response body
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `sha256` — path; required. Lowercase SHA-256 content digest.

### Example request

```bash
curl --request HEAD \
  'http://127.0.0.1:8766/v1/media/{sha256}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/media/{sha256}/metadata`

Media metadata through the loopback-only NeoAnki API.

- **Operation ID:** `mediaMetadata`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [MediaMetadata]({{ '/api/schemas/#schema-mediametadata' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `sha256` — path; required. Lowercase SHA-256 content digest.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/media/{sha256}/metadata' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/study-responses`

List study responses through the loopback-only NeoAnki API.

- **Operation ID:** `listStudyResponses`
- **Authorization:** Bearer token with `study.responses.read`
- **Success:** `200` with [StudyResponseCollection]({{ '/api/schemas/#schema-studyresponsecollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `cursor` — query; optional. Opaque cursor returned by the preceding page.
- `limit` — query; optional. Maximum number of results to return.
- `cardId` — query; optional. The cardId query parameter.
- `itemId` — query; optional. The itemId query parameter.
- `tag` — query; optional. The tag query parameter.
- `createdAfter` — query; optional. The createdAfter query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/study-responses' \
  --header 'Authorization: Bearer <token>'
```
## `DELETE /v1/study-responses/{id}`

Delete study response through the loopback-only NeoAnki API.

- **Operation ID:** `deleteStudyResponse`
- **Authorization:** Bearer token with `study.responses.delete`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request DELETE \
  'http://127.0.0.1:8766/v1/study-responses/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/study-responses/{id}`

Get study response through the loopback-only NeoAnki API.

- **Operation ID:** `getStudyResponse`
- **Authorization:** Bearer token with `study.responses.read`
- **Success:** `200` with [StudyResponse]({{ '/api/schemas/#schema-studyresponse' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/study-responses/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/study-responses/{id}/content`

Download study response through the loopback-only NeoAnki API.

- **Operation ID:** `downloadStudyResponse`
- **Authorization:** Bearer token with `study.responses.read`
- **Success:** `200` with [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/study-responses/{id}/content' \
  --header 'Authorization: Bearer <token>'
```
## `HEAD /v1/study-responses/{id}/content`

Head study response through the loopback-only NeoAnki API.

- **Operation ID:** `headStudyResponse`
- **Authorization:** Bearer token with `study.responses.read`
- **Success:** `200` with no response body
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request HEAD \
  'http://127.0.0.1:8766/v1/study-responses/{id}/content' \
  --header 'Authorization: Bearer <token>'
```

Contract digest: `sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674`.

_Generated from the runtime endpoint registry; do not edit by hand._
