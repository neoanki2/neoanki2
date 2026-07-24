---
target: NeoAnki2 app UI
total_score: 21
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
p2_count: 2
timestamp: 2026-07-24T21-49-14Z
slug: sources-neoanki2
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2 | Full-screen spinners; minimal study progress |
| 2 | Match System / Real World | 3 | SRS vocabulary is appropriate |
| 3 | User Control and Freedom | 3 | Cancel on sheets; no undo after grade |
| 4 | Consistency and Standards | 2 | iOS navigation patterns on macOS |
| 5 | Error Prevention | 2 | Save gating works; raw error strings |
| 6 | Recognition Rather Than Recall | 2 | No menus or shortcuts surfacing actions |
| 7 | Flexibility and Efficiency | 1 | No keyboard shortcuts for study grades |
| 8 | Aesthetic and Minimalist Design | 3 | Clean but generic system-default UI |
| 9 | Error Recovery | 2 | Errors shown inline but often technical |
| 10 | Help and Documentation | 1 | No onboarding beyond empty states |
| **Total** | | **21/40** | **Acceptable — significant Mac UX work needed** |

## Design Specificity Verdict

NeoAnki2 reads as a competent SwiftUI scaffold for a spaced-repetition tool, not yet as a Mac-native study product with its own visual or interaction identity. Architecture docs (`docs/DESIGN.md`) are strong on domain philosophy but do not define visual tokens, typography, or Mac window structure. The UI could belong to any early-stage flashcard app.

Deterministic scan: skipped — native SwiftUI target; web `detect.mjs` does not apply.

## Overall Impression

The foundation is solid: semantic empty states, toolbar actions, grouped forms, and clear study flow. The biggest gap is platform maturity — it behaves like an iOS app in sheets rather than a Mac productivity tool with split navigation, menu commands, and keyboard-driven study.

## What's Working

- `ContentUnavailableView` empty and completion states guide first-time users.
- Semantic typography and colors (`.headline`, `.secondary`, `.tertiary`) avoid hard-coded styling.
- Study flow is cognitively simple: prompt → reveal → grade, with a clear progress label.

## Priority Issues

**[P1] Mac platform conformance — iOS-shaped shell**
Why: Mac users expect sidebar + detail, menu commands, and resizable primary window — not stacked navigation in sheets.
Fix: Adopt `NavigationSplitView` for items; consider inline/study pane instead of sheet for frequent study.
Suggested command: `$impeccable layout`

**[P1] No keyboard efficiency for core study loop**
Why: Grading (Again/Hard/Good/Easy) is the highest-frequency action; mouse-only flow breaks flow state.
Fix: Add `keyboardShortcut` for 1–4 or J/K variants; menu items under Study.
Suggested command: `$impeccable harden`

**[P1] Accessibility labels missing for VoiceOver**
Why: `accessibilityIdentifier` serves UI tests, not screen reader labels; errors use color alone.
Fix: Add `accessibilityLabel`/`accessibilityHint` on grade buttons and list rows; announce progress changes.
Suggested command: `$impeccable audit`

**[P2] Content rendering gap undermines product promise**
Why: `ContentValueView` shows "Unsupported content" for media/cloze — breaks trust for non-text cards.
Fix: Implement media and cloze renderers or gate item types until supported.
Suggested command: `$impeccable harden`

**[P2] No captured product context (PRODUCT.md)**
Why: Impeccable and future agent passes lack audience, tone, and Mac UX priorities.
Fix: Run `$impeccable init` to capture product brief separate from architecture doc.
Suggested command: `$impeccable init`

## Persona Red Flags

**Alex (Power User):** No keyboard shortcuts. Study opens in a sheet instead of a dedicated window/pane. Cannot batch-review or skip with keys. Will feel the app is a prototype.

**Jordan (First-Timer):** "Again/Hard/Good/Easy" assumes SRS knowledge — no inline explanation of what each grade means. Add Item sheet doesn't explain what an "item type" is.

**Sam (Accessibility):** Interactive elements rely on test identifiers, not human-readable labels. Error text uses `.red` without icons or accessibility announcements.

## Minor Observations

- Study layout uses centered `VStack` with `Spacer()` — content floats in wide windows instead of a max-width reading column.
- `CommandGroup(replacing: .newItem)` removes New without replacing it — lost Mac convention.
- Duplicate primary actions: "Add Item" in empty state and toolbar (acceptable but redundant).
- Loading states replace entire views rather than inline/skeleton patterns.

## Questions to Consider

- Should study be a first-class window scene rather than a dismissible sheet?
- What is the one signature visual moment for card review (typography, material, spacing)?
- Which content types must work before the UI can feel "complete"?
