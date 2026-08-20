---
title: Discovery
description: Generated NeoAnki local API operations for discovery.
audience: api
contract_digest: sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674
parent: Local API reference
permalink: /api/discovery/
---

# Discovery

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /health`

Health through the loopback-only NeoAnki API.

- **Operation ID:** `health`
- **Authorization:** Public loopback operation
- **Success:** `200` with [Health]({{ '/api/schemas/#schema-health' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/health' \
```
## `GET /v1/meta`

Meta through the loopback-only NeoAnki API.

- **Operation ID:** `meta`
- **Authorization:** Public loopback operation
- **Success:** `200` with [Meta]({{ '/api/schemas/#schema-meta' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/meta' \
```
## `GET /v1/openapi.json`

Openapi through the loopback-only NeoAnki API.

- **Operation ID:** `openapi`
- **Authorization:** Public loopback operation
- **Success:** `200` with [OpenAPIDocument]({{ '/api/schemas/#schema-openapidocument' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`, `X-NeoAnki-Contract-Digest`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/openapi.json' \
```

Contract digest: `sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674`.

_Generated from the runtime endpoint registry; do not edit by hand._
