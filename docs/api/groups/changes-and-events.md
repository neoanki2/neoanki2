---
title: Changes and events
description: Generated NeoAnki local API operations for changes and events.
audience: api
contract_digest: sha256:d1af897ec9d7e74241218073d7da8ff3b6a56cf62f9130a315e54338cb4c588b
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

Contract digest: `sha256:d1af897ec9d7e74241218073d7da8ff3b6a56cf62f9130a315e54338cb4c588b`.

_Generated from the runtime endpoint registry; do not edit by hand._
