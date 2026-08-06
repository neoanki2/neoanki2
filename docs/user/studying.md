---
title: Studying
description: Complete due-card sessions using reveal, type, choose, arrange, cloze, and record interactions.
nav_order: 3
parent: User Guide
---

# Studying

NeoAnki2 builds a study session from cards that are due now in the scope selected in the sidebar. Select **All Decks**, **Unassigned**, or a deck, then choose **Study**. A deck scope includes its descendant decks. The Study button shows the number due and is disabled when that count is zero; future cards are not included.

[![A card prompt before reveal]({{ site.baseurl }}/assets/screenshots/study-prompt.png)]({{ site.baseurl }}/assets/screenshots/study-prompt.png)

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Session states](#session-states)
- [Card interactions](#card-interactions)
- [Feedback and grading](#feedback-and-grading)
- [Fix a card during a session](#fix-a-card-during-a-session)
- [Keyboard and Study menu](#keyboard-and-study-menu)
- [Undo and ending a session](#undo-and-ending-a-session)
- [Motion and accessibility](#motion-and-accessibility)
</nav>

## Session states

A session moves through a small set of states:

1. **Loading** fetches the due queue for the selected scope.
2. **Prompt** shows the current card and its interaction.
3. **Answer** shows the reference answer and, when available, response feedback.
4. **Grading** saves one rating and advances to the next card.
5. **Repair rounds** repeat failed cards after the current queue until each is
   recalled or you end the session.
6. **Session Complete** reports reviews and unique cards, then offers **Undo
   Last Grade** or **Done**.

The header shows the scope and the number of unresolved cards, such as
“Biology · 7 cards remaining.” Remembering a card reduces the count; grading
Again keeps it unchanged because that card moves to a repair round.
The first card appears as soon as its exact due count and content are ready.
NeoAnki2 validates the rest of the initial queue in the background; you can read,
answer, and reveal that first card immediately, while grading, editing, and
skipping become available when queue validation finishes. Failed cards are due immediately
but move behind cards already waiting. After that queue finishes, each failed
card appears once per repair round. When no cards are due, the scope home says
**You’re caught up** and tells you when the next card returns, and a session
opened on an empty queue shows **Nothing Due Right Now**.

[![The revealed answer and grading controls]({{ site.baseurl }}/assets/screenshots/study-answer.png)]({{ site.baseurl }}/assets/screenshots/study-answer.png)

## Card interactions

Every interaction ends with self-grading. Automatic feedback is guidance, not a grade: you still choose Again, Hard, Good, or Easy.

### Reveal

Read the prompt, recall the answer, then choose **Show Answer**. This is the interaction used by the starter Basic item type.

### Type answer

Enter a response in **Your answer**, then press Return or choose **Check Answer**. Checking ignores case and diacritics, normalizes whitespace, and ignores surrounding punctuation. It compares your response with usable text representations on the answer side. A match shows **Your response matches**; otherwise, NeoAnki2 asks you to compare your response with the answer.

An empty response is not checked. Enter an answer or choose **Reveal & Self-Grade**. If the answer side has no checkable text, automatic checking is unavailable and the answer is revealed for self-grading.

[![Typing and checking an answer]({{ site.baseurl }}/assets/screenshots/study-type.png)]({{ site.baseurl }}/assets/screenshots/study-type.png)

### Choose

Select one of the numbered options, then choose **Check Choice**. NeoAnki2 derives up to four options from the card’s answer, item fields, and prompt. Options are reordered consistently for that card. If no usable options can be made, reveal the answer and self-grade.

Press the plain number shown beside an option to select it before reveal.

### Arrange

Select an item and use **Move Up** or **Move Down** until the sequence is correct, then choose **Check Order**. Multi-line answers are split into lines; otherwise answers are split into words, or into characters when only one word is available. If there is nothing usable to arrange, reveal and self-grade.

For keyboard-only ordering, press Command-1 through Command-9 to select one of the first nine items, then Command-Up Arrow or Command-Down Arrow to move it.

### Record

Choose **Start Recording**, speak, and choose **Stop Recording**. You may play the temporary recording or record again. Once the recording is ready, choose **Reveal & Compare** to reveal the answer while keeping **Play My Recording** available. If the answer contains reference audio, play that real recording from the answer; otherwise, NeoAnki2 states that reference audio is unavailable and you compare your recording with the written answer. NeoAnki2 never synthesizes a reference voice. **Reveal & Self-Grade** remains available as a fallback when you do not want to record.

The first recording attempt may trigger the macOS microphone permission prompt. If access is denied or restricted, enable NeoAnki2 in **System Settings → Privacy & Security → Microphone**. Recordings are temporary: NeoAnki2 removes them when the card changes, the study view closes, or a new recording replaces the old one.

Use Command-R to start or stop recording and Command-P to play or stop playback.

### Cloze

Cloze cards show the surrounding text while concealing only the blank for the current cloze group. Choose **Show Answer** to reveal that blank. Distinct cloze groups generate distinct cards, so one cloze item can contribute several cards to a session.

## Feedback and grading

After reveal, NeoAnki2 may show:

- **Your response matches** for an automatically checked match.
- **Compare your response with the answer** for a mismatch.
- **Automatic checking wasn’t available** when the answer cannot be checked.

These messages do not choose a rating. Grade based on the quality of your recall:

- **Again (1):** you did not remember. The card moves to the next repair round.
- **Hard (2):** you remembered with difficulty. FSRS may schedule another
  review later the same day.
- **Good (3):** you remembered correctly.
- **Easy (4):** recall was too easy; allow a longer wait.

Open **Grade Help** from the question-mark button for the same guidance.

[![Grade Help explains the four ratings]({{ site.baseurl }}/assets/screenshots/study-grade-help.png)]({{ site.baseurl }}/assets/screenshots/study-grade-help.png)

NeoAnki2 uses FSRS-6. Each saved rating updates the card’s estimated difficulty
and stability, and the next due date is calculated for the built-in 90%
retention target. The current app does not expose a retention setting. Again
marks one lapse when a review card enters relearning; repeated failures during
that repair sequence do not add more lapses. Hard reduces growth; Easy can
increase it. Every repair attempt records its actual timestamp and is never
fuzzed or delayed: failed acquisition returns in the next repair round.
After recall, FSRS keeps fractional-day precision and may choose an intraday
review when the memory state calls for it. Longer review intervals depend on
the card’s history, elapsed time, scheduler parameters, and small deterministic
interval variation.

## Fix a card during a session

Reviewing is when card problems surface: a typo, a missing detail, a definition
that needs more context. Choose **Edit Card** in the session header, choose
**Study ▸ Edit Card…**, or press Command-E to open the current card's item in
the same editor the library uses.

1. Correct or extend the fields.
2. Choose **Save**, or **Cancel** to leave the item unchanged.
3. The session stays on the same card and shows the saved content.

Saving behaves exactly like [editing from the
library](../authoring-items/#edit-an-item): the item's type, tags, and deck
assignment are preserved, and generated cards are reconciled, so a card that
still generates keeps its review history. When one item contributes several
cards to the session, every one of them shows the correction. Editing does not
change when a card is next due; only a grade does that. An edit that retires the
current card, such as removing the cloze blank it was generated from, leaves
nothing to grade: the session drops that card and continues when you grade.

The editor shows every field of the item, including the answer side. Opening it
before reveal therefore shows you the answer, and grading remains yours to
choose honestly. A revealed answer stays revealed and keeps its feedback; before
reveal, choices and arrange items are rebuilt from the saved content.

While the editor is open, the study commands are disabled, so the unmodified
grade keys type into the form instead of grading the card behind it.

## Keyboard and Study menu

The **Study** menu mirrors the main actions:

- Command-Shift-S: start studying the current scope.
- Space or Return: continue with the primary action when it is available.
- 1, 2, 3, 4: grade Again, Hard, Good, or Easy after reveal.
- Right Arrow: reveal without checking for Type, Choose, Arrange, or Record.
- Command-E: edit the card you are reviewing.
- Command-Z: undo the last saved grade while undo is available.
- Escape: request the end of the session.

Interaction-specific shortcuts are described above. Shortcuts are enabled only when their corresponding action is valid, which prevents grading before reveal or comparing a Record card before recording.

## Undo and ending a session

After a grade is saved, an undo banner identifies the rating. Choose **Undo** or press Command-Z to revert that latest review and return to the same card with its answer revealed. You can dismiss the banner; completing another grade replaces the previous undo opportunity. **Undo Last Grade** also appears on the completion screen when the final grade can still be reverted.

[![The completed-session summary]({{ site.baseurl }}/assets/screenshots/study-complete.png)]({{ site.baseurl }}/assets/screenshots/study-complete.png)

Choose **End Session** or press Escape to leave early. If you have already reviewed at least one card and more cards remain, NeoAnki2 asks for confirmation and reports the number reviewed. Saved grades remain saved; the current, ungraded card is not saved. Choose **Continue Studying** to cancel. Before any grade, or after the session is complete, leaving does not require that confirmation.

## Motion and accessibility

NeoAnki2 respects macOS **Reduce Motion**. With it enabled, answer reveals and study-layout changes occur without the normal transition animation.

Controls have spoken labels and state values for VoiceOver, including progress, selected choices and arrangement items, concealed or blurred content, grade meanings, and recording failures. When an answer is revealed, NeoAnki2 announces it and moves accessibility focus to the answer. Recording and other errors are announced and focused. Hidden media is not loaded before reveal, and concealed content is described without exposing its answer.
