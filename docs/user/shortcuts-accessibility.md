---
title: Shortcuts and accessibility
description: Use NeoAnki2 by keyboard and distinguish automated accessibility coverage from unverified behavior.
audience: user
nav_order: 9
parent: User Guide
---

# Shortcuts and accessibility

NeoAnki2 uses standard macOS menus, controls, focus behavior, and semantic
system colors. Menu items are disabled when their action is unsafe—for example,
imports are disabled during study and portable export requires a selected
deck.

## Accessibility evidence and limits

Current automated tests verify specific behavior, not general accessibility
conformance:

- routing logic produces announcements and answer/error focus targets, and
  suppresses only consecutive duplicate announcements;
- concealed content policies cover every content/reveal combination without
  putting hidden answer text in accessibility labels;
- Reduce Motion suppresses time-based audio/video autoplay and GIF animation;
- image and GIF item validation requires a description; and
- UI tests exercise selected keyboard paths: Space to reveal, `3` to grade
  Good, Command-Z to undo, Right Arrow to self-grade, and Command-Down Arrow
  during arrange.

The test suite does **not** run a live VoiceOver session, verify spoken output
or focus movement end to end, audit every screen at every text size, measure
contrast, or establish WCAG conformance. Full keyboard traversal, Voice
Control, Switch Control, Zoom, and localization with assistive technology are
also unverified as complete user journeys.

The sections below document behavior implemented in current source. Treat
anything outside the tested list above as implemented but not independently
verified with its assistive technology. If you depend on one of those paths,
test the current development build and [report a minimal, privacy-redacted
issue](../support/#report-an-issue-safely).

## Menus

The app adds these commands to the standard macOS menu bar.

### File

- **New Item** — **Command-N** — adds an item to the selected scope.
- **Add from Vocabulary…** searches an installed offline vocabulary pack and
  adds generated items to the selected deck.
- **Import…** opens a JSON or CSV file.
- **Import Deck…** opens a `.neodeck` file or `.neoanki` bundle.
- **Import Vocabulary Pack…** validates and installs a local `.neovocab`
  directory.
- **Export Deck…** exports the selected real deck as `.neodeck`.

There is no **New Window** or **New Tab**; NeoAnki2 has one library. Create decks
with the controls in the sidebar.

### Library

- **Browse Items** — **Command-Option-B**
- **Show / Hide Answer Column** — **Command-Option-A** (browse mode only)
- **Review Affected Items** on the scope home opens the same keyboard-navigable
  Browse table filtered to repeatedly forgotten cards' source items.
- Select one or more rows and choose **Mark Selected OK** to remove reviewed
  warnings without editing their items. The action is disabled with no
  selection, is also available from the row context menu, and each item returns
  after another lapse.
- **Show All Items** clears that filter.
- **Vocabulary Packs…** lists the packs installed in the current library.
- **Item Types…** — **Command-Shift-T**

### Study

- **Start Study** — **Command-Shift-S**
- **End Session**
- **Edit Card…** — **Command-E** — opens the current card's item editor.
- **Continue** — **Space** from the Study menu; **Return** also activates the
  in-view default action.
- **Grade: Again** — **1**
- **Grade: Hard** — **2**
- **Grade: Good** — **3**
- **Grade: Easy** — **4**
- **Undo Last Grade** — **Command-Z**

Commands become available only in the relevant state. Grades are disabled until
the answer is revealed, and every study command is disabled while the card
editor is open.

### Scheduling

- **Scheduling Settings…** sets when a new study day begins.

There is no optimization command. Parameter fitting runs by itself when review
history warrants it, so there is no menu item to find, enable, or wait on.

## Keyboard shortcuts by task

### Library and editors

- **Command-N:** add an item from the library view.
- **Command-Shift-S:** start studying when the selected scope has due cards.
- **Command-Option-B:** open browse mode for the selected scope.
- **Command-Option-A:** show or hide the Answer column while browsing.
- **Command-Shift-T:** open Item Types.
- **Previous Page / Next Page:** move through Browse results when more than 500
  items match. The footer also exposes the visible item range and page number.
- **Return:** activate the default save, create, import, check, or reveal action
  in the current sheet or editor.
- **Escape:** cancel a sheet/editor, leave browse mode, or close Item Types with
  **Done**.

### Study

- **Space** or **Return:** reveal the answer or run the current interaction's
  primary check action.
- **Right Arrow:** reveal without automatic checking and self-grade on typed,
  choice, record, and arrange cards.
- **1–4:** select Again, Hard, Good, or Easy after reveal. With Fail / Pass
  grades enabled, **1** selects Fail (Again) and **2** selects Pass (Good).
  Before reveal, the same number keys choose a multiple-choice option when one
  is present.
- **Command-E:** edit the item behind the current card, then **Return** to save
  or **Escape** to cancel.
- **Command-Z:** undo the most recent grade when undo is available.
- **Escape:** request to end the session. If at least one card was reviewed and
  the session is still active, NeoAnki2 asks for confirmation.
- **Command-R:** start, stop, or redo a recording on record cards.
- **Command-P:** play or stop your study recording.
- **Command-1** through **Command-9:** select one of the first nine items on an
  arrange card.
- **Command-Up Arrow / Command-Down Arrow:** move the selected arrange item.

On a record card, stop the recording before **Reveal & Compare** becomes
available. After reveal, **Play My Recording** remains available beside the
written answer. A separate reference-audio control appears only when the card
contains real answer audio. If it does not, NeoAnki2 says that no reference
audio is available; it does not synthesize a voice from the answer text.

## VoiceOver and focus

Rows combine their important text into one useful VoiceOver label: deck rows
include counts, item rows include title, summary, card count, and item type, and
study progress is labeled as progress. Choice and arrange controls announce
their position and selected state.

The active study stage follows the preset's semantic region order and omits
concealed answer regions from VoiceOver until reveal. It does not scroll; when
Dynamic Type or long content exceeds the available stage, **View full content**
opens a scrollable detail sheet while the grading footer remains stable.
For Focus compositions, reveal preserves the authored order: the original
question remains first, the expected answer follows immediately, and
supplemental answer details remain last. VoiceOver focus still moves to the
newly revealed answer.

Scheduling health uses text and symbols as well as color, and migration or
optimization progress remains readable with Dynamic Type.

Parent deck selection and disclosure remain separate actions. Activating the
row selects that deck's scope without expanding it; use the disclosure triangle
to show or hide its children. A focused UI test verifies both actions.

Pointer users can drag the small reorder handle beside a deck without changing
the row selection. Each deck row also exposes accessibility actions for moving
it up or down, moving it out one level, moving it to the top level, or placing
it inside another eligible deck. The same operations are available from the
row's **Move** context menu when dragging is inconvenient.

NeoAnki2 also routes important changes to accessibility focus:

- revealing an answer announces **Answer revealed** and moves focus to the
  answer;
- recording failures announce the recording error and focus its message; and
- error banners announce **Error** plus the message and receive focus.

Consecutive duplicate announcements are suppressed. Hidden or blurred answer
media is announced as concealed rather than exposing its description early.
Use the **Grade Help** button in a study session for the meaning of each grade
and a compact shortcut reminder.

## Text size, contrast, and color

The interface uses semantic macOS text styles and preferred AppKit fonts, so it
responds to the user's text-size and Dynamic Type settings. Study prompts,
answers, editor text, captions, and empty states preserve their hierarchy as
the preferred size changes.

Colors come from system window, control, accent, highlight, and status colors,
including Light, Dark, and Increased Contrast variants. Errors use an icon,
the word **Error** in their accessibility label, and text—not red alone.
Selected choice and arrange states also have labels or values rather than
depending on checkmark color.

## Reduce Motion

With **Reduce motion** enabled in macOS Accessibility settings, answer and
navigation reveal transitions occur without animation. Audio, GIF, and video
marked for autoplay do not autoplay, and GIF animation remains stopped even if
its template requests autoplay or looping. Manual media controls remain
available.

## Media descriptions

An image or GIF cannot be saved to an item without a nonblank **Image
description**. Write a short description that communicates the information the
image contributes, not its filename. NeoAnki2 uses it as the image's VoiceOver
label.

Descriptions for audio and video are optional but recommended; they appear as
supporting text and accessibility labels. A play-on-tap audio control includes
the description in its label. If answer media is hidden until reveal, its
description is not announced before the answer.

## Keyboard and assistive-technology tips

- Use macOS **Keyboard navigation** or VoiceOver navigation to reach toolbar,
  sidebar, form, and dialog controls.
- If a shortcut types into a focused text field instead of acting, move focus
  out of the field or use the equivalent menu/button.
- Number keys intentionally change meaning by study phase: options before
  reveal, grades after reveal. Arrange selection uses Command-number to avoid
  that conflict.
- A disabled command generally means the app is loading, transferring, showing
  another workflow, or lacks the required selection—not that the shortcut is
  broken.

---

**Next:** [Troubleshoot app behavior](../troubleshooting/)

**Related:** [First study session](../first-study-session/) · [Build and support](../support/)
