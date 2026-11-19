---
title: "ADR 0002: Native library commands and maturity reads"
description: Share native command outcomes and demand-driven reads while keeping maturity work scoped and recoverable.
audience: developer
---

# ADR 0002: Native library commands and maturity reads

- Status: Accepted
- Date: 2026-11-16

## Context

The previous implementation had two independent costs: Mac and mobile adapters composed their own mutation/refresh sequences, and every cold maturity query hydrated all cards and active reviews. A successful import could be followed by failed placement or cleanup; a selected move could commit only some rows. An unrelated deck rename invalidated the full maturity snapshot.

## Decision

`NeoAnkiApplication.NativeLibraryCommands` owns selection construction, atomic move/delete/import dispatch, and the distinction between a durable command and a later refresh failure. `CommandOutcome<Value>` carries the returned value when available, a durable receipt, and recovery warnings. A receipt can recover a committed command when its post-commit read fails. Specialized Studio, capture, and generated-deck plans retain their existing validation and transactions.

Core records native receipts in the existing idempotency ledger, in the same transaction as the mutation. A dedicated native client identifier and route separate these receipts from HTTP clients. The request ID is an operation identity; the request hash prevents its reuse for different input. Recover with the same `NativeCommandContext`; a new context denotes a deliberate new operation. Ledger retention remains governed by the existing pruning policy. Portable/authored import receipts also retain their exact result identifiers and counts. No schema or interchange-format migration is required.

`NativeLibraryReadCoordinator` loads explicit home, summary, browse, and catalog demands. Snapshots carry scope, sort, time, and source journal revision. It retries reads spanning a mutation, with a bounded retry count. Native presentation adapters guard publication with generations and query identity; journal notifications cover local commands, API writes, and synchronized changes on the shared repository. The mobile home retains its authoring catalog but does not enumerate browse rows. Background refresh retains the last requested browse scope independently of navigation selection, so opening one deck does not trigger an All Decks browse scan. Mac Items and Decks share the coordinator while retaining native table comparators and navigation. `OfflineFirstSyncService` remains the owner of outbound change monitoring and debounce.

The mobile library model owns initial opening independently of scene task cancellation. Concurrent startup callers share that operation; a ready model does not reopen when a scene reappears. Cold iOS background refresh opens the library before reading or syncing. Only an initial local-open failure may set the blocking load error. Later refresh failures retain the current content and report a recovery message, including failures after initial sync. Canceled reads stop without publishing a snapshot, showing an error, or repeating the canceled operation; cancellation takes precedence over snapshot invalidation by a concurrent mutation.

Mobile scheduling availability has an independent `LibraryDueCountsModel` and optional `LibraryDueSnapshotReading` repository capability. A batched `LibraryDueSnapshot` contains the library total, Home deck rollups, Unassigned, and the currently open scope. It excludes content, catalogs, maturity, and unrelated schedule totals. Home rollups retain global family eligibility; Unassigned and the open scope retain their own representatives and daily-limit semantics. A slower full Home snapshot cannot replace this separate observable state.

The availability reader owns one long-lived, read-only SQLite connection, initialized after bootstrap without migrations or maintenance. Its disposable cache is validated using the connection's local revision/data-version token and current calendar/timezone. It expires at the next unsuspended-card due time or study-day rollover and rejects backward-clock reuse. Content changes may dirty the derived family/template projection; only the existing writer repairs that explicit readiness condition before a fresh count transaction. Actual database errors propagate without retries. This avoids competing read-to-write lock upgrades while editing or syncing.

Foreground entry synchronously marks due counts as checking, then validates local availability before broad refresh or network synchronization. Concurrent requests coalesce to one active read and the latest pending request; generation checks reject superseded results. Commit and inbound-sync notifications invalidate availability independently of broad reads. A foreground-only timer targets the next expiration instead of polling the full library every ten seconds. Sync status retains separate lightweight foreground polling because its service exposes no status event stream. Significant time/timezone changes revalidate immediately. Failed checks offer retry rather than zero; badge/widget publication remains outside the study/review command completion barrier. Cache expiration is distinct from the next actual study opportunity, and widgets retain scoped family eligibility. See the [mobile due-count performance evidence](../audits/mobile-due-counts-2026-11-19.md) for measurements and the bulk-new-card limitation.

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

The remaining full study-relation rebuild after content edits, bootstrap recovery scans, and portable transfer throughput are separate concerns outside this decision. This change does not redesign those subsystems.

## Verification and release

Use the normal headless checks, relevant iOS builds and focused Simulator XCTest, then merge to `main` before invoking the [unified release controller](../RELEASING.md). Release completion includes applicable Homebrew installation, verified iPhone installation, and release-owned artifact cleanup.
