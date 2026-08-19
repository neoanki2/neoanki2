---
title: Changes and events
description: Generated NeoAnki local API operations for changes and events.
audience: api
contract_digest: sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674
parent: Local API reference
permalink: /api/changes-and-events/
---

# Changes and events

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /v1/changes`

Changes through the loopback-only NeoAnki API.

- **Operation ID:** `changes`
- **Authorization:** Bearer token with `library.read or study.responses.read`
- **Success:** `200` with [ChangeCollection]({{ '/api/schemas/#schema-changecollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `after` — query; optional. Return durable changes after this cursor.
- `limit` — query; optional. Maximum number of results to return.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/changes' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/events`

Events through the loopback-only NeoAnki API.

- **Operation ID:** `events`
- **Authorization:** Bearer token with `library.read or study.responses.read`
- **Success:** `200` with [EventStream]({{ '/api/schemas/#schema-eventstream' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `after` — query; optional. Return durable changes after this cursor.
- `Last-Event-ID` — header; optional. Last durable event cursor received by an SSE client.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/events' \
  --header 'Authorization: Bearer <token>'
```

Contract digest: `sha256:1e36292ce4418b256226feee694b72c8fc30c014e7bfdd3a1c464cfb8ce59674`.

_Generated from the runtime endpoint registry; do not edit by hand._
