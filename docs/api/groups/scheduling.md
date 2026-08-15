---
title: Scheduling
description: Generated NeoAnki local API operations for scheduling.
audience: api
contract_digest: sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098
parent: Local API reference
permalink: /api/scheduling/
---

# Scheduling

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `POST /v1/scheduling/default-restores`

Restore default scheduling through the loopback-only NeoAnki API.

- **Operation ID:** `restoreDefaultScheduling`
- **Authorization:** Bearer token with `settings.write`
- **Success:** `200` with [SchedulingHealth]({{ '/api/schemas/#schema-schedulinghealth' | relative_url }})
- **Request body:** [RequiredConfirmInput]({{ '/api/schemas/#schema-requiredconfirminput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/scheduling/default-restores' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/scheduling/health`

Scheduling health through the loopback-only NeoAnki API.

- **Operation ID:** `schedulingHealth`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [SchedulingHealth]({{ '/api/schemas/#schema-schedulinghealth' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/scheduling/health' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/scheduling/optimization-runs`

List scheduling optimization runs through the loopback-only NeoAnki API.

- **Operation ID:** `listSchedulingOptimizationRuns`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [FSRSOptimizationRunArray]({{ '/api/schemas/#schema-fsrsoptimizationrunarray' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `limit` — query; optional. Maximum number of results to return.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/scheduling/optimization-runs' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/scheduling/parameter-sets`

List scheduling parameter sets through the loopback-only NeoAnki API.

- **Operation ID:** `listSchedulingParameterSets`
- **Authorization:** Bearer token with `library.read`
- **Success:** `200` with [FSRSParameterSetArray]({{ '/api/schemas/#schema-fsrsparametersetarray' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/scheduling/parameter-sets' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/scheduling/rollbacks`

Rollback scheduling through the loopback-only NeoAnki API.

- **Operation ID:** `rollbackScheduling`
- **Authorization:** Bearer token with `settings.write`
- **Success:** `200` with [SchedulingHealth]({{ '/api/schemas/#schema-schedulinghealth' | relative_url }})
- **Request body:** [SchedulingRollbackInput]({{ '/api/schemas/#schema-schedulingrollbackinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/scheduling/rollbacks' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```

Contract digest: `sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098`.

_Generated from the runtime endpoint registry; do not edit by hand._
