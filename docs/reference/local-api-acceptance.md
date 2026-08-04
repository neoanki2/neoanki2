---
title: Local API acceptance evidence
description: Reproducible test commands and criterion-to-suite traceability for the version-1 local API release gate.
parent: Reference
---

# Local API acceptance evidence

This record identifies the automated evidence used to evaluate the normative
criteria in [Local API requirements](../LOCAL_API.md). It does not replace or
relax those requirements. A failed command, an untested normative change, or a
missing evidence row invalidates the corresponding result.

## Verification record

Verified on 2026-08-05 on macOS arm64 with the Swift 6 package toolchain.

| Verification command | Result |
| --- | --- |
| `swift test --filter NeoAnkiAPITests` | Pass: 35 tests |
| `swift test` | Pass: 340 tests |
| `cd NeoAnkiCore && swift test` | Pass: 358 tests |
| `NEOANKI_RUN_API_PERFORMANCE_TEST=1 swift test --filter referenceScaleAPILatencyMeetsVersionOneReleaseBudgets` | Pass: 100,000-item fixture and all four p95 budgets; 53.898 seconds including fixture creation |
| `git diff --check` | Pass |
| `swift Scripts/validate-docs.swift` | Local API validation passes; the repository-wide command remains blocked by two unrelated vocabulary feature-manifest entries |

The performance test is opt-in because it creates 100,000 items. The ordinary
suite still compiles and discovers the test, but a release run MUST set
`NEOANKI_RUN_API_PERFORMANCE_TEST=1`.

## Criterion traceability

| Criteria | Primary automated evidence |
| --- | --- |
| `GEN-001`–`GEN-003` | API item/content tests plus Core item creation, validation, card generation, media accounting, and persistence-boundary tests |
| `GEN-004`–`GEN-009` | `loopbackServerServesHTTPAndStopsCleanly`, `localAPIDefaultsOffAndReportsTheConfiguredPortConflict`, `strictHTTPParserRejectsAmbiguityAndParsesQuerySeparately`, `strictInputRejectsUnknownMembersUppercaseUUIDAndOversizedJSON`, and `openAPIDocumentDeclaresTheCompleteVersionOneRouteInventory` |
| `SEC-001`–`SEC-009` | Discovery/authentication, pairing-limit, 256-bit entropy, credential-redaction, CORS/Host, scope, revocation, and active-stream tests in `NeoAnkiAPIServiceTests` |
| `GEN-010`–`GEN-014` | Cross-adapter stale-revision race, 100-way review replay, signed collection cursor traversal, strict input, fault recovery, and problem-response assertions |
| `DECK-001`–`DECK-007` | Deck CRUD/replay tests, nested-plan impact tests, Core atomic deck deletion/reset tests, and ordered change-event assertions |
| `TYPE-001`–`TYPE-006` | Item-type validation, duplication, impact-token reconciliation, stable-card, in-use deletion, and Core schema reconciliation tests |
| `ITEM-001`–`ITEM-007` | Every-content-value round trip, invalid-item fixtures, identity-preserving update/delete tests, exact native-filter fixture, media lifecycle tests, and tag merge/removal tests |
| `TAG-001`–`TAG-002` | Core normalization-limit tests and API tag merge/removal atomicity assertions |
| `CARD-001`–`CARD-005` | Read-only route inventory, all-six-interaction content parity, suspension/preview/reset tests, and Core scheduling/history assertions |
| `STUDY-001`–`STUDY-008` | Four-scope eligibility, 100 concurrent reservations, all ratings, replay/conflict/end/revert tests, and post-commit restart recovery |
| `MEDIA-001`–`MEDIA-006` | Complete supported-signature matrix, hostile/over-limit uploads, content-addressed deduplication, independent reservations, reference counting, sandbox tests, and consistent range rejection |
| `BATCH-001`–`BATCH-005` | 500-item commit, 501-item rejection, invalid-operation rollback, dry-run identity, replay, and single-transaction event tests |
| `TRANSFER-001`–`TRANSFER-006` | Four-format validation/commit tests, staging/expiry tests, portable round trip, and import/export process-exit recovery at every declared boundary |
| `EVENT-001`–`EVENT-006` | Durable changes, mutation/no-op event sets, reconnect/expiry behavior, SSE parity, ordering, revocation, and content-redaction assertions |
| `V1-001`–`V1-006` | The API, root-package, and Core suites above, including fault, concurrency, security, restart, OpenAPI, and transaction coverage |
| `V1-007` | `referenceScaleAPILatencyMeetsVersionOneReleaseBudgets` with the required environment variable |
| `V1-008` | API lifecycle/port tests, Keychain-or-verifier credential tests, private staging permissions, cancellation/expiry cleanup, and stream shutdown tests |
| `V1-009`–`V1-012` | [Local automation API guide](../user/local-api.md), documentation assertions, clean-launch lifecycle test, and exact port-conflict test |

Criteria `POST-001` through `POST-008` are deferred and are not counted as
version-1 acceptance requirements.

## Fault boundaries exercised

The API suite injects process termination after media reservation, before
import domain commit, after import domain commit and durable commit-marker
write, after completed import-job persistence, after pending export-job
persistence, after export output generation, after completed export-job
persistence, and after review commit but before response persistence. Retries
must return the same logical resource and must not duplicate bytes, items,
review logs, events, or scheduling transitions.

## Repository-wide documentation exception

`Scripts/validate-docs.swift` currently reports only these unrelated omissions:

- `Sources/NeoAnki2/VocabularyPacksView.swift` is not mapped in
  `docs/features.json`.
- `Tests/NeoAnki2Tests/VocabularyLibraryModelTests.swift` is not mapped in
  `docs/features.json`.

Neither file is part of the local API implementation. They remain visible here
so a repository-wide release cannot mistake the local API evidence for a clean
global documentation result.
