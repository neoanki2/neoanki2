---
title: API errors
description: Shared problem-details response format and recovery categories for the NeoAnki local API.
audience: api
contract_digest: sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098
parent: Local API reference
permalink: /api/errors/
---

# API errors

Every unsuccessful operation returns `application/problem+json` using the
[Problem schema]({{ '/api/schemas/#schema-problem' | relative_url }}).

- `400` — malformed input, unsupported query members, or validation failure.
- `401` — missing or invalid bearer token.
- `403` — loopback, origin, pairing, or scope policy rejected the request.
- `404` — no registered operation or visible resource matches the request.
- `409` — revision, idempotency, or state transition conflict.
- `412` — `If-Match` or confirmation precondition failed.
- `413` — request body exceeds its endpoint limit.
- `422` — the request is syntactically valid but cannot be applied.
- `500` — unexpected internal failure; record the returned `requestId`.

See the [API design requirements]({{ '/LOCAL_API/#64-errors' | relative_url }})
for normative security and retry semantics.

Contract digest: `sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098`.
