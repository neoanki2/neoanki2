---
title: Cards and study
description: Generated NeoAnki local API operations for cards and study.
audience: api
contract_digest: sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098
parent: Local API reference
permalink: /api/cards-and-study/
---

# Cards and study

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /v1/cards`

List cards through the loopback-only NeoAnki API.

- **Operation ID:** `listCards`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [CardCollection]({{ '/api/schemas/#schema-cardcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `cursor` — query; optional. Opaque cursor returned by the preceding page.
- `limit` — query; optional. Maximum number of results to return.
- `itemId` — query; optional. The itemId query parameter.
- `deckId` — query; optional. The deckId query parameter.
- `includeDescendants` — query; optional. The includeDescendants query parameter.
- `templateId` — query; optional. The templateId query parameter.
- `phase` — query; optional. The phase query parameter.
- `isSuspended` — query; optional. The isSuspended query parameter.
- `dueBefore` — query; optional. The dueBefore query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/cards' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/cards/{id}`

Get card through the loopback-only NeoAnki API.

- **Operation ID:** `getCard`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [Card]({{ '/api/schemas/#schema-card' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/cards/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `PATCH /v1/cards/{id}`

Patch card through the loopback-only NeoAnki API.

- **Operation ID:** `patchCard`
- **Authorization:** Bearer token with `study.review`
- **Success:** `200` with [Card]({{ '/api/schemas/#schema-card' | relative_url }})
- **Request body:** [PatchCardInput]({{ '/api/schemas/#schema-patchcardinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request PATCH \
  'http://127.0.0.1:8766/v1/cards/{id}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/cards/{id}/content`

Card content through the loopback-only NeoAnki API.

- **Operation ID:** `cardContent`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [StudyCard]({{ '/api/schemas/#schema-studycard' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/cards/{id}/content' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/cards/{id}/resets`

Reset card through the loopback-only NeoAnki API.

- **Operation ID:** `resetCard`
- **Authorization:** Bearer token with `study.review`
- **Success:** `200` with [Card]({{ '/api/schemas/#schema-card' | relative_url }})
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
  'http://127.0.0.1:8766/v1/cards/{id}/resets' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/cards/{id}/review-preview`

Review preview through the loopback-only NeoAnki API.

- **Operation ID:** `reviewPreview`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [RatingPreviewArray]({{ '/api/schemas/#schema-ratingpreviewarray' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/cards/{id}/review-preview' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/cards/{id}/scheduling-explanation`

Scheduling explanation through the loopback-only NeoAnki API.

- **Operation ID:** `schedulingExplanation`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [SchedulingExplanation]({{ '/api/schemas/#schema-schedulingexplanation' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/cards/{id}/scheduling-explanation' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/reviews`

Submit review through the loopback-only NeoAnki API.

- **Operation ID:** `submitReview`
- **Authorization:** Bearer token with `study.review`
- **Success:** `201` with [ReviewResult]({{ '/api/schemas/#schema-reviewresult' | relative_url }})
- **Request body:** [SubmitReviewInput]({{ '/api/schemas/#schema-submitreviewinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/reviews' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/reviews/{reviewLogId}/reverts`

Revert review through the loopback-only NeoAnki API.

- **Operation ID:** `revertReview`
- **Authorization:** Bearer token with `study.review`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `reviewLogId` — path; required. Review-log identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/reviews/{reviewLogId}/reverts' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/study-sessions`

Create study session through the loopback-only NeoAnki API.

- **Operation ID:** `createStudySession`
- **Authorization:** Bearer token with `study.review`
- **Success:** `201` with [StudySession]({{ '/api/schemas/#schema-studysession' | relative_url }})
- **Request body:** [CreateStudySessionInput]({{ '/api/schemas/#schema-createstudysessioninput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/study-sessions' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/study-sessions/{id}`

End study session through the loopback-only NeoAnki API.

- **Operation ID:** `endStudySession`
- **Authorization:** Bearer token with `study.review`
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
  'http://127.0.0.1:8766/v1/study-sessions/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/study-sessions/{id}`

Get study session through the loopback-only NeoAnki API.

- **Operation ID:** `getStudySession`
- **Authorization:** Bearer token with `study.review`
- **Success:** `200` with [StudySession]({{ '/api/schemas/#schema-studysession' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/study-sessions/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/study-sessions/{id}/next`

Next study card through the loopback-only NeoAnki API.

- **Operation ID:** `nextStudyCard`
- **Authorization:** Bearer token with `study.review`
- **Success:** `200` with [StudyCard]({{ '/api/schemas/#schema-studycard' | relative_url }})
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/study-sessions/{id}/next' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/study-sessions/{id}/skips`

Skip study card through the loopback-only NeoAnki API.

- **Operation ID:** `skipStudyCard`
- **Authorization:** Bearer token with `study.review`
- **Success:** `204` with no response body
- **Request body:** [SkipStudyCardInput]({{ '/api/schemas/#schema-skipstudycardinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/study-sessions/{id}/skips' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```

Contract digest: `sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098`.

_Generated from the runtime endpoint registry; do not edit by hand._
