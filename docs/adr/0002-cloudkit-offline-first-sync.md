---
title: "ADR 0002: Offline-first CloudKit synchronization"
description: Synchronize independent SQLite replicas through CKSyncEngine without making iCloud the local authority.
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
