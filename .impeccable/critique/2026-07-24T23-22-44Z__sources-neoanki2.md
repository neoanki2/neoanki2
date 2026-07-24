---
target: Sources/NeoAnki2
total_score: 29
max_score: 40
na_heuristics: 
p0_count: 1
p1_count: 2
timestamp: 2026-07-24T23-22-44Z
slug: sources-neoanki2
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Study progress is clear; grading commits with no in-flight feedback beyond disabled buttons |
| 2 | Match System / Real World | 3 | Calm learner copy in study; Item Type / Template / Field jargon leaks into admin surfaces |
| 3 | User Control and Freedom | 3 | End-session confirm, Cancel/Save, Skip Card — but no undo after a grade |
| 4 | Consistency and Standards | 3 | Strong HIG split-view + Study menu; accent overused on form Save buttons; duplicated gating logic in ContentView/StudyView |
| 5 | Error Prevention | 3 | Save gating works; disabled Save gives no diagnosis of which field blocks submission |
| 6 | Recognition Rather Than Recall | 2 | Grade shortcuts (1–4) exist but are invisible on buttons; keyboard docs omit Escape, Skip, ⌘N, ⌘⇧T |
| 7 | Flexibility and Efficiency | 4 | Toolbar, menus, and keyboard paths wired through FocusedValues — genuinely keyboard-first |
| 8 | Aesthetic and Minimalist Design | 3 | Study stage is exemplary; toolbar mixes daily actions with schema admin at equal weight; hard-coded yellow highlight on card content |
| 9 | Error Recovery | 3 | ErrorBanner + plain copy; generic "Something went wrong" for unmodeled failures |
| 10 | Help and Documentation | 2 | Grade Help is the only in-app help; no first-run orientation for items, due cards, or scheduling |
| **Total** | | **29/40** | **Good — study loop is credible; trust, discoverability, and admin IA need work** |

## Design Specificity Verdict

**LLM assessment:** NeoAnki2 is authored where it matters most. The 600pt reading column, prompt→divider→answer stack, Study Indigo applied once at the root, and shame-free grade copy ("Didn't remember — show this card again soon") are product-specific choices a generic flashcard shell would not make. Browse mode has improved: `ItemReadingPreview` now renders field content in study typography, not metadata alone. The split personality remains in configuration: `TemplatesView`, `TemplateEditorView`, and `ItemTypeEditorView` expose raw schema vocabulary (Item Type, Field, Prompt, Answer) with no translation layer — legacy SRS mental model at equal prominence to daily study actions.

**Deterministic scan:** CLI `detect.mjs` returned `[]` (exit 0) — SwiftUI is not in scannable extensions. Manual static review found 11 issues: 1 high (hard-coded `Color.yellow` highlight in `ContentValueView.swift:51`), 5 medium (accent on form Save buttons, hard-coded empty-state font size, boxed panels in TemplatesView, incomplete Grade Help keyboard docs, undiscoverable Escape for End Session), 5 low (Skip Card a11y, End Session label, Item Types toolbar shortcut, off-grid spacing, popover width). No gamification patterns detected.

**Browser overlays:** Not available — native macOS SwiftUI app with no web render surface.

## Overall Impression

NeoAnki2 has crossed from scaffold to credible Mac study product in the detail pane (29/40, stable vs the Jul 24 post-polish run). "The Quiet Desk" is real in the study loop. The single biggest opportunity is earning trust in the highest-frequency interaction: grading dozens of cards via keyboard with no undo, no visible shortcut hints, and no feedback beyond a briefly disabled button.

## What's Working

1. **Study reading column** — Centered prompt/answer stack, flat stage, `.title`/`.title2` hierarchy, 600pt column via `readingColumnLayout()`. The clearest expression of the brand north star.
2. **Shame-free failure language** — "Again" carries no red, no alarm icon; scheduling consequences explained in calm tooltip copy. Deliberate emotional design most SRS apps get wrong.
3. **Keyboard craft + accessibility discipline** — `StudyCommands`, FocusedValues, Reduce Motion honored in `StudyAnimation`, and composite list rows get hand-written VoiceOver labels rather than fragment stitching.

## Priority Issues

**[P0] No undo or recovery after grading a card**
- **Why it matters:** Grading is the most repeated action (1–4 keypresses, dozens per session). A miskeyed grade silently corrupts scheduling with no recovery — directly undermines the "calm desk" trust promise.
- **Fix:** Brief post-grade undo affordance (toast or inline banner) that reverts `submitReview` and rewinds the queue for a few seconds.
- **Suggested command:** `$impeccable harden StudyView.swift`

**[P1] Grade keyboard shortcuts invisible at the point of use**
- **Why it matters:** DESIGN.md names keyboard-first study as a pillar, but buttons show only "Again/Hard/Good/Easy" — the 1–4 mapping lives in an opt-in Grade Help popover.
- **Fix:** Show shortcut glyphs on grade buttons (Mac menu convention); extend Grade Help with Escape (End Session) and → (Skip Card).
- **Suggested command:** `$impeccable polish StudyView.swift GradeGuideView.swift`

**[P1] Hard-coded yellow highlight breaks semantic color system on card content**
- **Why it matters:** Rich-text highlights use `Color.yellow.opacity(0.35)` — fails Dark Mode and Increased Contrast on the study stage where content must stay semantic and flat.
- **Fix:** Replace with a DesignSystem highlight token (e.g. `selectedTextBackgroundColor` or adaptive semantic fill).
- **Suggested command:** `$impeccable colorize ContentValueView.swift`

**[P2] "Item Types" is a permanent, equal-weight toolbar citizen**
- **Why it matters:** Schema authoring is the least-frequent, most complex task — sitting beside Study and Add Item contradicts "general learner, minimal chrome."
- **Fix:** Remove from toolbar; keep Library menu / ⌘⇧T entry only.
- **Suggested command:** `$impeccable distill ContentView.swift`

**[P2] Accent overused on form Save actions**
- **Why it matters:** `.borderedProminent` on Save in AddItemView, TemplateEditorView, ItemTypeEditorView, and TemplatesView dilutes the One Accent Rule — Study Indigo should mark forward motion in study, not admin forms.
- **Fix:** Use `.bordered` for form Save; reserve `.borderedProminent` for Study / Show Answer / session Done.
- **Suggested command:** `$impeccable quieter AddItemView.swift TemplatesView.swift`

## Persona Red Flags

**Alex (Power User):** Add Item always dismisses on save — no "Save & Add Another" for batch entry. Grade shortcuts invisible during rapid-fire review. No post-session or historical stats surface anywhere (by design during review, but nothing after either).

**Jordan (First-Timer):** App boots to empty sidebar with no explanation of items, due cards, or scheduling. "Item Types" toolbar button is unexplained jargon — curious click lands in schema editing. After first save, Study may still be disabled with no explanation that cards must become due first.

**Sam (Accessibility):** `ItemTypeEditorView` remove buttons all share static "Remove field" label — indistinguishable in VoiceOver. Skip Card lacks `.help()` and explicit label unlike grade buttons. Fixed 600pt reading column has no Dynamic Type overflow path at XXL sizes.

## Minor Observations

- `cardHasUnsupportedContent` duplicated between `ContentView` and `StudyView` — drift risk between menu commands and inline controls.
- `emptyDueView` and `finishedView` both use `checkmark.circle` — opposite emotional beats rendered identically.
- `SidebarEmptyState` CTA uses `.controlSize(.small)` — undersized for a first-run primary action.
- Template editor only creates `Interaction.reveal` templates with no copy explaining other interaction types aren't creatable yet.
- Off-grid spacing: `Spacing.rowTight = 4` and list row `.padding(.vertical, 2)`.

## Questions to Consider

- If "content is the hero," why does every user see a permanent Item Types button at equal weight to Study?
- Is "keyboard-first" a shipped behavior or a DESIGN.md aspiration when the fastest path hides its own keys?
- What does a calm app owe users when its most-repeated interaction is also its only irreversible one?
