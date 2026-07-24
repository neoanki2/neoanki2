---
target: Sources/NeoAnki2
total_score: 29
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
p2_count: 2
timestamp: 2026-07-24T22-12-42Z
slug: sources-neoanki2
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Study progress strong; `ItemsModel` load errors never shown in main window |
| 2 | Match System / Real World | 3 | Calm copy; item/card/type jargon leaks in sidebar and Add form |
| 3 | User Control and Freedom | 3 | End-session confirm, Cancel/Save, Skip Card; no grade undo |
| 4 | Consistency and Standards | 3 | Mac split view + Study menu align with DESIGN.md; minor padding drift |
| 5 | Error Prevention | 3 | Save gating, end-session guard; unsupported cards can queue without upfront warning |
| 6 | Recognition Rather Than Recall | 3 | Grade tooltips + Help popover; SRS labels visible before explanation |
| 7 | Flexibility and Efficiency | 3 | Full keyboard path (⌘⇧S, Space/Return, 1–4, Study menu) |
| 8 | Aesthetic and Minimalist Design | 4 | Quiet Desk delivered in study: flat stage, restrained accent, no gamification |
| 9 | Error Recovery | 2 | ErrorBanner solid in study/add; raw `localizedDescription` in models; silent load failures |
| 10 | Help and Documentation | 2 | Grade Help is opt-in icon-only; no first-run orientation for item/card/SRS |
| **Total** | | **29/40** | **Good — study loop ships; browse/add/error surfacing need work** |

## Design Specificity Verdict

**LLM assessment:** The study experience is authored for NeoAnki2 — 600pt reading column, prompt→divider→answer hierarchy, Study Indigo on forward actions only, text progress without rings. `DesignSystem.swift` codifies the north star in code. Browse and add still read as category-default Mac app: metadata-only item preview, grouped settings form, schema labels in the sidebar. A competitor could swap the accent hex and ship the same shell.

**Deterministic scan:** Web `detect.mjs` returned `[]` (exit 0) — not applicable to native SwiftUI. Manual static review found: 1 substantive hard-coded error red (`DesignSystem.swift:52`), 0 reduce-motion gaps, 0 typography-on-chrome violations, 0 gamification patterns. List rows, Grade Guide popover, and bootstrap states lack rich explicit accessibility metadata.

**Browser overlays:** Skipped — native macOS app; no reliable web overlay path.

## Overall Impression

The design system pass moved NeoAnki2 from scaffold to credible Mac study product in the detail pane (+8 heuristics vs Jul 24 baseline). The single biggest opportunity: unify browse and study around the same "desk page" reading column, and hide distractions during active review.

## What's Working

- **Study reading column** — Centered prompt/answer stack, flat stage, typography hierarchy enforced; clearest expression of "The Quiet Desk."
- **Keyboard craft** — `StudyCommands` + `FocusedValues`, menu mirrors footer, `StudyAnimation` honors Reduce Motion.
- **Design system discipline** — Centralized tokens, semantic surfaces, shared `ErrorBanner`, grade accessibility labels.

## Priority Issues

**[P1] Item detail shows metadata, not content**
Why: Violates "content is the hero" in browse mode; users can't verify what they added without starting study.
Fix: Render item fields in the same 600pt reading column / typography as study preview.
Suggested command: `$impeccable polish Sources/NeoAnki2`

**[P1] No study focus mode — sidebar stays visible and selectable**
Why: Split view competes with the desk-page metaphor during retrieval practice.
Fix: Collapse or hide sidebar column while `isStudying`.
Suggested command: `$impeccable layout Sources/NeoAnki2`

**[P1] Load errors silently dropped in main window**
Why: `ItemsModel.errorMessage` set on failed `load()` but never surfaced in `ContentView`.
Fix: Show `ErrorBanner` above sidebar/list when load fails.
Suggested command: `$impeccable harden Sources/NeoAnki2`

**[P2] Grade vocabulary shown before explanation**
Why: Again/Hard/Good/Easy assume SRS literacy; meaning hidden in tooltips and opt-in Help.
Fix: First-run grade guidance inline or auto-open Grade Help on first grade phase.
Suggested command: `$impeccable onboard Sources/NeoAnki2`

**[P2] Unsupported content dead-end in live queue**
Why: Media/cloze cards show placeholder + Skip only; may erode trust if many appear in session.
Fix: Filter/warn at session start; clarify Skip impact on scheduling.
Suggested command: `$impeccable harden Sources/NeoAnki2`

## Persona Red Flags

**Alex (Power User):** No search/sort in sidebar; item detail useless for content verification; Skip bound to Right Arrow (non-standard); disabled Study menu items give no hint why.

**Jordan (First-Timer):** Item→card relationship explained once in empty state, not in Add flow; raw item type name as form section header; four cryptic grade buttons; no post-save reassurance about when cards become due.

**Sam (Accessibility):** Grade Help is icon-only; list rows lack combined accessibility summary; duplicate `accessibilityIdentifier("studyDone")` on two buttons; Grade Guide popover awkward for keyboard/VoiceOver users.

## Minor Observations

- `ContentValueView` "Unsupported content" tone differs from study-level `ContentUnavailableView`.
- Detail pane has no contextual title during study.
- Grade Guide omits Space, Return, and ⌘⇧S documented in DESIGN.md.
- Error banner uses hard-coded `Color.red.opacity(0.12)` — may wash out in Increased Contrast.

## Questions to Consider

- If "one open page" is the north star, why does study share the window with a selectable item list?
- Should browse and study share the exact same reading column component?
- When the user taps Skip on an unsupported card, what story does FSRS tell?
