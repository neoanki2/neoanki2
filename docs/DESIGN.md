---
name: NeoAnki2
description: A calm, native Mac study surface where card content is the hero and the app chrome disappears.
colors:
  accent-study: "{system.controlAccentColor}"
  surface-sidebar: "{system.controlBackgroundColor}"
  surface-detail: "{system.windowBackgroundColor}"
  text-primary: "{system.labelColor}"
  text-secondary: "{system.secondaryLabelColor}"
  text-tertiary: "{system.tertiaryLabelColor}"
  semantic-error: "{system.systemRed}"
  semantic-success: "{system.systemGreen}"
typography:
  card-prompt:
    fontFamily: "SF Pro, system-ui"
    fontSize: "34pt"
    fontWeight: 400
    lineHeight: 1.25
  card-answer:
    fontFamily: "SF Pro, system-ui"
    fontSize: "28pt"
    fontWeight: 400
    lineHeight: 1.3
  ui-title:
    fontFamily: "SF Pro, system-ui"
    fontSize: "22pt"
    fontWeight: 600
    lineHeight: 1.2
  ui-body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "17pt"
    fontWeight: 400
    lineHeight: 1.45
  ui-caption:
    fontFamily: "SF Pro, system-ui"
    fontSize: "15pt"
    fontWeight: 400
    lineHeight: 1.3
rounded:
  sm: "6pt"
  md: "8pt"
  lg: "10pt"
spacing:
  xs: "8pt"
  sm: "12pt"
  md: "16pt"
  lg: "24pt"
  xl: "32pt"
  study-column-max: "600pt"
components:
  button-primary:
    backgroundColor: "{colors.accent-study}"
    textColor: "#FFFFFF"
    rounded: "{rounded.md}"
    padding: "8pt 16pt"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    padding: "6pt 12pt"
  grade-button:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.sm}"
    padding: "6pt 14pt"
---

# Design System: NeoAnki2

<!-- SEED+SCAN: Visual strategy established from product research and incumbent SwiftUI; re-run $impeccable document after major UI passes to refresh extracted tokens. -->

> **Note:** Domain architecture and learning-science rationale live in [`ARCHITECTURE.md`](ARCHITECTURE.md). This file is the **visual design system** for the SwiftUI shell.

## Overview

**Creative North Star: "The Quiet Desk"**

NeoAnki2 should feel like a well-lit desk: one open page (the card), a tidy stack of notes to the side (the item list), and almost nothing else competing for attention. The product is a **calm Mac study tool**, not a gamified learning app and not a legacy SRS dashboard.

Research across native SRS apps (immemor, sumi, SpaceRep, Cortex) and Apple platform guidance (HIG, WWDC25 design system) converges on one strategy: **platform-native restraint + content-forward layout**. Competitors that win on trust use minimal chrome, FSRS without spectacle, and typography that privileges the card. Anki’s spreadsheet density and Quizlet’s game visuals are explicit anti-references.

NeoAnki2 expresses brand through **precision and calm** — correct split-view structure, keyboard-first study, semantic system colors, and a single accent reserved for primary forward motion (Study, Show Answer). Scheduling stays invisible; the card is the only hero per screen.

**Key Characteristics:**

- Content-first: card prompt/answer dominates the detail pane
- Mac-native: `NavigationSplitView`, menus, keyboard shortcuts, tooltips
- Semantically colored: SwiftUI system colors, not hard-coded grays
- Restrained accent: tint appears on ≤2 primary actions per screen
- Tonal depth: sidebar vs detail via system surfaces, not custom shadows
- No gamification visuals: no streak flames, progress rings, or confetti

## Colors

The palette is **semantic-first**. Prefer SwiftUI `Color` roles and `NSColor` system names so Light/Dark Mode, the user's chosen accent, and Increased Contrast adapt automatically.

### Primary

- **System Accent** (`controlAccentColor`): The app tint and primary action fill (Study, Show Answer). It follows the user's macOS accent and includes system-provided Light, Dark, and Increased Contrast variants. Apply via `.tint()` at app root; never as a full-bleed background.

### Neutral

- **Sidebar Surface** (`controlBackgroundColor`): Item list column; slightly recessed from detail.
- **Detail Surface** (`windowBackgroundColor`): Study and item preview — the “desk page.”
- **Primary Text** (`labelColor`): Card content, titles, button labels.
- **Secondary Text** (`secondaryLabelColor`): Subtitles, progress (“Card 3 of 12”), metadata.
- **Tertiary Text** (`tertiaryLabelColor`): Hints, optional field labels, helper copy.
- **Separator** (`separatorColor`): Dividers between prompt and answer, header/footer rules.

### Semantic

- **Error Rose** (`systemRed` at ~12% opacity for banners; full red for icon): Inline errors only — always paired with icon + text.
- **Success** (`systemGreen`): Reserved for future “correct answer” feedback in Type mode — not used decoratively today.

### Named Rules

**The One Accent Rule.** The system accent appears only on primary forward actions (Study, Show Answer, Done on completion). Grade buttons, list rows, and chrome stay neutral bordered styles.

**The No Gamification Palette Rule.** Do not introduce streak orange, achievement gold, or chart rainbow colors. Progress is text (“Card 3 of 12”), not rings or bars.

## Typography

**Display Font:** SF Pro (system) — card prompt only  
**Body Font:** SF Pro (system) — all UI chrome, answers, forms  
**Label Font:** SF Pro (system) — captions, progress, toolbar

**Character:** Single-family, Apple-native, optimized for screen reading at desk distance. No display/body pairing — product UI clarity over editorial personality.

### Hierarchy

- **Card Prompt** (regular, `.largeTitle` / ~34pt, 1.25 line-height): Primary retrieval question; center-aligned in study column; multiline supported.
- **Card Answer** (regular, `.title` / ~28pt, 1.3 line-height): Revealed content; visually subordinate to prompt but still comfortable to read.
- **Title** (semibold, `.title2` / `.title3`): Item titles in sidebar and detail preview.
- **Body** (regular, `.body` / ~17pt): Form labels, descriptions, empty-state copy. Max ~65 characters per line in study column.
- **Caption** (regular, `.subheadline` / ~15pt): Progress, card counts, metadata, error banners.

### Named Rules

**The Card Type Scale Rule.** Only card prompt uses `.largeTitle`; only card answer uses `.title`. UI chrome never borrows card sizes — prevents “everything shouts.”

**The Dynamic Type Rule.** Use semantic SwiftUI text styles via `DesignSystem.Typography` — never hard-coded `.font(.system(size:))` in production views.

## Layout

**Spatial model:** `NavigationSplitView` — sidebar (items) + detail (study or preview). This matches Mac user expectations (Reminders, Notes) and the confirmed study-flow brief.

| Region | Width | Behavior |
|--------|-------|----------|
| Sidebar | 220–340pt (ideal 260) | Item list, selection, empty state |
| Detail | Flexible | Study session or item preview |
| Study reading column | max 600pt centered | Card content; never full-bleed text on ultrawide windows |
| Window default | 960×640pt | Comfortable split at launch |

**Spacing rhythm (8pt grid):** 8 / 12 / 16 / 24 / 32pt — padding in study header (12×20), card area (24×32), footer actions (20).

**Study pane structure (top → bottom):**

1. Session header — progress + help + end session  
2. Scrollable card stage — prompt, divider, answer  
3. Optional error banner — full width, subtle fill  
4. Fixed footer — Show Answer or grade row  

**Responsive behavior:** On future iPad/iPhone, collapse split to stack navigation; study column becomes full width with bottom-fixed grade bar (touch targets ≥44pt). Mac density preserved on desktop.

### Named Rules

**The Split-First Rule.** Study never returns to a sheet modal on Mac. Detail pane owns the session.

**The Reading Measure Rule.** Card text lives in a centered column capped at 600pt (~65ch for typical content). Wide windows add margin, not longer line lengths.

## Elevation & Depth

**Philosophy:** Tonal layering, not drop shadows. Depth comes from system background roles and dividers — appropriate for a productivity surface and aligned with Apple’s content-forward direction (including Liquid Glass on **navigation only**).

- Sidebar uses `controlBackgroundColor` (recessed)
- Detail uses `windowBackgroundColor` (primary work surface)
- Dividers use `separatorColor` — 1pt horizontal rules only
- No card-style boxed containers around study content (no “floating card” shadow)

**Liquid Glass (macOS 26+):** Apply to sidebar chrome and toolbar if/when adopting Tahoe SDK. **Never** apply glass materials to the study prompt/answer area or item list rows — content stays opaque for readability (WWDC25: “navigation layer only”).

### Named Rules

**The Flat Study Stage Rule.** The study card is not a `Card` component with shadow. It is text on the desk — divider + typography hierarchy only.

## Shapes

- **Corner radius:** System default for buttons (`.bordered`, `.borderedProminent`) — do not custom-radius primary controls.
- **Forms:** `.formStyle(.grouped)` for Add Item sheet — Mac settings pattern.
- **Popovers:** Grade help uses standard popover; no custom corner treatment.
- **Icons:** SF Symbols only — `play.fill`, `plus`, `questionmark.circle`, `checkmark.circle`, `rectangle.stack`.

### Named Rules

**The Platform Shape Rule.** If SwiftUI or AppKit provides the control, use its default geometry. Custom radii only for future media containers (image/audio cards).

## Components

### Buttons

- **Shape:** System bordered styles (6–8pt effective radius)
- **Primary:** `.borderedProminent` — Study, Show Answer, Done on completion; uses accent tint
- **Secondary:** `.bordered` — grade buttons (Again/Hard/Good/Easy), Cancel, Skip Card
- **Tertiary:** `.borderless` — Grade help icon, End Session text in header
- **Hover / Focus:** System-default; ensure keyboard focus ring visible
- **Disabled:** System dimmed state during `isGrading`

### Grade row

- **Layout:** Horizontal `HStack`, 12pt spacing, centered in footer
- **Labels:** Single word only (Again/Hard/Good/Easy) — meaning in tooltip + Help popover
- **Keyboard:** 1–4 shortcuts; VoiceOver labels include full meaning

### Lists (sidebar)

- **Style:** Standard `List` with selection
- **Row content:** Title (headline) + subtitle (secondary) + metadata line (caption/tertiary)
- **No** custom row backgrounds, swipe chrome, or trailing button clusters in v1

### Empty states

- **Component:** `ContentUnavailableView` + SF Symbol + one primary action
- **Tone:** Direct, encouraging, no exclamation-mark hype

### Sheets

- **Add Item:** Grouped form, min 420×220; Cancel/Save in toolbar
- **Use sparingly:** Prefer detail-pane inline editing when add-item becomes frequent

### Navigation

- **Split view:** Sidebar title “Items”; window title “NeoAnki2”
- **Toolbar:** Study (with due badge), Add Item — no icon-only mystery meat
- **Menus:** Study menu with shortcuts documented in Grade Help

### Signature element: Study reading column

The centered prompt → divider → answer stack is the product’s visual signature. Protect its simplicity: no badges, no side panels, no stats during review.

### Media fields

- **Layout:** Max width `study-column-max` (600pt); centered in the reading column like text cards.
- **Image / GIF:** Rounded 8pt container; optional alt text shown as caption (`ui-caption`, secondary color).
- **Audio / video:** Native AVKit controls; no custom chrome beyond system player.
- **Prompt behavior:** Respect `MediaBehavior` — autoplay only when slot requests it; honor Reduce Motion by skipping autoplay when the system setting is on.
- **Blur / hidden:** Image prompt slots may use blurred or hidden-until-answer presentation; answer side shows full media.

## Do's and Don'ts

### Do:

- **Do** use semantic SwiftUI colors (`.primary`, `.secondary`, `.tertiary`, `.red` for errors with icons).
- **Do** keep one primary action visible per study phase (Show Answer *or* grade row, never both prominent).
- **Do** expose keyboard paths (Space/Return, 1–4, ⌘⇧S) and document them in Grade Help.
- **Do** test Light, Dark, and Increased Contrast before shipping UI changes.
- **Do** adopt Liquid Glass on sidebar/toolbar when targeting macOS 26 — with opaque study content.

### Don't:

- **Don't** gamify: streaks, XP, leaderboards, celebratory animations, or progress rings.
- **Don't** use hard-coded `#888` grays — they break Dark Mode.
- **Don't** put custom shadows, gradients, or glass on card content.
- **Don't** use display serifs, condensed fonts, or “flashcard app cute” illustration styles.
- **Don't** copy Anki’s dense toolbar/grid aesthetic or Quizlet’s bright game UI.
- **Don't** show scheduling statistics during active review — study is for retrieval, not analytics.

## Research Summary (strategy rationale)

| Reference | Relevant lesson for NeoAnki2 |
|-----------|------------------------------|
| **Apple HIG / WWDC25** | Split view, content-forward layout; Liquid Glass on navigation only |
| **Reminders / Notes** | Structural reference for sidebar + detail on Mac |
| **immemor, sumi, Cortex** | “Quiet flashcard app” positioning — FSRS without spectacle |
| **Anki** | Anti-reference — density, legacy chrome, HTML-card aesthetic |
| **Quizlet** | Anti-reference — gamification, streaks, bright casual UI |
| **Incumbent code** | 600pt column, semantic fonts, bordered buttons, 8pt spacing grid |

**Recommended evolution path:**

1. **Now (macOS 14+):** Semantic system theme + Study Indigo tint + split layout (current direction)
2. **Next:** Type/Choose interaction UI using same reading column and footer pattern
3. **macOS 26:** Liquid Glass sidebar/toolbar adoption without touching study stage opacity
4. **iOS/iPad:** Stack navigation + bottom grade bar; preserve typography scale via Dynamic Type
