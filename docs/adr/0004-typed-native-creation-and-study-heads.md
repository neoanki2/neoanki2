---
title: "ADR 0004: Typed native deck creation and bounded study heads"
description: Reuse authored semantic compilation without native file round trips and bound ordinary first-card reads.
audience: developer
---

# ADR 0004: Typed native deck creation and bounded study heads

- Status: Accepted
- Date: 2026-11-16

## Decision

Native poem/prose creation uses a typed text-deck draft and an opaque validated
Core package. The existing authored compiler owns schema/content semantics;
a shared writer enforces encoded source/line/part budgets and implements legacy
bundle export. Normal native creation neither writes a generated package nor
parses JSON. Public bundle/workspace/view/registry entry points remain adapters.

The importer allocates new durable identities for each intentional creation,
reuses equivalent schemas with ordinal field remapping, and commits parent
placement, ownership, cards, journal and result receipt in one transaction.
Missing parents and changed reused definitions fail atomically. Same-operation
retries recover the original receipt; postcommit refresh/publication failures
remain warnings. Existing editor reconciliation and Studio authorizations stay
separate and unchanged. No database or interchange schema changes are required.

Unlimited new-card queue selection uses the existing active-new/due index for
the global scope. Scoped reads retain planner choice to avoid a global-index
scan for sparse decks. Limited paths keep their existing eligibility CTEs.
A covering work-index check can prove globally absent works cheaply; if any work
exists, the old scoped/due preflight and work ordering remain. All decisions and
selection execute in one consistent read snapshot after relation maintenance.

## Alternatives and consequences

Sharing only generator wire structs would retain native filesystem lifetime and
reparsing. A new universal transfer framework would conflate authored, portable
and generated semantics. Typed preparation into the existing compiler removes
the accidental native file boundary while preserving external validation.

Forcing a work-first join everywhere can regress dense future/suspended works.
Forcing a global new index for sparse deck scopes can also regress reads. The
selected dispatch therefore optimizes the measured global ordinary path and
keeps selective fallbacks. It does not alter first-card versus gradeable-session
readiness, or eliminate full-queue hydration and post-edit relation rebuilding.

## Verification and delivery

Differential imports, atomic rollback, lost-response receipt recovery, encoded
limits, registry compatibility, query plans and held-snapshot writes have focused
contracts. The implementation evidence records baseline/candidate measurements;
the normal headless/architecture/API/docs and platform build checks remain gates.
Release comes only from merged main through the unified release controller.
