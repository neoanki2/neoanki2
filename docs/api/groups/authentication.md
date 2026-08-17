---
title: Authentication and clients
description: Generated NeoAnki local API operations for authentication and clients.
audience: api
contract_digest: sha256:b8d1671781abe659c6515747087c057789606e89c9a5b738c3f7c2468c280ec8
parent: Local API reference
permalink: /api/authentication/
---

# Authentication and clients

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `DELETE /v1/clients/current`

Revoke current client through the loopback-only NeoAnki API.

- **Operation ID:** `revokeCurrentClient`
- **Authorization:** Bearer token with `any`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request DELETE \
  'http://127.0.0.1:8766/v1/clients/current' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/clients/current`

Current client through the loopback-only NeoAnki API.

- **Operation ID:** `currentClient`
- **Authorization:** Bearer token with `any`
- **Success:** `200` with [Client]({{ '/api/schemas/#schema-client' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/clients/current' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/pairings`

Pair through the loopback-only NeoAnki API.

- **Operation ID:** `pair`
- **Authorization:** Public loopback operation
- **Success:** `201` with [PairingResult]({{ '/api/schemas/#schema-pairingresult' | relative_url }})
- **Request body:** [PairingInput]({{ '/api/schemas/#schema-pairinginput' | relative_url }})
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/pairings' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```

Contract digest: `sha256:b8d1671781abe659c6515747087c057789606e89c9a5b738c3f7c2468c280ec8`.

_Generated from the runtime endpoint registry; do not edit by hand._
