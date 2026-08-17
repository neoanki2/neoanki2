---
title: "Proposal: persistent spoken responses"
description: Accepted design for local-only, persistent Audio Submission responses.
audience: developer
---

# Persistent spoken responses

- Status: Accepted with revisions
- Date: 2026-08-14
- Primary use case: a one-off spoken response recorded during study and retrieved by an authorized local client

## Decision

Add a separate `audioSubmission` interaction. Do not add storage or completion policies to the existing `record` interaction.

`record` remains a temporary record-and-compare exercise with answer reveal and normal FSRS grading. An Audio Submission card is prompt-only: the learner records, reviews the draft, and chooses **Save & Complete**. A successful completion persists the validated M4A and suspends the card atomically. It advances session progress but creates no `ReviewLog`, reveals no answer, and makes no FSRS mutation.

This separation prevents invalid policy combinations and, most importantly, prevents an existing temporary recording template from gaining retention through migration or editing.

## Template and format contract

`Interaction.audioSubmission` has wire value `"audioSubmission"`. Its template must have at least one prompt slot, an empty answer side, and a skill whose output is `audio`. Converting a template with answer slots requires confirmation before the editor clears them.

Authored and portable deck format version 4 introduced this interaction.
Version 5 carries it in semantic study compositions; versions 1–4 remain
importable. Exports never include learner responses or response-only media.

## Persistence contract

Schema version 23 adds `study_responses`:

| Column | Contract |
| --- | --- |
| `id` | Stable UUID primary key used for retry idempotency |
| `card_id` | Unique card foreign key with `ON DELETE CASCADE` |
| `media_hash` | One reference to a validated audio media asset |
| `kind` | Always `audio` |
| `duration_ms` | 1 through 1,800,000 milliseconds |
| `captured_at` | Time capture began |
| `submitted_at` | Time persistence completed |

The response has no review-log relationship because it is always ungraded. Insert/delete/cascade triggers maintain `media_assets.ref_count`, revision tracking, durable changes, and response-media privacy markers. Orphan collection runs after the mutating transaction commits.

Completion validates card eligibility and uniqueness, ingests an M4A using the existing reservation mechanism, inserts the response, consumes the reservation, and suspends the card in one transaction. The source draft remains available if ingest or commit fails. Recording uses mono AAC/M4A around 64 kbps, the existing 20 MB audio limit, and a 30-minute automatic stop.

## Native product behavior

macOS and iOS share the observable feature state while keeping AVFoundation record/playback controllers platform-specific.

- Idle explains that submissions are persistent, local, and excluded from Cloud sync.
- Recording shows live elapsed time and Stop.
- Ready shows duration, Play, Record Again, Delete Draft, and primary Save & Complete.
- Saving disables duplicate actions and shows progress. A retryable inline error retains the draft.
- Leaving with an unsaved draft requires discard confirmation.
- Successful save removes the temporary file best-effort and advances without grading controls.

Library includes **Saved Responses**, newest first, with source title, submission time, duration, playback, refresh/error/empty states, and confirmed deletion. Deleting a response does not unsuspend its card. Record Again replaces only the current draft.

Native controls support Dynamic Type, VoiceOver state and announcements, keyboard operation, reduced motion, and 44-point iOS targets.

## Local API and privacy

Two opt-in scopes are added; existing tokens receive neither:

- `study.responses.read`
- `study.responses.delete`

The API provides:

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/v1/study-responses` | Signed keyset pagination and `cardId`, `itemId`, `tag`, `createdAfter` filters |
| `GET` | `/v1/study-responses/{id}` | Metadata and live card/item identifiers |
| `GET`, `HEAD` | `/v1/study-responses/{id}/content` | Exact validated M4A bytes and hash metadata |
| `DELETE` | `/v1/study-responses/{id}` | Conditional, idempotent deletion |

Create and delete operations emit `studyResponse` changes and SSE events. `/changes` and `/events` filter by scope while advancing across hidden events. Generic media lookup and ordinary media events hide hashes with only response references; authorized retrieval uses the response-content endpoint.

Response rows and response-only media never enter outbound Cloud sync. Identical bytes referenced by ordinary content still sync through that ordinary reference. Synced source deletion follows the strict-cascade policy and deletes local responses without pausing sync.

Local source deletion and destructive template edits report the affected response count and require an explicit, revision-bound retry. Direct deletion and cascades emit response deletion events and release media references.

## Acceptance criteria

1. Existing Record templates, reveal/compare, grading, imports, and retention remain unchanged.
2. Audio Submission saves a ten-minute recording, enforces the 30-minute and 20 MB limits, and survives navigation and app restart after submission.
3. Abandoning a draft leaves the card due. Completion suspends only after persistence succeeds and creates no review or FSRS mutation.
4. Stable response IDs make retries idempotent and the unique card constraint permits one response per card.
5. Authorized API clients can page/filter metadata and download bytes matching `assetHash`; unauthorized and generic-media clients learn nothing about private recordings.
6. Response-only rows and bytes never enter Cloud sync, including shared-hash and remote source-deletion cases.
7. macOS/iOS builds, shared-state tests, repository/API tests, and accessibility-oriented checks pass headlessly.
