---
title: "ADR 0002: Native library commands and maturity reads"
description: Share native command outcomes and demand-driven reads while keeping maturity work scoped and recoverable.
audience: developer
---

# ADR 0002: Native library commands and maturity reads

- Status: Accepted
- Date: 2026-11-16

## Context

The [codebase investigation](../audits/codebase-review-2026-11-16.md) found two independent costs: Mac and mobile adapters composed their own mutation/refresh sequences, and every cold maturity query hydrated all cards and active reviews. A successful import could be followed by failed placement or cleanup; a selected move could commit only some rows. An unrelated deck rename invalidated the full maturity snapshot.

## Decision

`NeoAnkiApplication.NativeLibraryCommands` owns selection construction, atomic move/delete/import dispatch, and the distinction between a durable command and a later refresh failure. `CommandOutcome<Value>` carries the returned value when available, a durable receipt, and recovery warnings. A receipt can recover a committed command when its post-commit read fails. Specialized Studio, capture, and generated-deck plans retain their existing validation and transactions.

Core records native receipts in the existing idempotency ledger, in the same transaction as the mutation. A dedicated native client identifier and route separate these receipts from HTTP clients. The request ID is an operation identity; the request hash prevents its reuse for different input. Recover with the same `NativeCommandContext`; a new context denotes a deliberate new operation. Ledger retention remains governed by the existing pruning policy. Portable/authored import receipts also retain their exact result identifiers and counts. No schema or interchange-format migration is required.

`NativeLibraryReadCoordinator` loads explicit home, summary, browse, and catalog demands. Snapshots carry scope, sort, time, and source journal revision. It retries reads spanning a mutation, with a bounded retry count. Native presentation adapters guard publication with generations and query identity; journal notifications cover local commands, API writes, and synchronized changes on the shared repository. The mobile home retains its authoring catalog but does not enumerate browse rows. Background refresh retains the last requested browse scope independently of navigation selection, so opening one deck does not trigger an All Decks browse scan. Mac Items and Decks share the coordinator while retaining native table comparators and navigation. `OfflineFirstSyncService` remains the owner of outbound change monitoring and debounce.

Core maturity reads now share one active-history predicate, including scheduler/card reset origins, reverts, timestamps, and append sequences. Single-card and item-detail reads hydrate only their requested cards and histories. Aggregate reads stream rows and retain compact card contributions and per-deck counts. A complete projection applies journal deltas to affected cards; deck renames replay no history. Unknown changes, a journal gap, or another connection's data-version change conservatively reset the projection. The cache remains derived, in memory, and independent of file formats.

Malformed active review evidence throws an explicit `MaturityReadError`. Existing application/HTTP failure semantics remain intact. Native readers can return scheduling/count data with an explicit maturity-unavailable issue; item detail and study remain usable. Failed evidence evaluation never silently supplies a successful empty maturity result to the external contract.

## Behavior corrections

- A selected move validates every item, its expected source assignment, and the destination in one transaction. Missing or stale members reject the entire selection. Concurrent content edits are preserved because the command updates assignments rather than replacing item snapshots.
- Native JSON/CSV import places items/cards, attaches the item type, and commits media references together. A failed attachment leaves no imported rows behind. Reservation cleanup after a committed import is best effort.
- Portable/authored imports validate the normalized deck graph and insert parents before children, preserving source sibling order. Valid nested packages no longer depend on UUID ordering.
- A refresh/publication problem after a durable save is reported separately and must not prompt a blind replay of the mutation.

## Alternatives and consequences

One observable view model for both shells would absorb Mac table comparators, file access scopes, and navigation differences. Keeping those adapters while sharing application commands/read policy removes the duplicated persistence decisions without replacing native workflows. HTTP reservation and compatibility adapters retain their own contracts.

A persistent maturity table could avoid more cold work, but would add schema evolution, repair, and synchronization responsibilities. Scoped reads plus a disposable projection achieve the measured gates without that migration. Full invalidation on every write was simpler but made unrelated edits scale with the entire library. Incremental contributions introduce cache bookkeeping, covered by rename/grade/revert, reset, journal-gap, external-origin, and malformed-history tests.

The remaining full study-relation rebuild after content edits, bootstrap recovery scans, and portable transfer throughput are separate candidates from the investigation. This change does not redesign those subsystems.

## Verification and release

See the [implementation evidence](../audits/native-library-implementation-2026-11-16.md). Use the normal headless checks, relevant iOS builds and focused Simulator XCTest, then merge to `main` before invoking the [unified release controller](../RELEASING.md). Release completion includes applicable Homebrew installation, verified iPhone installation, and release-owned artifact cleanup.
