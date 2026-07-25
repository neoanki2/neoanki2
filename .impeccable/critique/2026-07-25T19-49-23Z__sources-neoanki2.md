---
target: Sources/NeoAnki2
total_score: 28
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
timestamp: 2026-07-25T19-49-23Z
slug: sources-neoanki2
---
# NeoAnki2 Design Critique

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3 | Strong progress/loading states; deck moves lack in-flight feedback |
| 2 | Match between system and real world | 2 | Builder vocabulary leaks into learner-facing schema tools |
| 3 | User control and freedom | 3 | Undo/cancellation are strong; saved items have no edit path |
| 4 | Consistency and standards | 2 | Deck-first IA conflicts with the documented item-first sidebar |
| 5 | Error prevention | 3 | Good destructive guards and disabled invalid saves |
| 6 | Recognition rather than recall | 2 | Item types and grade meaning require discovery |
| 7 | Flexibility and efficiency | 4 | Excellent Mac keyboard study workflow |
| 8 | Aesthetic and minimalist design | 3 | Study is calm; schema editors are dense |
| 9 | Error recovery | 3 | Plain-language errors and preserved state are generally strong |
| 10 | Help and documentation | 3 | Grade help is useful; authoring lacks contextual onboarding |
| **Total** | | **28/40** | **Good** |

## Design Specificity Verdict

**Moderately product-specific.** The study loop is authored for NeoAnki2's “Quiet Desk”: a centered reading column, phased reveal and grading, restrained accent, keyboard shortcuts, and no gamification. Library and schema management read as generic SwiftUI administration: deck-first navigation, dense forms, and builder vocabulary such as Modality, Operation, slots, and conditions.

The deterministic scan returned zero findings because the target consists of Swift files outside the detector's web/markup scan set. This is not evidence that the native UI is clean. Browser overlays were not applicable to a native SwiftUI target.

## Overall Impression

NeoAnki2 already has a convincing study experience. Its biggest opportunity is to bring authoring and library management to the same level of learner-facing calm. Today the app is easiest at the moment of review and hardest at the moments when users create, organize, or correct their knowledge.

## What's Working

1. The study stage executes the design system: one reading column, one primary action per phase, neutral grade actions, and no visual spectacle.
2. Keyboard-first Mac craft is substantive: grading, undo, session control, recording, and arrangement all have shortcuts.
3. Destructive actions, import conflicts, and operational errors generally use plain language and explicit confirmation.

## Cognitive Load

**Five of eight checklist items fail on schema-authoring paths:** single focus, chunking, one thing at a time, minimal choices, and progressive disclosure. Examples include eight field types, six interaction modes, and multiple modality pickers presented without a novice/advanced split. Study itself has low cognitive load.

## Emotional Journey

- **Peak:** focused reveal and grading loop.
- **Valley:** first encounter with Item Types and template slots.
- **End:** clear session-complete closure with undo.

## Priority Issues

### [P1] Existing items cannot be edited
- **Why it matters:** A typo or content correction forces recreation; this breaks ownership and trust in a knowledge tool.
- **Evidence:** `Sources/NeoAnki2/ItemReadingPreview.swift:62-144`
- **Fix:** Add an Edit Item path that reuses existing field editors and preserves the reading preview.
- **Suggested command:** `$impeccable harden`

### [P1] Schema authoring exposes builder jargon and too many simultaneous decisions
- **Why it matters:** General learners must understand implementation concepts before they can customize a card.
- **Evidence:** `Sources/NeoAnki2/TemplateEditorView.swift:33-107`
- **Fix:** Default to Basic; move skill, slot, condition, and modality controls behind an Advanced disclosure. Rename Item Types to learner-facing language.
- **Suggested command:** `$impeccable distill`

### [P2] Deck-first IA conflicts with the documented item-first mental model
- **Why it matters:** Users must understand scope before they can browse content; the implementation and design contract teach different navigation models.
- **Evidence:** `Sources/NeoAnki2/DeckSidebarView.swift:26-66`
- **Fix:** Reframe the sidebar as Library with clear scope and item access, or explicitly update the design contract and strengthen scope labels.
- **Suggested command:** `$impeccable shape`

### [P2] Template rows duplicate edit affordances
- **Why it matters:** A tappable row plus a pencil button creates redundant focus stops and visual noise.
- **Evidence:** `Sources/NeoAnki2/TemplatesView.swift:316-350`
- **Fix:** Keep one edit affordance.
- **Suggested command:** `$impeccable polish`

### [P2] Primary action styling is inconsistent
- **Why it matters:** Save and Study do not always receive the visual priority promised by the one-accent design rule.
- **Evidence:** `Sources/NeoAnki2/AddItemView.swift:69-75`, `Sources/NeoAnki2/StudyView.swift:431-457`
- **Fix:** Use prominent styling only for the current forward action; keep grade actions neutral.
- **Suggested command:** `$impeccable polish`

## Persona Red Flags

- **Alex, power user:** No item editing or bulk operations; field reordering is one arrow action at a time.
- **Jordan, first-timer:** Item Types, Modality, Operation, and slot conditions assume schema knowledge; grade meaning is hidden behind help.
- **Sam, accessibility-dependent:** Media semantics, cloze blanks, and repeated slot controls do not consistently provide enough spoken context.
- **River, general learner:** Adding is approachable, but correcting saved content and customizing cards exposes builder-oriented friction.

## Minor Observations

- Import footer actions and Add Item toolbar actions use different patterns.
- Grade help is valuable but collapses too much content into one VoiceOver element.
- The implementation intentionally uses larger card typography than the documented baseline; the design document should be refreshed if this is final.

## Questions to Consider

1. Should editing existing content ship before deeper template customization?
2. Is deck hierarchy truly first-class for v1, or should the sidebar return to an item-first library?
3. Should advanced template vocabulary stay invisible until the learner explicitly opts into customization?
