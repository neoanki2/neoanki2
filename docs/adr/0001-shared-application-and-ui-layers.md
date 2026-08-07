---
title: "ADR 0001: Shared application and UI layers"
description: Separate platform-neutral workflows and adaptive feature content from Apple-platform shells.
---

# ADR 0001: Shared application and UI layers

- Status: Accepted
- Date: 2026-08-07

## Context

The macOS executable combined application state, SwiftUI content, AppKit adapters,
routing, transfers, refresh scheduling, and platform services. That made apparently
portable models depend on `ItemStore` and made `ContentView` the coordinator for
unrelated workflows. An iPhone/iPad client would either duplicate those workflows
or accumulate conditional compilation throughout one monolithic UI.

## Decision

Keep `NeoAnkiCore` as one stable domain/persistence product. Add
`NeoAnkiApplication` for repository-facing workflows and `AppSession`, and
`NeoAnkiSharedUI` for adaptive feature content. Platform shells own native
navigation and adapter implementations. Repository capabilities are focused into
query, mutation, study, transfer, and change-persistence protocols; only
`SQLiteLibraryRepository` wraps `ItemStore`.

Shared UI uses semantic system colors, Dynamic Type, a 600-point reading column,
44-point interaction targets, safe-area-aware composition, and reduced-motion
behavior. Complex navigation, tables, document selection, rich text, media, and
recording remain platform-adapted.

## Rejected alternatives

- One conditionally compiled UI target: platform behavior would spread through
  feature views and make every change require testing both branches.
- Duplicate Mac and iOS features: workflow drift and duplicated validation would
  be inevitable.
- Split domain and persistence packages immediately: the churn would obscure the
  cross-platform seams before their APIs are proven.

## Consequences

The existing executable is migrated incrementally and stays green after each
feature extraction. Shared targets have explicit forbidden-import checks and both
macOS and generic iOS Simulator compile gates.
