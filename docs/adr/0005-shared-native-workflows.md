---
title: "ADR 0005: Shared native workflows and presentation boundaries"
description: Keep native session transitions and authoring workflows shared while platform views own presentation and device interaction.
audience: developer
---

# ADR 0005: Shared native workflows and presentation boundaries

- Status: Accepted
- Date: 2026-11-18

## Decision

Mac and iOS consume one application `StudySessionState` through the shared
observable `StudyFeatureModel`. Queue order, deferred repair materialization,
review/submission counters and undo changes belong to that state. The feature
model retains asynchronous reads, persistence orchestration, stale-load rejection,
interaction state and timing. Its computed action availability is shared by both
shells; platform adapters add local editor/microphone restrictions. There is no
second mutable queue or platform-specific review policy.

Repository handles remain private to feature models. `LibraryFeatureFactory`
constructs child features, resolving optional Studio capability before displaying
an editing screen. It vends feature models and named application operations,
never a repository. Mac composition supplies factories for its platform adapters;
views do not reach through an item/deck/study model to obtain library capabilities.

`ItemTypeAuthoring` owns selecting/copying/creating types and changing deck policy.
Policy changes resolve current authoring choices rather than reconstructing a
command from stale rendered rows. This does not introduce a new atomic
read/modify/write guarantee; existing repository validation remains authoritative.
Shared chooser and deck-settings models own loading, mutation exclusion, error
state and refresh callbacks. Selection remains busy until its completion callback
finishes, preventing another creation during postcommit refresh.

`GeneratedDeckEditing` shares record loading and validated ordered reconciliation
between source editors. `GeneratedDeckEditorView` also shares built-in editor
routing across study and item-detail screens on both platforms; SharedUI depends
on the two source-editor packages, which do not depend on SharedUI. Poem/prose
reconcilers retain their separate text rules
and existing error messages. `NativeDeckCreation` shares prepared creation and
legacy bundle placement. File pickers, security scopes, workspace cleanup and
platform presentation remain adapters.

The shipping iOS root injects a separate fixture service for explicit test
scenarios; fixture screens do not require a public repository on the library model.
The architecture gate rejects published library handles in shared feature models
and repository access through presentation model handles.

## Preserved behavior and limits

No database/interchange or HTTP contract changes are required. Review transactions,
durable command receipts, postcommit warnings, answer evaluation, progressive
readable-head loading, eligibility revalidation, ordered-work slots and undo
semantics retain their existing authorities. Native and HTTP session lifecycles
remain distinct. Existing public view initializers accepting capabilities remain
convenience composition adapters for callers; app screens use model injection.

This is an incremental boundary improvement. It does not isolate all persistence
from Core or move Apple generation/media providers out of the feature target.
Platform-native layout, navigation and input adaptation remain intentionally
separate. The November 17 architecture atlas is historical evidence, not a live
representation of these new boundaries.

## Verification

Application tests cover deferred repair/skip/undo, edited repair content, readable
head preservation and reset. Shared workflow tests cover inherited-policy
localization, default removal after another attachment, independent type creation,
and unsupported destinations. Existing headless study/authoring/API/flow contracts
and Mac/iOS builds remain required. No host desktop or application launch is part
of this refactoring's verification.
