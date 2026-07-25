# NeoAnki2 — Audit Remediation Plan

This plan turns every non-green cell of the adversarial audit scorecard
(prompt → respond → grade against `PRODUCT.md` / `ARCHITECTURE.md`) into
**green**, defined as:

- **Impl** — the behavior described in the docs exists and is reachable.
- **Hard** — it survives malformed, hostile, and edge-case input without
  crashing, leaking, or corrupting data.
- **Test** — automated tests assert the behavior *and* the failure modes
  (not just the happy path), and run under `./Scripts/test-fast.sh`.
- **Truthful docs** — where a promise is not going to be built, the docs are
  corrected so the claim matches reality. A green cell requires code and docs
  to agree.

Baseline at time of writing: `test-fast.sh` = **166 tests green** (103 core +
63 shell). The risk is unverified behavior, not failing behavior — so almost
every item below adds tests as an explicit deliverable.

---

## 0. Product decisions to confirm before coding

Three items require a product call because "green" can be reached two ways.
Recommended defaults are marked ✅.

| # | Decision | Options | Recommendation |
| --- | --- | --- | --- |
| D1 | ReviewLog "append-only" | (a) implement soft-delete/tombstone so history is preserved ✅; (b) delete the "append-only" wording from docs | (a) — history feeds future FSRS fitting; deletion is a data-integrity liability |
| D2 | FSRS "adapts to the individual learner via parameter fitting" | (a) implement an optimizer; (b) downgrade docs to "roadmap" and ship static weights ✅ for now | (b) short-term to get green honestly, then (a) as a tracked feature. See §4. |
| D3 | Legacy `file://` media refs | (a) drop support entirely (tests migrate to hash refs) ✅; (b) keep but sandbox-restrict | (a) — the feature exists only for old test fixtures and is a live arbitrary-read hole |

Everything else is a straight bug/feature fix with one correct outcome.

---

## 1. Phased roadmap

Effort: S ≤ half day, M ≈ 1–2 days, L ≈ 3–5 days.

### Phase P0 — correctness, security, and truth (ship-blockers)

| ID | Workstream | Scorecard rows fixed | Effort |
| --- | --- | --- | --- |
| P0-1 | Cloze render-time crash guard + decode/persist validation | Cloze; Content rendering (Test) | M |
| P0-2 | Media arbitrary-read + persist-`file://` fix | MediaStore security | M |
| P0-3 | Import path traversal / absolute / symlink / nil-base fix | Import security | M |
| P0-4 | Enforce import limits before parse; stream/cap media before full read | Import; MediaStore | M |
| P0-5 | Fix magic-byte validation (video no-op, offset bugs) | MediaStore security | S |
| P0-6 | ReviewLog append-only (D1) | ReviewLog append-only | M |
| P0-7 | FSRS parameter-fitting claim (D2) | FSRS "adapts…" | S (docs) / L (optimizer) |
| P0-8 | Transaction wrapping: `updateItemType`+`syncCards`, `importItems` | SQLite integrity | M |
| P0-9 | Migration downgrade guard + read-failure hardening | SQLite migrations | S |
| P0-10 | Study `grade()` reentrancy + cloze soft-lock + undo-after-finish | Study loop; Keyboard | M |

### Phase P1 — feature depth behind "Implemented" labels

| ID | Workstream | Scorecard rows fixed | Effort |
| --- | --- | --- | --- |
| P1-1 | Full template authoring UI (interaction/skill/generateWhen/slots/reveal) | Template authoring UI | L |
| P1-2 | Cloze feature completeness (default hide, groups, arbitrary-token blanking, built-in template) | Cloze | L |
| P1-3 | `media_assets` ref-counting + orphan GC | media_assets v4 | M |
| P1-4 | FSRS same-day (w17/w18) + fuzz + numeric reference tests | FSRS scheduling | M |
| P1-5 | Built-in item-type honesty (remove or document `Basic`) | Domain-neutral core | S |

### Phase P2 — accessibility & structural test debt

| ID | Workstream | Scorecard rows fixed | Effort |
| --- | --- | --- | --- |
| P2-1 | VoiceOver labels in production; audio/cloze control traits | Accessibility | M |
| P2-2 | Keyboard: default/cancel keys, NSTextView Tab, focus order | Keyboard; Accessibility | M |
| P2-3 | Increased-Contrast + adaptive accent | Accessibility | S |
| P2-4 | Plain-language errors at all sites | Accessibility | S |
| P2-5 | Cross-cutting test additions (security, migration, a11y, races) | every "Test ❌" | L |
| P2-6 | Number/`lang` rendering polish | Content rendering | S |

---

## 2. P0 detailed specs

### P0-1 — Cloze render crash + validation boundary

**Current.** `ClozeValidation.displayText` (`ClozeValidation.swift:66-67`) calls
`String.index(_:offsetBy:)` with no `limitedBy:`; out-of-bounds/negative offsets
trap. Reachable from `ItemDisplay.plainText(.cloze)` (list browsing) and
`ClozeContentView` (study). Persistence only validates cloze on **required**
fields (`ItemStore.swift:601 where field.isRequired`); no decode-time check.

**Target.** Malformed `ClozeSpan` can never crash a render; malformed cloze can
never be persisted through any core API.

**Changes.**
1. `ClozeValidation.displayText`: make offset math total. Use
   `text.index(_, offsetBy:, limitedBy: text.endIndex)`; on `nil`, or on
   `start < 0` / `start+length > text.count`, skip that blank (defensive) rather
   than trap. Sort/clamp before replacing.
2. Add `ClozeValidation.sanitize(text:blanks:) -> [ClozeSpan]` that drops invalid
   spans, used by the render path as belt-and-suspenders.
3. `ItemStore.validate(_:against:)` (`ItemStore.swift:601`): validate cloze on
   **all** fields (remove `where field.isRequired` for the cloze branch), so
   `createItem` rejects bad optional cloze.
4. `ContentValue`/`ClozeSpan` decode: add an `init(from:)` (or a validating
   factory used at the store boundary) that rejects negative `start`/`length`.
   Keep `Codable` synthesis but funnel store reads through a validator.

**Tests (`MediaAndClozeTests` / new `ClozeValidationTests`).**
- `displayText` with `start<0`, `start>count`, `start+length>count`, negative
  `length`, emoji/combining-mark text → returns a string, never traps.
- `createItem` with an optional cloze field carrying an out-of-bounds blank →
  throws `ClozeValidationError.blankOutOfBounds`.
- `ItemDisplay.plainText` on a bad persisted cloze → no crash.

**Acceptance.** Cloze row: Hard ✅, Test ✅ (crash path). Content-rendering Test
gap closed for cloze.

---

### P0-2 — Media arbitrary file read / persisted `file://`

**Current.** `resolveLegacyURL` (`MediaStore.swift:89-95`) returns any absolute
`file://` with no containment; decoder rebuilds it from a `url` key
(`MediaRef.swift:68-71`); UI reads it (`MediaViews.swift:44,73,137`). Encode
writes the raw URL back (`MediaRef.swift:86-88`).

**Target (D3-a).** No `MediaRef` can resolve outside the sandbox; no `file://`
URL is ever persisted.

**Changes.**
1. Remove `legacyURL` from the persisted model. In `MediaRef.init(from:)`, when a
   legacy `url` is present, **do not** reconstruct a resolvable ref — either
   throw a decode error or map to an unresolvable placeholder (kept only in
   in-memory test fixtures, never persisted).
2. Delete the `url` branch in `encode(to:)`; only hash refs are written.
3. Delete `resolveLegacyURL`; `resolve` handles hash refs only.
4. Migrate the handful of test fixtures that used `MediaRef(url:)` to ingest via
   `MediaStore` and use hash refs (`MediaAndClozeTests`, any `ScenarioContext`
   helper).
5. Harden `resolve` containment: compare against `mediaDirectory.path + "/"`
   (path-boundary, not raw `hasPrefix`) and use `resolvingSymlinksInPath()`.

**Tests.**
- Decoding a payload with `{"url":"file:///etc/passwd"}` → decode error / no
  resolvable ref (regression test for the exact exploit).
- `resolve` with a crafted `assetHash` of `../../x` → `sandboxViolation`.
- Round-trip encode of a hash ref never emits a `url` key.

**Acceptance.** MediaStore-security row: Impl ✅ Hard ✅ Test ✅ for this vector.

---

### P0-3 — Import path traversal / absolute / symlink

**Current.** `resolveImportPath` (`ItemStore.swift:525-548`) accepts absolute
paths, skips containment when `baseDirectory == nil` (the default
`ImportContext`), uses string `hasPrefix` (sibling-dir leak), no symlink
resolution.

**Target.** A media path in an import file can only ever read a file **inside the
declared import bundle**.

**Changes.**
1. Require a non-nil `baseDirectory` whenever any `.mediaPath` cell is present;
   otherwise throw a clear `ImportError`.
2. Reject absolute paths outright (remove the `hasPrefix("/")` branch that builds
   an absolute `URL`).
3. Resolve with `baseDirectory.appendingPathComponent(trimmed).resolvingSymlinksInPath()`
   and compare against `base.resolvingSymlinksInPath().path + "/"` using path
   components, not string prefix.
4. Reject paths whose resolved location is a symlink escaping the base.

**Tests (`NativeImportFlowTests` / new `ImportSecurityTests`).**
- `../../etc/passwd`, absolute `/etc/passwd`, sibling `../bundle-evil/x.png`,
  and a symlink-inside-bundle → all throw, none read outside base.
- Valid relative path inside bundle → succeeds.

**Acceptance.** Import-security row (traversal): Hard ✅ Test ✅.

---

### P0-4 — Limits before parse; cap media before full read

**Current.** Only the 5 MB payload cap is pre-parse (`ItemStore.swift:419`);
row/field caps run after decode (`:421,:473`). `MediaStore.ingest(url:)` reads
the whole file (`MediaStore.swift:31`) before the size check (`:35`). Field cap
counts graphemes, not bytes.

**Target.** No unbounded read; documented limits enforced with documented units.

**Changes.**
1. Cap file size **before** reading: in `ingest(url:)`, stat the file
   (`FileManager.attributesOfItem` / `resourceValues(forKeys: [.fileSizeKey])`)
   and reject over the per-kind cap before `Data(contentsOf:)`. For very large
   caps, read with a bounded stream and abort past the limit.
2. Base64 import: check the decoded length against the media cap before/at decode
   (the base64 string length already bounds it, but assert explicitly).
3. Decide the field-length unit: either (a) change docs to "32 K characters", or
   (b) measure `value.utf8.count` in `ImportLimits.validateFieldString`
   (`ImportLimits.swift:20`). Recommend (b) to match the documented "32 KB".
4. Keep row/field caps where they are but document that the 5 MB byte cap is the
   pre-parse DoS guard; optionally add a fast pre-count of rows for CSV.

**Tests.**
- Oversized media file rejected without loading it fully (inject a sentinel /
  measure peak or use a path guard).
- Field string of 32 769 bytes rejected; 32 768 accepted (unit-correct).

**Acceptance.** Import row: Hard ✅ Test ✅; doc claim made accurate.

---

### P0-5 — Magic-byte validation

**Current.** Video accepts any file starting `[0x00,0x00,0x00]`; `ftyp` matched
at offset 0 instead of 4 (`MediaValidation.swift:78,87-91`); extension and magic
validated independently.

**Target.** Magic-byte checks actually constrain container types.

**Changes.**
1. Check ISO-BMFF `ftyp` at **offset 4** for mp4/mov/m4a; remove the
   `[0x00,0x00,0x00]` catch-all.
2. Cross-check that the validated `kind`/magic and the chosen `ext` are
   consistent (derive the stored extension from validated content, not the
   attacker filename).
3. Keep the allow-list (already correct) and keep SVG excluded.

**Tests (`MediaValidationTests`).**
- Real mp4/m4a/gif/png/jpeg headers accepted; three-NUL junk rejected as video;
  GIF-bytes-named-`.png` rejected or normalized.

**Acceptance.** Magic-check portion of MediaStore-security: Hard ✅ Test ✅.

---

### P0-6 — ReviewLog append-only (D1-a)

**Current.** `revertReview` does `DELETE FROM review_logs` (`SQLiteDatabase.swift:630-633`);
`RevertReviewFlowTests.swift:25` asserts count → 0. Deletes by `reviewed_at DESC`
(wrong-row risk); restored memory is unverified caller input.

**Target.** History is never destroyed; revert is a compensating operation.

**Changes.**
1. Schema v5: add `reverted_at REAL NULL` to `review_logs` (or a `review_events`
   append with a `kind` = review|revert). Add `Schema.migrationV5Statements`.
2. `revertReview`: instead of `DELETE`, mark the target log `reverted_at = now`
   (or append a revert event) and restore memory in the same transaction.
3. Target the log by **id** captured at grade time (thread the just-inserted log
   id back to `StudyModel.pendingGradeUndo`), not by `ORDER BY reviewed_at`.
4. `reviewLogCount(for:)` and any stats exclude reverted rows; add
   `activeReviewLogCount`.
5. Update `RevertReviewFlowTests` to assert the row still exists and is flagged,
   and that active count decremented.

**Tests.**
- After revert, raw log count unchanged, `reverted_at` set, active count −1,
  memory restored.
- Two reviews then revert deletes/flags the **correct** (latest) event by id.

**Acceptance.** ReviewLog-append-only row: Impl ✅ Hard ✅ Test ✅; docs true.

---

### P0-7 — FSRS parameter-fitting claim (D2)

The docs (`ARCHITECTURE.md:208-209`, diagram edge `:144`) assert live per-user
fitting; none exists (`FSRSScheduler.swift:40` weights immutable). Two paths to
green:

**D2-b (fast, honest — recommended first).** Edit `ARCHITECTURE.md` and
`PRODUCT.md` to state weights are the FSRS-5 defaults and per-user optimization
is **planned**, not active. Remove/relabel the `RL -.->|optimizes| SCH` edge as
dashed "future". This makes the row green by truthfulness immediately.

**D2-a (feature — schedule as its own project, tracked separately).** Implement
an optimizer:
1. New `FSRSOptimizer` in `NeoAnkiCore/SRS/`: read `ReviewLog` history
   (elapsed, rating, prior state), compute log-loss of predicted vs actual
   recall, fit the 19 weights via gradient descent / coordinate descent with
   clamping to FSRS parameter bounds.
2. Persist fitted weights per profile (new `scheduler_params` table) and load
   into `FSRSScheduler.Parameters`.
3. Gate behind a minimum review count; expose a "Optimize scheduling" action.
4. Tests against a synthetic review history with known-recoverable weights;
   assert improved log-loss vs defaults.

**Acceptance.** Green via D2-b now (docs match static weights) with D2-a tracked;
or fully green when D2-a ships and docs restore the present-tense claim.

---

### P0-8 — Transaction integrity

**Current.** `ItemStore.updateItemType` calls `database.updateItemType` then
`syncCards` (many auto-commit statements) unwrapped (`ItemStore.swift:112-122`,
`:612-659`). `importItems` loops per-row `createItem`, each its own transaction
(`:437-442`).

**Target.** Item-type edits and batch imports are all-or-nothing.

**Changes.**
1. Add a `database` API that runs a closure inside one `inTransaction` and move
   `updateItemType`+`syncCards` into it (a single `updateItemTypeAndSyncCards`
   DB method), so type write and card sync commit together.
2. Wrap the whole `importItems` row loop in one transaction (add a batch
   `createItems` DB method, or a transaction-scoped variant of `createItem`).
   On any row failure, roll back the entire import.

**Tests.**
- Force a failure mid-`syncCards` (e.g., inject a bad template) → item type
  unchanged, no partial cards.
- Force a failure on import row N → zero rows committed.

**Acceptance.** SQLite-integrity row: Impl ✅ Hard ✅ Test ✅.

---

### P0-9 — Migration safety

**Current.** `migrate()` (`SQLiteDatabase.swift:100`) `guard current < version
else return` silently runs older code on newer DBs; `schemaVersion()` maps read
failures to 0 (`:873-875`), which can re-`createStatements` and skip note→item.

**Target.** Fail loud on downgrade; never misclassify an existing DB as fresh.

**Changes.**
1. Add `if current > Schema.version { throw DatabaseError.unsupportedSchemaVersion(current) }`.
2. `schemaVersion()`: distinguish "table missing" (fresh, version 0) from
   "query error" (rethrow) — check for the `schema_version` table's existence
   explicitly rather than swallowing all `queryFailed`.
3. Surface `unsupportedSchemaVersion` through `UserFacingError` with a plain
   message ("This library was created by a newer version of NeoAnki2.").

**Tests (`MigrationTests`).**
- Fresh DB → v(current). v0→v2 backfill, v2→v3 note→item, v3→v4 media_assets,
  each asserted. DB stamped `version+1` → open throws downgrade error. Corrupt
  `schema_version` read → does not silently recreate.

**Acceptance.** SQLite-migrations row: Impl ✅ Hard ✅ Test ✅.

---

### P0-10 — Study loop robustness

**Current.** `StudyModel.grade()` (`StudyModel.swift:88-115`) has no
`guard !isGrading` entry check → double-keypress double-logs + skips next.
Cloze marked supported (`StudySupport.swift:6`) but `revealAnswer()` rejects
non-`.reveal` (`StudyModel.swift:84`) → soft-lock. Undo shortcut lives only in
`activeCardView`, gone after finish.

**Target.** No double-grade; every supported card is answerable; undo reachable.

**Changes.**
1. `grade()`: `guard !isGrading else { return }` at entry (set/reset around the
   await). Ensures keyboard + menu + button paths can't overlap.
2. Cloze: make `revealAnswer()` handle `.cloze` (flip the reveal flag so blanks
   show), or narrow `StudySupport.isSupportedInteraction` to exclude `.cloze`
   until P1-2 wires it — pick reveal support (small) so cloze works now.
3. Keep the `⌘Z` undo command available on the finished view (move the
   `.keyboardShortcut` / command to session scope, not card scope).
4. Card-deleted-mid-session: on `cardNotFound`, auto-advance instead of pinning.
5. Fix stacked `.return`+`.space` shortcuts: register reveal via the command menu
   once and a single primary key on the button; verify space works.

**Tests (`StudyModelTests`).**
- Two concurrent `grade` tasks → exactly one log, index +1.
- Cloze card can reveal → grade → advance.
- Grading last card then undo restores it.
- `cardNotFound` mid-session advances past the dead card.

**Acceptance.** Study-loop row: Hard ✅ Test ✅. Keyboard row upgraded (rest in P2-2).

---

## 3. P1 detailed specs

### P1-1 — Full template authoring UI

**Current.** `saveTemplate` always calls `makeRevealTemplate`, hardcoding
`.reveal` + single-field slots (`TemplatesModel.swift:243`,
`ItemTypeValidation.swift:123-131`). Interaction (5/6), skill, `generateWhen`,
multi-slot/literal sides, reveal modes are unauthorable, yet `TemplatesView`
displays labels for them (`TemplatesView.swift:349-364`).

**Target.** The UI can author the full `Template` model, or the docs are scoped
down. To make "template authoring UI | Implemented" green, build it.

**Changes.**
1. Extend `TemplateDraft` (`TemplatesModel.swift:73-103`) to cover
   `interaction`, `skill (input/output/operation)`, `generateWhen`, and an
   ordered list of prompt/answer `Slot`s (`SlotSource.field|.literal` +
   `Presentation` reveal/media).
2. `TemplateEditorView`: add pickers for interaction and skill enums, a
   `generateWhen` builder (`.fieldNotEmpty(fieldID)` etc.), a slot list editor
   (add/remove/reorder, field-or-literal, reveal mode), and allow media/cloze
   answer fields (remove the `TemplateEditorView.swift:33-35` restriction).
3. Replace `makeRevealTemplate` usage with a general `Template(from: draft)`
   builder; keep reveal as the default preset.
4. Auto-derive skill remains available as a default but is overridable.

**Tests (`TemplatesModelTests`).**
- Author `.type`, `.choose`, `.cloze` templates; multi-slot side with a literal;
  `generateWhen` gating; round-trip persistence; card generation reflects the
  authored interaction/skill/gate.

**Acceptance.** Template-authoring row: Impl ✅ Test ✅ (or docs scoped to
"reveal-only" for a smaller green — note in `PRODUCT.md`).

---

### P1-2 — Cloze feature completeness

**Current.** Default `Presentation(.always)` leaks answers on cloze prompts
(`Template.swift:72`); no built-in cloze template; grouping cosmetic
(`CardGenerator.swift:12-22`, `displayText` hides all); editor blanks only the
last word (`ClozeFieldEditor.swift:95-101`).

**Changes.**
1. Provide a built-in "Cloze" item type/template (or a cloze preset in P1-1) with
   the cloze slot set to `.hiddenUntilAnswer` by default.
2. Make groups functional: `displayText` reveals per-group; optionally generate
   one card per cloze group in `CardGenerator`.
3. Editor: blank the current selection (wire `NSTextView` selection range into
   `ClozeFieldEditor`, not just last word); let blanks share a group.

**Tests.** Group-scoped reveal; per-group card generation; selection blanking;
hidden-until-answer default (prompt does not contain the answer).

**Acceptance.** Cloze row → Impl ✅ Hard ✅ Test ✅.

---

### P1-3 — `media_assets` ref-counting + GC

**Current.** `media_assets` table exists (`Schema.swift`) but is never
written/read; no `ref_count` column; removed media files leak
(`MediaFieldEditor.swift:54-57`).

**Changes.**
1. Add `ref_count` (schema migration). On `ingest`, upsert the row and increment;
   on item save/delete/edit, diff media refs and increment/decrement.
2. Add `MediaStore.collectGarbage()` deleting files whose `ref_count == 0`; call
   after item delete / on maintenance.
3. Compute ref deltas centrally in `ItemStore` when persisting field values.

**Tests.** Ingest same bytes twice → one file, ref_count 2. Delete one item →
ref_count 1, file kept. Delete both → GC removes file.

**Acceptance.** media_assets row: Impl ✅ Hard ✅ Test ✅; doc claim true.

---

### P1-4 — FSRS completeness

**Current.** `w17/w18` declared but unused → same-day "Good" grows stability by
0; no fuzz; tests only directional.

**Changes.**
1. Implement the FSRS-5 short-term stability path using `w17/w18` for
   `elapsed == 0` / same-day reviews.
2. Add interval fuzz (deterministic seed for tests) to spread same-day due piles.
3. Add numeric reference tests: compare `recallStability`, `forgetStability`,
   `nextDifficulty`, and interval against values from the reference FSRS-5 impl
   for a fixed weight vector and inputs.

**Acceptance.** FSRS-scheduling row: Hard ✅ Test ✅ (rigorous, numeric).

---

### P1-5 — Built-in item-type honesty

**Current.** `Basic` is hardcoded, undeletable, self-reseeding
(`BuiltInItemTypes.swift`, `ItemStore.swift:64,99`), contradicting the
"can ship with zero built-in types" comment.

**Changes (pick one).**
- (a) Allow deleting built-in types (seed once, don't re-seed if the user removed
  it — track a "seeded" flag), keeping stable UUIDs only as a first-run default; or
- (b) Keep `Basic` but update `ItemType.swift:5` comment and `PRODUCT.md` to state
  a neutral starter type ships by default.

Also add the acceptance-test-as-code (below).

**Acceptance.** Domain-neutral row: Test ✅ once the acceptance test is encoded.

---

## 4. P2 detailed specs

### P2-1 — VoiceOver in production
- Set the rich-text `NSTextView` `accessibilityLabel` unconditionally (not behind
  `NEOANKI_TESTING`) from the field name (`RichTextFieldEditor.swift:114,205-213`).
- Add `accessibilityLabel` to the cloze remove button (`ClozeFieldEditor.swift:64-69`).
- Make audio play a real `Button` with `.isButton` trait, not a bare
  `onTapGesture` (`MediaViews.swift:29-33`).
- **Tests:** view-model/inspection tests asserting labels exist (or XCUITest in
  the UI suite, run only on request per repo policy).

### P2-2 — Keyboard completeness
- Add `.keyboardShortcut(.defaultAction)` to Save and `.cancelAction` to Cancel in
  `AddItemView` (`:62-73`).
- Remap Tab in the rich-text `NSTextView` to advance focus (avoid the trap).
- Add `@FocusState` initial focus + explicit order in `AddItemView`.

### P2-3 — Increased Contrast + accent
- Replace the hardcoded accent hex (`DesignSystem.swift:6-11`) with a semantic /
  asset-catalog color that has a high-contrast variant; consult
  `@Environment(\.colorSchemeContrast)` where custom colors are used.

### P2-4 — Plain-language errors everywhere
- Route `MediaFieldEditor.swift:140`, `ClozeFieldEditor.swift:108`,
  `NeoAnki2App.swift:45` through `UserFacingError` instead of raw
  `error.localizedDescription`.
- **Tests:** extend `UserFacingErrorTests` for the new mappings.

### P2-5 — Cross-cutting test debt (new test files)
- `ImportSecurityTests`, `MediaValidationTests`, `MigrationTests`,
  `ClozeValidationTests`, FSRS numeric tests, study race test, and an
  **acceptance test** encoding domain-neutrality: build a wholly novel schema
  (e.g. `spatial`/`sequence`/`arrange`/`reproduce`), create items, generate
  cards, study, delete the subject — assert no code path is subject-specific.
- Add SQL-injection regression tests binding hostile strings into names/tags.

### P2-6 — Number/`lang` rendering
- `ContentValueView` `.number` (`:18`): use a `NumberFormatter` (locale-aware,
  integer vs decimal, guard `NaN`/`Infinity`).
- Consume `lang` for accessibility/TTS or drop it from the model and docs.

---

## 5. Cross-cutting test & CI additions

- All new tests must run under `./Scripts/test-fast.sh` (no UI tests locally per
  repo policy). UI-only accessibility checks go in the UITest target, run in CI
  or on explicit request.
- Add negative/adversarial fixtures as first-class: hostile import bundles,
  crafted `MediaRef` JSON, corrupt cloze spans, newer-schema DBs.
- Target: every scorecard row that is "Test ❌/⚠️" gains at least one failure-mode
  assertion, not just happy path.

---

## 6. Sequencing & dependencies

```
P0-1 cloze crash ─┐
P0-2 media read   ├─ independent, do first (security/crash)
P0-3 import path  ┘
P0-5 magic bytes ── depends on P0-2 (extension-from-content)
P0-4 limits ─────── depends on P0-2/P0-5 (ingest changes)
P0-6 append-only ── schema v5; do before P1-3/P1-4 stats work
P0-9 migration ──── precedes any new schema (v5 in P0-6, ref_count in P1-3)
P0-8 transactions ─ independent
P0-10 study ─────── independent
P1-1 templates ──── enables P1-2 cloze preset
P1-2 cloze ──────── depends on P0-1 + P1-1
P1-3 media GC ───── depends on P0-9 (migration) + P0-2
P1-4 FSRS ───────── independent
P2-* ────────────── after P0/P1 stabilize; P2-5 tracks all
```

Recommended order: **P0-1, P0-2, P0-3** (crash + two file-read holes; small,
high-severity, currently untested) → **P0-9** (so subsequent schema changes are
safe) → **P0-6, P0-8, P0-10** → **P0-4, P0-5** → **P0-7 docs** → P1 → P2.

---

## 7. Definition of done (scorecard → all green)

A row is green only when: code implements it, a hostile/edge test asserts it,
`test-fast.sh` stays green, and `PRODUCT.md` / `ARCHITECTURE.md` describe exactly
what ships (no present-tense promise for unbuilt behavior). The two documented
invariants that are currently false — "ReviewLog append-only" and FSRS
"adapts to the individual learner" — must be made **true** (P0-6, P0-7/D2-a) or
**rewritten** (D1-b, D2-b); either way the doc and code must agree.
