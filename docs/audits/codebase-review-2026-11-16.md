---
title: NeoAnki2 simplification and performance review
description: Evidence and proposed designs for shared native library workflows and bounded maturity reads.
audience: developer
---

# NeoAnki2 simplification and performance review

Review date: November 16, 2026. Baseline: `1bfe9f85baae51e3387615d71164d418545aa197` plus the captured working-tree changes, including the two untracked study files. This is an investigation report; product improvements, implementation sequencing, and release execution remain separate work.

The highest-impact simplification is to replace the parallel native library coordinators with shared command handling and shared read-model coordination. The highest-impact performance opportunity is to replace the library-wide maturity snapshot used for narrow reads and ordinary invalidations with scoped, dependency-aware maturity reads. These recommendations address different responsibilities and can be evaluated independently.

The architecture already has valuable boundaries: validated Core transactions, an application repository adapter, shared study and Studio workflows, and transport-independent sync contracts. Keep those safeguards. The remaining problem is that shared types have not consistently produced shared ownership, and a single cached aggregate still performs work proportional to the whole library after unrelated writes.

## Evidence and coverage

The source snapshot contains 877 inventoried files, including 555 source files and 152,783 source lines across application code, tools, and tests, excluding the separately classified FSRS implementation. The coverage ledger accounts for every file by path, classification, hash, subsystem, and inspection level. Every source received a structural declaration/import scan; the workflow and candidate paths below received targeted semantic inspection. This is comprehensive subsystem coverage, not a claim that every source line received an independent correctness proof.

Generated site/API output, historical benchmarks, packaged assets, test fixtures, and vendored algorithms are distinguished from maintained first-party implementation. Historical benchmark files are not used as fresh measurements. First-party converters and integration code around vocabulary sources and FSRS remain in scope.

| Subsystem | Ownership and workflow inspection | Validation and retained distinctions |
| --- | --- | --- |
| Core content, models, schema, persistence | Validation, card generation, SQLite schema/migrations, transactions, journals, identities, projections, idempotency, and repository consumers | Core and flow suites; database errors and schema boundaries stay in Core. An 8,284-line SQLite file alone does not establish a simplification opportunity. |
| Study and scheduling | Native shared coordinator, queue ordering, response evaluation, grading/undo/repair, scheduling persistence and replay, maturity, optimizer integration | Study contracts, ordering/reference comparisons, scheduling/replay tests, and fresh read/ordering measurements. HTTP reservations remain distinct from native sessions. |
| Application and native shells | Capability protocols/adapters, Mac Items/Decks/Content orchestration, mobile LibraryFeatureModel and local browse state, lifecycle/sync refresh, editor drafts | Shared feature/application and Mac model suites; native mobile controls and host-window behavior were not exercised. |
| Shared UI, text, and media | Card layouts/concealment, newly shared answer review, Studio, rich text/cloze/occlusion, transfer adapters, image preparation, recording/playback | Rendering, editing, media, image-preparation, and response tests. AppKit/UIKit editors, security scopes, pickers, and accessibility geometry require platform adapters. |
| Library, activity, and pack sync | Initial backup/merge, aliases, durable staging, cursor/acknowledgment ordering, conflicts/restoration, CloudKit adapter, immutable learning-time stream, chunked pack transfer | Existing convergence, state-machine, relocation, lost-acknowledgment, metadata, and conflict tests. No production CloudKit access or new stress campaign. |
| Builders and interchange | Poem/prose planners and reconciliation; vocabulary generation; JSON/CSV and authored/portable decoding, staging, commit, export replacement; repair/migration CLIs | Builder, import, portable, and migration suites plus fresh portable transfer measurements. Authored source and portable round trips deliberately carry different provenance/source-authoring semantics. Both formats are content-only and create new cards without learner progress. |
| Dictionary and contextual authoring | Compiler/indexed lookup, checksum/package installation, capture/manual edits, contextual drafts, speech/media preparation and transcription checkpoints | Vocabulary, capture/context/media suites. Real speech-model availability and device transcription performance remain outside measured results. |
| External interfaces | HTTP routing, typed endpoints/DTOs, auth, durable mutation replay, transfer jobs, events, CLIs, Chrome storage/capture/retry | 168 API tests, 86-operation reference check, 19 Chrome unit tests, packaged headless Chromium integration against the isolated API fixture. |
| Device services and tooling | Reminder/badge/widget publication, deep links, background refresh, learning-time aggregation, packaging/release/deployment controllers, retired wrappers, CI and documentation generators/search | Device-service contracts, supporting script checks, architecture/docs checks. No installation, publication, account operations, or host desktop interaction. |

The actual package graph is the dependency authority. For example, SharedUI depends on Features; the architecture overview diagram draws the opposite edge. The documentation's description of shared library ownership also overstates current Mac adoption. These are supporting evidence for examining consumers rather than treating architectural descriptions as established fact.

### Workflows traced across layers

| Workflow | Trace and invariant |
| --- | --- |
| Startup and refresh | Mac composition → repository bootstrap/home snapshot → Items/Decks publication; mobile lifecycle → LibraryFeatureModel bootstrap/reload → home, browse, catalog, device publication. Preserve one captured scheduling instant, recovery errors, and coherent scope/revision publication. |
| Authoring and editing | Native drafts/capture/API → repository capability → ItemStore validation/card reconciliation → SQLite and media reference transaction → journal → projection refresh/sync. Preserve field semantics/languages, surviving card history, derived-speech invalidation, and stale-edit safeguards. |
| Study | Both shells → StudyFeatureModel → progressive queue, validation, durable review receipt, next-card preparation, undo/repair. API clients instead use owned durable reservations and replay. Device publishers must not hold the grading controls. |
| Transfer and generated decks | File access or generated bundle → bounded parsing/validation and identity/schema mapping → media reservations → shared SQLite import/bulk reconciliation → cleanup and presentation. Preserve atomic writes, export-original recovery, authored/portable differences, and protection against stale generated-deck edits. |
| Synchronization | Committed journal → durable outbound assets/envelopes → transport acknowledgment → incoming staging → validated transaction → visible refresh. Initial merging adds a verified backup, identity aliases, and conflict preservation; restart/lost acknowledgments must not lose data. |
| Dictionary and context capture | Package validation/index → cancellable lookup → retained manual choices/draft → reserved verified media → item commit. Context source transcription checkpoints finalized chunks; saved responses have separate ownership/privacy and deletion impact. |
| Device summaries and activity | Study/library changes → lightweight availability/reminder/badge publication → privacy-limited widget snapshot. Learning-time events/aliases form a separate immutable stream and remain independent of card-library conflict rules. |

## Fresh measurements and profiling

All timings use the optimized `ReviewProbe` CLI against synthetic SQLite libraries on this Mac: Mac15,7, 12 CPU cores, 36 GiB RAM, macOS 27.2.1, Apple Swift 6.4.2. Expensive paths have one excluded warm-up and five repetitions; short paths have one excluded warm-up and 100 samples. Values below are medians and observed ranges, not confidence intervals. p95 is reported only for the 100-sample paths. The archive contains 1,904 timing records, including warm-ups and six exploratory one-sample feature bootstraps; those bootstraps are excluded from ranking conclusions.

“Cold” means a fresh application store/cache after bootstrap, with fixture construction and bootstrap excluded from the read timer. It does not mean a purged filesystem cache or a measured graphical launch. Bootstrap has its own timer. Tests and builds ran before measurement, and probes ran serially; host background activity was not disabled. Treat absolute times as host-specific.

Primary fixtures use 100/1,000/25,000/100,000 Basic items with the existing scaled deck hierarchies. Histories contain 1,200 or 12,000 real production review submissions, the latter across 1,000 cards. Content/timestamp construction is fixed; persistence generates UUIDs, which remain fixed across repetitions. A separate mixed fixture adds 100 rich-text/Unicode/image items and 200 cards to the 1,000-item history fixture, with 100 verified references to one deduplicated image. The performance data do not model large video payloads, million-review mature libraries, real speech models, or live network/cloud timing.

Automatic scheduling fitting was suppressed only in the disposable snapshot through a recorded, environment-controlled diagnostic guard. This isolates foreground read costs; it is not a product change or an integrated maintenance benchmark. Preliminary unisolated probes are retained under `discarded-unisolated/` and excluded. The production fast tests ran before this diagnostic guard was introduced.

### Maturity and home reads

Values are milliseconds; brackets show minimum–maximum across five measured repetitions.

| Items / reviews | Single-card maturity | Home snapshot | Single-card maturity after deck rename |
| --- | ---: | ---: | ---: |
| 100 / 1,200 | 21.4 [21.1–22.0] | 22.9 [22.7–22.9] | 21.4 [21.2–21.9] |
| 1,000 / 0 | 8.9 [8.8–9.1] | 16.8 [16.7–17.5] | 8.9 [8.9–9.0] |
| 1,000 / 12,000 | 264.2 [258.4–281.1] | 276.5 [271.3–279.1] | 261.9 [258.3–271.9] |
| 25,000 / 12,000 | 527.0 [509.0–538.9] | 980.8 [921.3–1,005.5] | 495.4 [486.5–508.2] |
| 100,000 / 12,000 | 1,309.4 [1,248.7–1,362.0] | 3,930.6 [3,707.3–4,033.9] | 1,324.4 [1,278.3–1,331.9] |

At a fixed 1,000-item size, adding 12,000 reviews increases the median cold maturity lookup from 8.9 to 264.2 ms. At stress size, a warm cached lookup takes 0.077 ms median and 0.102 ms p95; a deck-name change causes a roughly 1.3-second rebuild. The mixed fixture also reproduces the issue: 265.8 ms for one card and 283.6 ms for home.

The shared feature refresh after an independently invalidating write takes 4,837.4 [4,553.2–4,893.9] ms at stress size. This is an end-to-end model reload including home, catalog and browse reads, not an attribution of the entire time to maturity.

The focused CPU sample starts after a readiness marker, then repeatedly invalidates by deck rename and reads one maturity status. Its call trees show `ItemStore.maturitySnapshot`, `SQLiteDatabase.fetchMaturityInputs`, all-card hydration, `decodeCard`, JSON decoding, row dictionaries and review input processing. SQL plans independently show a full cards index scan, a full review-log scan, joins and a temporary ordering B-tree. This corroborates the all-library mechanism rather than inferring a bottleneck from source size.

### Competing paths

| Path | 1,000 items / 12,000 reviews | 25,000 items / 12,000 reviews | 100,000 items / 12,000 reviews |
| --- | ---: | ---: | ---: |
| Existing-library bootstrap | 319.7 ms | 1,351.8 ms | 4,514.1 ms |
| Cold browse | 2.3 ms | 88.9 ms | 450.3 ms |
| First 50 study cards | 2.3 ms | 29.5 ms | 214.7 ms |
| One item edit then first 50 study cards | 21.7 ms | 474.3 ms | 2,217.9 ms |

Bootstrap CPU sampling shows `reconcileReviewedCardScheduling()` hydrating all cards and then fetching each card and its history inside a transaction. Its purpose is substantive recovery of acknowledged stale schedules; skipping that safeguard is not an acceptable optimization. The post-edit study sample separately shows `refreshStudyRelationsIfNeeded()` hydrating all items and deleting/reinserting relation rows after a single text edit. Its family/ordered-work rules influence new-card eligibility and session ordering, making incremental invalidation a larger correctness undertaking.

Independent queue ordering for the first 100 positions remains approximately 0.38 ms across 100–100,000 cards (100 samples per size; correctness comparison occurs outside the timer). This supports the existing early-exit policy for ordinary independent cards. It says nothing about a complete long related-card or ordered-work session.

Computed visible-item arrangement costs 5.63 ms median at 25,000 items and 22.79 ms median / 23.62 ms p95 at 100,000. Recomputing this from a native view is a credible responsiveness concern, but these are model timings, not rendered-frame measurements.

### Transfers and resources

The first valid nested portable export failed to reimport with `FOREIGN KEY constraint failed`. The saved package passes SQLite integrity and foreign-key checks; the target rolls back to zero decks/items/cards. The archive retains the exact package, original error, package row-order analysis and rollback counts. That failed nested scenario was not retried unchanged and supplies no successful import timing.

A separate flat-hierarchy variant then measured content-only whole-library transfers, retaining the known nested failure rather than masking it:

| Flat transfer | 1,000 items | 25,000 items |
| --- | ---: | ---: |
| Export | 0.448 s [0.443–0.456] | 10.469 s [10.182–10.751] |
| Import | 0.981 s [0.958–0.990] | 30.032 s [29.179–31.112] |

The 25,000-item package is about 21.7 MB and contains no learner progress or media assets. These measurements justify retaining transfer performance as a candidate, with lower workflow frequency and substantial format/recovery constraints.

Fresh-process `/usr/bin/time -l` probes compare bootstrap plus one-card preparation with the same process path followed by one maturity lookup. At 100,000 items, process lifetime peak RSS was 223.9 MiB for preparation and 286.3 MiB with maturity. These are single resource samples from separate processes, not a per-flow allocation measurement or an attributable subtraction. CPU profiles, query plans and retained array/dictionary ownership explain why a streaming/scoped design could reduce resources; the proposed reduction still needs implementation validation.

## Candidate comparison

Scores use 1–5: higher impact/confidence is better; higher effort, introduced complexity, or migration risk is worse. Weighted score is `0.35 I + 0.25 C + 0.15 (6-E) + 0.10 (6-X) + 0.15 (6-R)`. Impact reflects frequency and workflow reach as well as magnitude. Confidence distinguishes measured/reproduced mechanisms from plausible opportunities. Effort estimates assume one engineer: 1 ≤ one day, 2 about 2–4 days, 3 about 1–2 weeks, 4 about 2–4 weeks, 5 longer. These are comparative estimates, not delivery commitments.

### Simplification candidates

| Candidate | I | C | E | X | R | Score | Evidence and decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| S1 Shared native library commands and read coordination | 5 | 5 | 4 | 3 | 3 | 4.05 | Selected. Mac and mobile separately coordinate item/deck commands, imports, refresh and sync. A real partial-move failure leaves mobile state stale; both platforms can mix durable command success with fallible secondary reads. |
| S2 Shared remaining import preparation/commit lifecycle | 4 | 5 | 3 | 2 | 3 | 3.95 | Both formats already share the database import plan. Remaining policy/cleanup duplication has a post-commit error divergence; the new nested round-trip failure also exposes an unnormalized deck plan. Still a smaller responsibility footprint than S1. |
| S3 Shared generated-sequence reconciliation mechanism | 3 | 4 | 3 | 3 | 3 | 3.25 | Poem/prose duplicate matching, retention, order, and previews; Core also recognizes their work ordering inside the SQLite relation projector. Opening cards, context repair, prose separators and changed-prompt retirement are real semantic differences. |
| S4 One generic synchronization subsystem | 4 | 3 | 5 | 5 | 5 | 2.55 | Existing envelope/metadata/transport reuse is substantial. Mutable conflicts, immutable activity, and immutable chunked packages have different recovery/ownership rules; a universal engine risks adding policy machinery. |
| S5 Merge native editing/rendering implementations | 3 | 4 | 4 | 4 | 4 | 2.85 | Shared drafts, Studio, layout/concealment and answer review already centralize much policy. Platform text systems and provider/file lifetimes are necessary differences. Consolidate semantic rules only when drift is demonstrated. |

Splitting SQLiteDatabase or the HTTP router into smaller files is organizational work without demonstrated elimination of independently maintained rules. It fails the eligibility criterion for the top simplification recommendation. Similarly, short retired release wrappers deliberately fail closed and do not constitute competing release engines.

### Performance candidates

The fresh measurement section supplies results for maturity, home/browse reads, visible-item computation, first-page study hydration, post-edit study projection rebuilding, queue ordering and portable transfers. Sync fan-out and optimizer redesign remain lower-confidence candidates because neither received a new end-to-end throughput profile.

| Candidate | I | C | E | X | R | Score | Evidence and decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| P1 Scoped maturity reads and dependency-aware invalidation | 5 | 5 | 3 | 3 | 3 | 4.20 | Selected. Single-card reads and deck-name changes can trigger all-card/all-history decoding and derived allocations. Fresh scaling, query plans, and CPU sampling attribute the cost. |
| P7 Batch startup recovery reads | 5 | 5 | 3 | 3 | 4 | 4.05 | Fresh bootstrap measurements and a separate CPU profile expose all-card hydration plus per-card fetch/history queries. Closest runner-up; changing recovery reads also affects durable scheduling repair. |
| P8 Incremental study-relation projection | 5 | 5 | 4 | 4 | 4 | 3.80 | A one-item edit followed by first-page study costs 2.22 s at stress size versus 0.215 s without the edit. CPU sampling shows global item hydration and relation reinsertion. Incremental family/work invalidation is more complex and can affect eligibility/order. |
| P2 Demand-driven browse loading and cached presentation queries | 4 | 4 | 4 | 3 | 3 | 3.45 | Mobile bootstrap/reload eagerly loads items; model and mobile view compute filtered/sorted arrays, while Mac already stores/debounces search results. A full paging redesign must preserve locale-aware sorting/filtering and selection semantics. |
| P3 Study queue or first-page loading redesign | 3 | 4 | 3 | 2 | 4 | 3.20 | Fresh first-50 and independent-ordering measurements; existing early-exit and progressive-loading safeguards already remove common whole-queue work. Do not infer full-session behavior from the first-100-position probe. |
| P4 Transfer pipeline streaming/batching redesign | 3 | 4 | 4 | 3 | 4 | 2.95 | Fresh whole-library export/import measurements and existing staged BLOB/atomic commit design. Less frequent than library/detail reads, with considerable recovery/format risk. |
| P5 Sync batching, asset staging and refresh fan-out | 4 | 2 | 4 | 4 | 4 | 2.70 | Credible from source fan-out, paged journal collection and existing contracts, but simulated convergence is not a throughput or real CloudKit profile. |
| P6 Replace/rework FSRS optimization | 2 | 2 | 5 | 4 | 5 | 1.70 | Background maintenance, eligibility/cadence/promotion safeguards, and separate optimizer package reduce workflow frequency; no fresh optimizer profile supports displacement of the measured read problem. |

Six sensitivity profiles use the agreed weights, impact-heavy, confidence-heavy, effort-heavy, risk-heavy, and equal weights. S1 wins four profiles; S2 wins the effort-heavy and equal-weight profiles. The agreed impact-led weights favor S1’s wider responsibility reduction. P1 wins all six profiles, including against P7 and P8. Choosing S1 assumes substantial subsystem simplification matters more than the shortest isolated correction. Reported scores express judgment rather than precise economic returns. The selected opportunities remain defensible because S1 has reproduced workflow divergence and P1 has a bounded-call/unbounded-work mismatch. Small browse memoization may be cheaper, but addresses less of the demonstrated library-wide cost.

## Simplification recommendation

### Replace parallel native library coordination with shared ownership

`ItemsModel` (703 lines), `DecksModel` (426), and `ContentView` (1,164) still coordinate substantial Mac library behavior alongside `LibraryFeatureModel` (625). These are responsibility surfaces, not a promised count of removable lines. Mac's custom table sorting, window/menu routing, keyboard behavior and file panels remain useful platform responsibilities.

Evidence is concentrated in `LibraryFeatureModel.swift:112–186,308–440,528–566`, `ItemsModel.swift:66–118,329–425,552–573,650–703`, `ImportModel.swift:250–312`, and Mac composition's sync callback at `NeoAnki2App.swift:333–343`.

- Mac caches and cancels browse filtering; mobile has computed arrangement in the feature model and another local item array/query in LibraryView, with reloads observing `model.items`.
- Mac create/update also perform fallible summary reads after persistence inside their Boolean-result error handling. Mobile commands await `didMutate()` after persistence. A refresh failure can therefore escape as a command failure after a durable create/update. This is a source-verified control-flow problem; a post-commit refresh-failure injection was not performed.
- Mac moves report the committed partial count and reload after a later failure. Mobile's loop throws before `didMutate()`. The fault probe injected a failure on the second SQLite item move: one item durably moved, zero appeared moved in the model, and all three items remained intact. No production code was changed for this reproduction.
- Both native JSON/CSV paths import first and then attach types/move rows in separate operations. A later placement error can leave committed imported data despite an apparent failed workflow.
- The feature model and OfflineFirstSyncService both schedule 600-millisecond local synchronization, while the service already observes the committed journal. Durable mutation observation should own automatic sending.

### Proposed ownership

| Responsibility | Proposed owner |
| --- | --- |
| Native library commands and commit outcomes | Shared command service in the application/feature boundary, receiving narrow capabilities |
| Home/catalog/browse query identity, invalidation, generation checks and coalescing | Shared read-model coordinator with immutable published snapshots |
| Navigation, selection presentation, table comparators, commands and native resource acquisition | Platform shell/adapters |
| Validation, atomicity, identities, review history and media reference integrity | Existing Core/SQLite transaction boundary |
| Automatic local sending, transport lifecycle and durable recovery | Existing sync service, driven by committed journal events |

Extract these responsibilities from the existing coordinators; do not make Mac adopt the current aggregate LibraryFeatureModel wholesale. That would also import its eager reads, public aggregate repository exposure and post-commit failure semantics. Avoid a new universal framework or generic command bus.

Use an internal `CommandOutcome<Value>` separating a committed value/receipt from projection/publication warnings. Publish committed state and schedule invalidation before fallible secondary work. Retrying a read must never repeat a write. If the persistence layer cannot establish whether a write committed, retain the operation identity and reconcile its receipt rather than issuing a new create/import.

Introduce a narrow production capability for atomic selection moves; update deck assignment only, validate the complete selection and destination in one transaction, and reject a stale/missing selection without partial writes. Do not emulate this with stale full-item replacements. JSON/CSV destination placement and required type attachment should also participate in the same import transaction. Preserve existing entry points as forwarding adapters where source compatibility requires them; no HTTP route or DTO change is needed.

Shared read publication captures scope, sort/search identity, scheduling instant and revision before awaiting work, and discards stale results. Keep the Mac behavior of retaining populated rows during refresh. Preserve the existing study revision guards and nonblocking, ordered device publication.

### Behavior corrections and safeguards

| Existing divergence | Required behavior |
| --- | --- |
| Partial native selection moves with inconsistent refresh/error reporting | Both shells use the atomic selection operation. A failed selection move commits nothing; retain selection and show the error. This deliberately strengthens current partial-move behavior. |
| Durable mutation followed by thrown refresh error | Report the committed operation once, retain its result, and surface a refresh warning/retry that performs reads only. |
| Import committed before destination/type placement | Validate and commit placement with import; reject the entire operation on failure and preserve the draft/selected source. |
| Portable reservation cleanup throws after database commit, while authored/audio cleanup is best-effort | Preserve the stronger authored/audio commit semantics: retain successful receipt and log/surface recoverable cleanup debt. Never report an uncommitted import or invite duplication after commit. See Portable `ItemStore+PortableDeck.swift:413–447` versus Authored `ItemStore+AuthoredDeck.swift:184–219`. |
| Valid nested portable package read in parent-ID order | Normalize a validated import plan into parent-before-child order before committing. Reject missing parents/cycles before mutation; preserve complete rollback and external formats. UUID ordering must not determine whether a valid deck imports. |
| Multiple refresh owners and query results arriving out of order | One invalidation/publication authority, captured query identity, and stale-result rejection across both shells. |

The portable nested round-trip failure is independently reproduced: an internally valid exported package has deck children ordered ahead of their parents by `PortableDeck.swift:761`; `ItemStore+PortableDeck.swift:271–286` preserves that order, and `SQLiteDatabase.swift:2404–2409` inserts it under immediate parent foreign keys. The target remains empty after rollback. This requires a focused correctness correction in the separate implementation work, independently of whether S1 or S2 is undertaken first.

The portable cleanup discrepancy is source evidence for the shared outcome policy; consolidating both format parsers is unnecessary. Keep bounded input reads, media hash/reservation checks, archive-before-repair, optimistic Studio authorizations, ordered-deck expected snapshots, and conflict-copy recovery.

### Alternatives and acceptance

**Alternative 1:** Patch each platform's failures and copy its stronger guards to the other. This is smaller, but retains multiple authorities and recurring parity work. **Alternative 2:** Route all Mac behavior through the existing mobile aggregate. This removes visible classes but centralizes unrelated state and carries known weaknesses into Mac. **Alternative 3:** Extend persistence protocols with every UI operation. This would pull navigation/presentation concerns inward and undermine capability isolation.

Acceptance requires one owner for each shared command/invalidation policy, removal of the migrated duplicate implementations, and an explicit before/after ownership and removed-code inventory. Adding a wrapper while old callers retain their own rules does not qualify.

Run the same command contracts through both adapters. Cover successful CRUD, duplicate submission while busy, second-operation failure, destination deletion, stale selections, post-commit refresh failure, cancellation before/after commit, restart/receipt reconciliation, external sync during refresh, and scope changes with out-of-order reads. Assert atomic persistence, accurate commit outcomes, preservation of existing IDs/history/media counts, exactly-once import allocation, and reads-only refresh recovery. Retain platform table sorting, rapid-search cancellation, drafts/languages/media semantics, destructive-impact confirmation, Studio authorization and generated-deck stale-edit tests. A held badge/widget publisher must still leave grading/undo usable.

## Performance recommendation

### Replace the global maturity snapshot with scoped read models

`ItemStore.maturitySnapshot()` loads every card and active review, builds evidence/status/detail dictionaries, sorts details, and produces per-deck counts. `cardMaturityStatus(id:)`, batch statuses, item details, deck summaries, and scope summaries all enter this shared cache. Its token combines a database-local revision with SQLite `data_version`; unrelated writes invalidate the same cache.

The decisive source paths are `ItemStore.swift:320–384,387–439,981–1028`, `SQLiteDatabase.swift:3038–3055,4064–4117,7901+`, and `Models/CardMaturity.swift`. SQL plans show an all-card index scan plus a full review-log scan, joins and temporary ordering. Adding an index alone cannot make an unscoped request bounded.

Current study saving already uses the lightweight availability capability and defers device publication. This recommendation does not claim that a global maturity rebuild remains on every native grade's critical path. Its demonstrated costs affect cold detail/API reads, full home refresh, and reads after invalidation. The entire home-refresh time is not attributable to maturity: due aggregates, browse reads and other projections retain separate costs.

### Proposed design and compatibility

Keep the existing maturity rules and outward types. Introduce a Core-owned maturity reader that separates three requests: selected card IDs, one item's cards, and scope/deck aggregates. Detail reads fetch only selected card headers and their active history. Aggregate construction streams validated inputs and retains compact per-card contributions rather than full Card/ReviewLog arrays and all-item detail arrays.

Keep this index in memory initially; no library/portable/authored/vocabulary file-format migration is required. Reuse the durable change journal to identify affected cards/items and recompute only those contributions. Out-of-order sync, reverts and resets must replay the affected card's active history, not append blindly. Deck names require no review replay; hierarchy changes recompute aggregate membership from the compact contributions. Unknown changes, journal gaps/pruning, unaccounted external writes, or inconsistent revision capture invalidate conservatively and rebuild from a consistent snapshot.

Tie cached results to one read transaction/revision. Publish only if the observed dependency state still matches; never attach a newer cache token to an older computed result. Keep time-sensitive due-count caching separate from maturity, whose semantics depend on persisted evidence rather than a moving `now`.

Use one active-history predicate for scoped and aggregate reads. The existing global query considers `scheduler_card_history.history_origin` as well as the card origin; the card-specific helper currently uses only the card origin. Reusing that helper unchanged would risk semantic drift. Preserve chronological `(reviewed_at, sequence)` ordering, revert exclusion, reset origins, and existing decoding/validation safeguards. Do not make malformed evidence newly eligible by decoding a less-validated subset. The current active-history decoder silently skips failed log decodes; changing this to retain the last valid projection and surface a recoverable issue is an explicit behavior correction. Reuse existing API problem representations rather than introducing a new wire shape.

### Alternatives and acceptance

**Alternative 1:** Optimize the existing whole-library dictionaries or add SQL indexes. This may reduce constants but leaves a single-card request and ordinary invalidation proportional to the entire library. **Alternative 2:** Persist a transactional maturity projection. This could improve first-process aggregate startup further, but adds schema/backfill/rebuild and replay migration risk. Reconsider only if the scoped in-memory design cannot meet the measured targets. **Alternative 3:** Remove maturity from home or defer it behind changed UI behavior. This changes information timing and does not solve narrow API/detail reads.

Acceptance requires:

- Cold single-card work proportional to that card's history, not unrelated library size; adding unrelated cards/reviews must not cause a whole-history query. Target at least a tenfold latency reduction at the measured large/stress sizes, with a 50 ms p95 ceiling on the same benchmark host/configuration.
- A deck-name change must cause zero maturity history replays. A grade/revert invalidates only affected cards; after warm-up, unrelated history growth must not increase that invalidation's decoded-row count.
- Streaming cold aggregates reduce peak attributable allocations by at least 30%, with no median latency regression above 10%. Verify memory using separate process baselines/allocation evidence; do not subtract unrelated lifetime high-water marks from a multi-flow test.
- Exact equality with the current full evaluator across new/learning/review/suspended cards; `.again` resets, `.hard`, 7-day spacing and 30-day stability boundaries; equal timestamps with persisted sequence; reverts, resets, deletes, template reconciliation, deck moves, initial merge and out-of-order deliveries.
- Race tests cover writes during reads, cross-connection changes, journal gaps, interrupted rebuilds and malformed inputs. Preserve immutable review records, schedules, IDs, file formats and API representations.

These are proposed implementation acceptance targets, not measured improvements. No optimized alternative was implemented.

## Validation results and reproducibility

| Check | Result |
| --- | --- |
| Core Swift Testing suites | 484 reported tests passed |
| Root Swift Testing suites | 771 reported tests passed; opt-in benchmark guards were inactive |
| Root XCTest inventory checks | Four passed; one failed because the dirty working tree adds `MobileStudyModesRedesignUITests/testTypedAnswerComparisonKeepsSubmittedAnswer` without adding it to `Config/ci-ui-shards.json` |
| Full fast runner | Exit 1 at that inventory failure; not rerun unchanged |
| API reference / architecture / documentation baseline | Passed; reference contains 86 operations and documentation validation reports 53 features |
| Report documentation validation | Passed after adding the required developer-hub link |
| Chrome unit / real packaged headless integration | 19 unit tests passed; integration passed pairing, capture, lookup, lost-response replay, access revocation and offline recovery |
| Supporting tooling | All 15 separately invoked supporting commands passed; sync-sensitivity and performance-runner policy tests also passed |
| New fault and transfer diagnostics | Partial move/stale model reproduced; nested portable import failure and complete rollback preserved |
| Diagnostic benchmark builds and final measurement processes | Passed except the explicitly retained nested-transfer failure; three CLI CPU samples completed successfully |

The benchmark probes exercise real Core/application/feature implementations with synthetic data. No product optimization or new production test was implemented. The initial inventory failure concerns an uncommitted test addition; the two reproduced runtime weaknesses are in unchanged implementation paths.

The [coverage ledger]({{ '/audits/codebase-review-2026-11-16-coverage.tsv' | relative_url }}) accounts for every baseline file. The [evidence archive]({{ '/audits/codebase-review-2026-11-16-evidence.tar.gz' | relative_url }}) contains original logs, raw/summary timings, scoring/sensitivity calculations, CPU samples, SQL plans, snapshot hashes/diff, untracked baseline inputs, diagnostic sources/guard and reproduction instructions. Large synthetic databases and build products remain locally under `.build/codebase-review-2026-11-16/`; the failed nested package is included in the archive.

The artifact index records measurement boundaries and separates excluded preliminary probes from final results. Every reported timing can be traced to its fixture, flow and repetition in `measurements.ndjson`. Reproduction requires the captured dirty overlay in addition to the base commit, and only disposable fixtures should be mutated by the diagnostic commands.

## Validation limits and next decision

The report's measurements characterize headless model/storage work on this Mac. They do not establish rendered frame rates, host-window launch times, physical iPhone behavior, energy use, or CloudKit server/push performance. No GUI startup benchmark or host desktop automation was run.

The bootstrap competitor is substantial: at stress size its measured cost exceeds a single maturity rebuild. P1 is selected because its read/invalidation cost recurs across ordinary editing and summary/detail workflows, while P7 changes a recovery path that deliberately repairs acknowledged stale schedules. This frequency assessment is a workflow-based judgment; no personal usage telemetry was collected. Startup optimization must retain reverted evidence and pre-review memory needed by recovery, rather than reuse maturity’s active-only history blindly.

The separate implementation plan should preserve these ownership boundaries, choose incremental adapter migration and rollback checkpoints, and translate the acceptance cases into focused tests before changing production behavior. The failed existing UI inventory assertion must be resolved on its merits before claiming an entirely green baseline. Neither recommendation authorizes a release.
