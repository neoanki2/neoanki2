---
title: "ADR 0002: Offline-first CloudKit synchronization"
description: Synchronize independent SQLite replicas through CKSyncEngine without making iCloud the local authority.
audience: developer
---

# ADR 0002: Offline-first CloudKit synchronization

- Status: Accepted
- Date: 2026-08-07

## Context

Mac, iPhone, and iPad must remain usable offline and may begin with different
libraries. NeoAnki already has a validated SQLite model, append-only review data,
content-addressed media, portable identifiers, and durable local change cursors.

## Decision

Use `CKSyncEngine` against the private database in a fixed custom zone. Keep local
SQLite authoritative. Persist engine serialization, CloudKit record metadata,
outbound position, inbound staging, device identity, mutation origin, and issues
outside domain tables. Remote changes are staged, validated, and transactionally
applied through repository capabilities with outbound echo suppression.

Library receiving explicitly fetches paginated record-zone changes on every sync
cycle. `CKSyncEngine.fetchChanges` can return without querying the server when
its push/foreground hints indicate no pending zone changes. Keep an independent
zone token and commit each page's token atomically with its staged payloads;
legacy metadata starts with a full snapshot. Use the engine for explicit sends
with automatic syncing disabled, so an older automatic fetch cannot overwrite a
newer explicit delivery. Dictionary assets remain in their separate zone.

A silent `CKRecordZoneSubscription` for the library zone wakes that same
explicit reader. Both native hosts register for remote notifications and route
only that subscription's notifications to the service. Pushes received during
an active cycle coalesce into a follow-up cycle, so a notification cannot be
lost behind the synchronization guard. Foreground reads and the 10-second
recovery poll cover delayed or missing notifications. Server retry-after delays
still take precedence over a push or local-change trigger.

Committed SQLite journal changes produce buffered cursor notifications. They
debounce local uploads by 600 milliseconds on both platforms; rolled-back or
read-only work emits no notification. The service broadcasts inbound commits to
each presentation after validation and repository application. Mac counts and
already-loaded Browse rows, mobile summaries, badges, and widgets refresh from
those events. Tests verify matching review identity, card state, and counts
before the recovery poll, rather than treating a successful status as evidence
that the visible data is current.

CloudKit can invalidate a long-lived client with an internal error (including
"Client went away before operation could be validated"). The next sync cycle
must recreate the container and engine from durable metadata instead of issuing
another request through the failed client. Keep staged inbound records and
pending uploads intact; callbacks from a discarded engine must not update the
replacement session.

Immutable reviews/reverts union-merge using deterministic device/order identity.
Mutable conflicts accept the server value and preserve the other side as a
recoverable conflict copy. Media deduplicates by content hash. Initial setup makes
a verified backup and unions both libraries; it never replaces either silently.

## Rejected alternatives

- Share a SQLite file through iCloud Drive: SQLite locking and partial file
  synchronization do not provide multi-replica conflict semantics.
- Replace SQLite with SwiftData or Core Data: it would rewrite a tested persistence
  model without eliminating product-level merge and conflict decisions.
- Last-writer-wins without copies: concurrent authoring could destroy valid user
  content and delete-versus-edit intent.

## Consequences

Sync status is non-blocking. Provisioned app IDs, push, container environments,
Developer ID certificates, and profiles are release prerequisites, while unsigned
development builds use a disabled/fake transport.
