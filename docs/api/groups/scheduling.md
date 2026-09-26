---
title: Scheduling
description: Generated NeoAnki local API operations for scheduling.
audience: api
contract_digest: sha256:0716d15215b36d6eccf1a225b90db11eab17fa452833e32ae8e92e2d25f011fc
parent: Local API reference
permalink: /api/scheduling/
---

# Scheduling

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

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

Contract digest: `sha256:0716d15215b36d6eccf1a225b90db11eab17fa452833e32ae8e92e2d25f011fc`.

_Generated from the runtime endpoint registry; do not edit by hand._
