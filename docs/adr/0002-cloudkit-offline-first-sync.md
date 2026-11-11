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
