---
title: Local API development
description: Change the typed endpoint registry, implementation, tests, and generated API reference together.
audience: developer
parent: Developer Guide
permalink: /user/developer/api-development/
---

# Local API development

The local HTTP API is code-first. Its typed endpoint registry is the single
route inventory used for request admission, browser preflight, query/body
validation, OpenAPI generation, and the published static reference.

## Add or change an operation

1. Add or update the operation in `APIOpenAPI`, including its stable handler
   identifier, scope, request/response schemas, parameters, status, and headers.
2. Add the handler identifier to the exhaustive `APIEndpointHandler` enum.
3. Implement or update the matching service behavior and focused contract tests.
4. Regenerate the public reference:

   ```bash
   swift run neoanki-api-reference generate
   ```

5. Run the API suite and freshness check:

   ```bash
   swift test --filter NeoAnkiAPITests --parallel
   swift run neoanki-api-reference check
   ```

Do not edit files under `docs/api/` by hand. A route implemented outside the
registry is rejected before dispatch, and branch protection rejects stale
generated pages or OpenAPI JSON.

## Compatibility

Versioned routes remain under `/v1`. Preserve operation IDs and compatible
request/response shapes within that version. Use the
[API design requirements]({{ '/LOCAL_API/' | relative_url }}) for normative
security, concurrency, idempotency, and lifecycle rules; use the
[generated API reference]({{ '/api/' | relative_url }}) for current wire details.

