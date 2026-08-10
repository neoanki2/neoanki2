---
title: "ADR 0003: Application library boundary"
description: Keep persistence actors behind capability-oriented application protocols.
---

# ADR 0003: Application library boundary

- Status: Accepted
- Date: 2026-08-10

## Context

The first native client passed `ItemStore` directly to feature models and the
loopback HTTP service. As features accumulated, that persistence actor became the
application API for items, decks, study, scheduling, media, imports, transfer
state, and synchronization. Multi-step HTTP mutations consequently coordinated
locking themselves, and a new platform client would have inherited SQLite-shaped
dependencies.

Adding a repository type without migrating its consumers did not change that
boundary: the adapter existed, but presentation and HTTP code still bypassed it.

## Decision

`NeoAnkiApplication` owns capability-oriented library protocols and the sole
SQLite adapter. Native feature models receive only the capability compositions
they use. The composition root receives the aggregate `LibraryRepository` and
passes it explicitly to workflows; models do not expose it as a service locator.

The local API depends on `LocalAPILibrary`. Persistence-backed validation copies,
portable/authored transfers, import adapters, and mutation serialization are
application operations. The HTTP target cannot construct or name `ItemStore` or
`SQLiteLibraryRepository`.

Architecture validation rejects direct persistence references in executable and
HTTP sources. `ItemStore` remains allowed only inside the SQLite application
adapters; the composition root constructs `SQLiteLibraryRepository`, and debug
scenario seeding uses an application capability.

## Rejected alternatives

- Split `ItemStore.swift` without changing consumers: smaller files would retain
  the same dependency direction and transaction leaks.
- Make `ItemStore` conform directly to application protocols: this would preserve
  the accidental ability to inject persistence into every client.
- Give every feature the aggregate repository: convenient, but it recreates a
  service locator and hides each feature's actual dependencies.
- Reimplement transfer and validation workflows in the HTTP target: that would
  duplicate Core rules and bind transport code to the SQLite implementation.

## Consequences

Persistence changes are localized to application adapters. Native UI, HTTP, and
sync code can be tested against capabilities and can move to another Apple client
without importing storage actors. Adding an operation now requires placing it in
an explicit capability and adapter rather than expanding an ambient store API.

The Core persistence implementation is still internally broad and can be split
incrementally. That cleanup no longer requires coordinated changes across UI and
HTTP clients.
