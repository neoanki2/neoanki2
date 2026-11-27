---
title: Studying
description: Complete due-card sessions, including persistent prompt-only spoken submissions.
audience: user
nav_order: 3
parent: User Guide
---

# Studying

Active study is timed automatically, including skipped cards and unfinished
attempts. The timer pauses after two minutes without interaction. Editing,
saving, hidden windows, and background time are excluded. **View Session Statistics**
opens duration, review counts, cards/items, and response totals in the unified
Statistics screen. Completion itself shows status and actions. Save failures remain visible
after a session ends. See [Learning time](../learning-time/) for counting rules.

Grades and review undo outcomes remain effective across iCloud sync even when
card snapshots arrive late. An older schedule cannot put a completed review
back into the due queue.

Item-type availability controls new-item authoring, not the study queue.
Automatically organizing types or removing a deck attachment preserves existing
cards and their ordering. Moving an item retains its type and scheduling history.

Every active card uses a predefined **Study Stage**. Its flexible card region
yields space to the response and status region, and the fixed interaction or
grading footer reserves its full height with bottom breathing room. By default,
the stage does not scroll or scale. Text that exceeds the available card region scrolls
inside that region while the footer stays visible; visual media receives a finite
height proposal so it can aspect-fit. On Mac, the study window is limited to the visible
screen and keeps clearance above its bottom edge, so every region and the
primary action remain fully visible on short displays. Focus, Split, Media
Aside, Media Hero, and Action Stage compositions rearrange at compact widths
and keep media aspect-fit.

Focus compositions preserve their authored reading order when the answer is
revealed. The question remains first and keeps its study emphasis, the expected
answer appears immediately below it, and supplemental answer details follow.
This keeps poetry and prose continuations in sequence while placing vocabulary
answers before grammar and example metadata. VoiceOver uses the same order.

All five static Card setup layouts use the same content and accessibility order
on Mac, iPhone, and iPad. Before reveal, expected-answer content stays concealed
by purpose even when an imported setup places it in an unusual region. A setup
may also hide supporting content until reveal or blur compatible image and GIF
content; **Show Answer** applies those reveal rules together without changing
the card's place in the session.

Text prompts can opt in to **Fit study area** in the Card setup editor. The
prompt text scales to the available card region on Mac and iPhone, including
when the study window is resized or the phone rotates. **Show Answer** remains
visible, and the revealed answer and its supporting text use their normal
reading size. Existing Card setups keep their current display unless this
option is enabled.

NeoAnki2 builds a study session from cards that are due now in the scope selected in the sidebar. Select **All Decks**, **Unassigned**, or a deck, then choose **Study**. A deck scope includes its descendant decks. The home screen shows the number of cards due, or **You’re caught up** when none are due; future cards are not included.

[![A card prompt before reveal]({{ site.baseurl }}/assets/screenshots/study-prompt.png)]({{ site.baseurl }}/assets/screenshots/study-prompt.png)

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Japanese Academy study path](#japanese-academy-study-path)
- [Session states](#session-states)
- [Study queue order](#study-queue-order)
- [Card interactions](#card-interactions)
- [Feedback and grading](#feedback-and-grading)
- [Fix a card during a session](#fix-a-card-during-a-session)
- [Keyboard and Study menu](#keyboard-and-study-menu)
- [Undo and ending a session](#undo-and-ending-a-session)
- [Motion and accessibility](#motion-and-accessibility)
</nav>

For large libraries of independent cards, loading the first new card now reads
in due order without sorting all new material first. Family, daily-limit, and
ordered-work rules still apply. The first card can be readable while the rest
of the session is preparing; grading waits until that preparation completes.

## Japanese Academy study path

Open **Japanese Academy - Level 1** and choose **Study**. The study session
opens each unread lesson in the supplied course order before introducing its
vocabulary. Scroll through the lesson in its reading pane. **Continue** stays
visible below the lesson and saves your place. Introductory and standalone
lessons are included. You can also study just one chapter or lesson.

Previously introduced vocabulary is reviewed when due. New vocabulary still
follows your daily limits, and reading a lesson doesn't use a new-card slot or
create a grade. When iCloud sync is enabled, the lesson item's reading progress
follows it to your other devices.

Revealing a Japanese Academy vocabulary answer plays the word and sentence
recordings in order. Use **Play Audio** to replay either recording. With
**Reduce Motion** enabled, use the same controls to start playback manually.

## Session states

Mac, iPhone, and iPad use the same session behavior. Loading failures do not
count as completed sessions or erase saved reviews. Choose **Try Again** to
reload a failed session. To leave it, choose **Back to Library** on Mac or
**End** on iPhone and iPad.

The Home count can stay visible while iCloud finishes saving a change. When
you start Study, the session checks current eligibility for the selected scope.

A session moves through a small set of states:

1. **Loading** fetches the due queue for the selected scope.
2. **Prompt** shows the current card and its interaction.
3. **Answer** shows the reference answer and, when available, response feedback.
4. **Grading** saves one rating and advances to the next card.
5. **Skip** moves the current card behind every card already waiting without
   grading it or changing its schedule.
6. **Repair** repeats every failed card after the cards already waiting.
   Consecutive failures remain unresolved and repeat in the same session.
7. **Session Complete** appears after the app checks the selected scope again
   and finds no more eligible due cards. Cards that became due during study
   are added to the same session. The completion screen offers **View Session
   Statistics**, **Undo Last Grade** when available, and **Done**.

After checking a typed answer, choice, or arrangement, **Your answer** stays
visible with the labeled **Answer** section. For a single plain-text answer,
changed words are bold and underlined. Answer-only notes open under
**Explanation**. You still choose your own grade.

The saving indicator covers the local review and next-card preparation. Badges,
reminders, widgets, and iCloud updates continue separately after the review is
saved, so they do not hold the next card's controls. Leaving study refreshes the
Home due counts; progress history is available in Statistics. On iPhone and
iPad, returning later checks local availability before showing a confirmed
empty queue, even when no other device has been used.

After a session adds usable review evidence, an eligible profile continues
tuning its scheduling model silently. This maintenance does not reorder the
finished session or rewrite existing due dates; bounded parameter steps affect
cards only as later study activity schedules them.

The header shows the scope and the number of unresolved cards, such as
“Biology · 7 cards remaining.” Remembering a card reduces the count.
Every Again remains in the count until the card is remembered or you end the session.
The header keeps **Skip** and **End Session** visible beside a **More** menu for
**Edit Card** and **Grade Help**. After a saved grade, the same row shows the
rating with **Undo**, so feedback does not take space away from the fixed action
footer.
The first card appears as soon as its exact due count and content are ready.
NeoAnki2 validates the rest of the initial queue in the background; you can read,
answer, and reveal that first card immediately, while grading, editing, and
skipping become available when queue validation finishes. Every failed card is
due immediately but moves behind cards already waiting. A consecutive Again
returns it to the end of the current session queue again. When no cards are due, the scope home says
**You’re caught up** and tells you when the next card returns, and a session
opened on an empty queue shows **Nothing Due Right Now**.

[![The revealed answer and grading controls]({{ site.baseurl }}/assets/screenshots/study-answer.png)]({{ site.baseurl }}/assets/screenshots/study-answer.png)

## Study extra new cards

When you’re caught up in a deck, choose **Study Extra Cards** on the deck
screen or at the end of its regular study session. The action appears when a
daily new-card limit is holding back cards in that deck or its subdecks.

Choose the number of cards and select **Start Extra Session**. You can use this
one-time override even when the deck’s limit is **0**. Your saved limit still
applies to regular study. Extra cards follow the normal scheduling and spacing
rules, and grades save as you go. If you end early, you can start another batch
from the deck whenever extra cards are available.

## Study queue order

Independent cards use learned-before-new ordering, with learning and repair
positions preserved. Related review cards prefer **five intervening cards** when
alternatives exist; a small deck can still finish every due review.
Large queues use the same spacing rules without searching every remaining card
when the next card is already unrelated to the recent cards.

Ordinary siblings share an item. Saved **Context Example** items share their
language and expression, including examples added in separate batches or decks.
At most **one new related card per study day** is introduced. A learned relative
that is due takes precedence, and reviewing a relative today defers new relatives
until the next study day. These deferrals are applied before daily deck limits;
undoing a review restores the corresponding eligibility.
Home due counts and the study queue use these same eligibility rules, including
after grading or undoing a review.

New cards from a deck export start in creation order. Reviews still take
priority, and daily limits apply across each selected deck and its subdecks.

**Poetry and prose builder cards keep their existing scheduling.** Only eligible
cards enter the session: no future-due, suspended, or daily-limit-excluded parts
are added. Included parts appear in source order even when their due times or
New/Review phases differ. If only parts 2, 5, and 8 are eligible, they appear as
2 → 5 → 8. Each work keeps its existing queue slots, so unrelated cards can still
appear between its parts. Opening cards lead their poem when eligible.

Source order applies separately to each pass, including repair passes. Skip
defers a part to a later pass. The interval variation and related-card spacing
rules for independent cards do not apply to poetry or prose builder cards.

The same eligibility and ordering policies apply on Mac, iPhone/iPad, and local
API study sessions. Stable identifiers break otherwise equal priorities.

Rearranging a deck changes which ancestor scopes include its subtree. New
sessions and completion checks use the current hierarchy.

The session keeps the current pass while you work. If grading places a card back
into Learning, it returns after the rest of the current queue rather than
interrupting the next card. **Skip** also moves the current card to the end, but
does not save a review or remove the card from the remaining count. Editing an
item refreshes its queued cards; deleting a card removes it from the session.
Editing an unrevealed card also refreshes its choices or arrangement. Feedback
for an answer already revealed stays visible while its content is updated.

Changing an Item Type's Card setups can likewise retire cards that no longer
generate. New sessions and completion checks use the reconciled card set.
Surviving Card setups keep their stable card identities, scheduling memory,
and normal learned-before-new queue priority. Choosing a different static
Layout alone does not change queue order.
Card maturity is shown in the library as a separate progress signal. Becoming
Maintaining does not move a card in this queue or alter its due time.

The **Show Answer** control in Item Type Studio is an authoring preview. It
does not reveal a live study card, write review history, or change scheduling;
only a grade saved during a study session changes a card's memory state.

If a card needs more room than the study area provides, choose **Read Full
Card** to open a scrollable reader. It follows the same reveal state, so opening
it before answering does not expose the answer. The response and grading
controls stay within the main study window. Hidden explanations appear only
after reveal, without placeholder rows taking up space beforehand.

A conditional poem opening card asks **Recall the first line.** with the title
and author as its caption. The answer stays hidden until reveal. Opening cards
follow the same learned-before-new queue policy; continuation cards retain
their existing prompts and learned schedules after a whole-poem edit.

The daily new-card allowance also includes first reviews received through
iCloud sync. After synchronization, **All Decks** uses the same remaining
allowance on Mac, iPhone, and iPad; a deferred new card stays out of the ready
queue even if its due date has arrived. Undoing that first review releases
its allowance. See [Daily limits](../library-and-decks/#set-a-daily-new-card-limit).

A review or undo received from another device refreshes the Home due count and
loaded Browse schedules as soon as it is applied. Pending attachment transfers
can continue alongside these updates. Your current study response remains
local while sync works in the background. See [Sync timing](../sync-reminders-widgets/#set-up-icloud-sync).

## Card interactions

Every ordinary review interaction ends with self-grading. Automatic feedback is
guidance, not a grade: you choose from the configured grading controls. By
default those controls are Again, Hard, Good, and Easy. Audio Submission is the
exception: it completes by persisting the response instead.

### Reveal

Read the prompt, recall the answer, then choose **Show Answer**. This is the interaction used by the starter Basic item type.

### Type answer

Enter a response in **Your answer**, then press Return or choose **Check Answer**. Checking ignores case and diacritics, normalizes whitespace, and ignores surrounding punctuation. It compares your response with usable text representations on the answer side. A match shows **Your response matches**; otherwise, NeoAnki2 asks you to compare your response with the answer.

An empty response is not checked. Enter an answer or, on Mac, choose **More → Reveal & Self-Grade** (Right Arrow) to reveal without checking. If the answer side has no checkable text, automatic checking is unavailable and the answer is revealed for self-grading.

[![Typing and checking an answer]({{ site.baseurl }}/assets/screenshots/study-type.png)]({{ site.baseurl }}/assets/screenshots/study-type.png)

### Choose

Select one of the numbered options, then choose **Check Choice**. NeoAnki2 derives up to four options from the card’s answer, item fields, and prompt. Options are reordered consistently for that card. If no usable options can be made, reveal the answer and self-grade.

Press the plain number shown beside an option to select it before reveal.

### Arrange

Select an item and use **Move Up** or **Move Down** until the sequence is correct, then choose **Check Order**. Multi-line answers are split into lines; otherwise answers are split into words, or into characters when only one word is available. If there is nothing usable to arrange, reveal and self-grade.

For keyboard-only ordering, press Command-1 through Command-9 to select one of the first nine items, then Command-Up Arrow or Command-Down Arrow to move it.

### Record

The footer keeps one primary recording action in a stable location: choose **Start Recording**, speak, and choose **Stop Recording** in the same place. Once the recording is ready, that action becomes **Reveal & Compare**. Use the adjacent **Recording** menu to play the temporary recording or record again. If the answer contains reference audio, play that real recording from the answer; otherwise, NeoAnki2 states that reference audio is unavailable and you compare your recording with the written answer. NeoAnki2 never synthesizes a reference voice. On Mac, choose **More → Reveal & Self-Grade** (Right Arrow) when you do not want to record.

The first recording attempt may trigger the macOS microphone permission prompt. If access is denied or restricted, enable NeoAnki2 in **System Settings → Privacy & Security → Microphone**. Recordings are temporary: NeoAnki2 removes them when the card changes, the study view closes, or a new recording replaces the old one.

On iPhone and iPad, tap **Record Answer**, then **Stop Recording**. Tap
**Compare Recording** to reveal the answer once the recording is ready. You
can replay your recording while grading. Choose **Reveal & Self-Grade** to
study without recording.

On Mac, use Command-R to start or stop recording and Command-P to play or
stop playback.

### Audio Submission

Audio Submission cards show only their prompt. The footer presents one primary
action that progresses from **Start Recording** to **Stop Recording**, then to
**Save & Complete** when the draft is ready. Use the adjacent **Recording** menu
to play, replace, or discard a ready draft. Saving persists the validated M4A
and advances.
There is no answer reveal and no grading control; completion creates no review
log and does not update FSRS. The card is suspended only after persistence
succeeds, so an abandoned or failed submission remains due.

The recording is persistent and local-only. It appears under **Library → Saved
Responses** with its source, time, duration, playback, and deletion controls,
and it is excluded from Cloud sync and deck exports. Leaving with a draft asks
for confirmation. A save error keeps the draft available for retry. Retrying
the same save safely reuses the completed response if the first confirmation
was interrupted, rather than creating a duplicate. Recordings stop automatically
at 30 minutes and remain subject to the 20 MB audio limit.

### Cloze

Cloze cards show the surrounding text while concealing only the blank for the current cloze group. Choose **Show Answer** to reveal that blank. Distinct cloze groups generate distinct cards, so one cloze item can contribute several cards to a session.

Vocabulary sets schedule two cards independently. The recognition card shows
the target word in its example sentence and asks you to recall its meaning
before revealing it. The production card hides the exact form in the sentence
with a native Cloze blank and uses the saved meaning as a cue. Type the
missing word to compare your answer with the original form before grading.

Successful meaning reviews count toward [Known Words](../authoring-items/#known-words-and-vocabulary-card-sets).
Suspending a vocabulary card keeps the evidence it has earned. A word that is
known from mature reviews stays known after you delete its card set.

## Feedback and grading

After reveal, NeoAnki2 may show:

- **Your response matches** for an automatically checked match.
- **Compare your response with the answer** for a mismatch.
- **Automatic checking wasn’t available** when the answer cannot be checked.

These messages do not choose a rating. Grade based on the quality of your recall:

- **Again (1):** you did not remember. The card stays in the current session
  and returns after the cards already waiting, even after consecutive failures.
- **Hard (2):** you remembered with difficulty. FSRS may schedule another
  review later the same day.
- **Good (3):** you remembered correctly.
- **Easy (4):** recall was too easy; allow a longer wait.

Open **More ▸ Grade Help** in the session header for the same guidance.

For a simpler choice, open **Settings → Study** and enable **Use Fail / Pass
grades**. Study sessions then show only **Fail (1)** and **Pass (2)**. Fail is
saved and scheduled exactly as Again; Pass is saved and scheduled exactly as
Good. This is a device-local display preference and does not change the
scheduler or rewrite earlier reviews.

[![Grade Help explains the four ratings]({{ site.baseurl }}/assets/screenshots/study-grade-help.png)]({{ site.baseurl }}/assets/screenshots/study-grade-help.png)

NeoAnki2 uses a native Swift implementation pinned to its documented upstream
FSRS-6 reference. Each saved rating updates the card’s estimated difficulty
and stability, and the next due date uses the active preset's retention target;
the product target is fixed at 90%. Again
marks one lapse when a review card enters relearning; repeated failures during
that repair sequence do not add more lapses. Hard reduces growth; Easy can
increase it. Every failure returns for immediate repair at the end of the
current session queue.
After eight lapses, the scope home can surface the card's item for attention.
Marking that item OK does not grade the card or change this history; it only
hides the warning until the card records another lapse.
After recall, FSRS keeps fractional-day precision and may choose an intraday
review when the memory state calls for it. Elapsed time comes from the exact
review timestamps, so multiple reviews on the same calendar day still use
their real fractional-day gaps instead of being rounded down to zero days.
Longer review intervals depend on
the card’s history, elapsed time, scheduler parameters, desired retention, and
configured maximum interval. Successful recall on independent cards applies
**±15% interval variation** to prevent cards learned together from remaining
synchronized. The numerical FSRS memory estimate stays unchanged. Variation is
reproducible for each card and review; saved due dates stay unchanged until a
new grade. Poetry and prose builder cards retain their precise FSRS intervals.

## Fix a card during a session

If a card reports that a media file cannot be read, follow
[media troubleshooting](../troubleshooting/#item-and-media-errors).
The same saved attachment is used in item detail and during study.

Reviewing is when card problems surface: a typo, a missing detail, a definition
that needs more context. Choose **More ▸ Edit Card** in the session header, choose
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
- Space or Return: continue with the primary action before reveal. After reveal,
  Space grades Good.
- 1, 2, 3, 4: grade Again, Hard, Good, or Easy after reveal. With Fail / Pass
  grades enabled, 1 selects Fail (Again) and 2 selects Pass (Good).
- Right Arrow: reveal without checking for Type, Choose, Arrange, or Record.
- Command-E: edit the card you are reviewing.
- Command-Z: undo the last saved grade while undo is available.
- Escape: end the session immediately.

Interaction-specific shortcuts are described above. Shortcuts are enabled only when their corresponding action is valid, which prevents grading before reveal or comparing a Record card before recording.

## Undo and ending a session

When **Session Complete** appears, choose **Done** to return to the library.
Choose **View Session Statistics** to inspect active time, linked reviews,
distinct cards and items, and saved responses. These reports use the same
shared Activity view on Mac, iPhone, and iPad.

After a grade is saved, a compact notice in the session header identifies the rating. Choose **Undo** or press Command-Z to revert that latest review and return to the same card with its answer revealed. You can dismiss the notice; completing another grade replaces the previous undo opportunity. **Undo Last Grade** also appears on the completion screen when the final grade can still be reverted.

[![The completed-session summary]({{ site.baseurl }}/assets/screenshots/study-complete.png)]({{ site.baseurl }}/assets/screenshots/study-complete.png)

Choose the visible **End Session** button or press Escape to leave immediately.
Saved grades remain saved, and the current ungraded card stays due. If a Record
or Audio Submission draft has not been saved, ending discards that draft.

## Motion and accessibility

NeoAnki2 respects macOS **Reduce Motion**. With it enabled, answer reveals and study-layout changes occur without the normal transition animation.

Controls have spoken labels and state values for VoiceOver, including progress, selected choices and arrangement items, concealed or blurred content, grade meanings, and recording failures. When an answer is revealed, NeoAnki2 announces it and moves accessibility focus to the answer. Recording and other errors are announced and focused. Hidden media is not loaded before reveal, and concealed content is described without exposing its answer.

## Study image occlusion

Each mask group is a separate scheduled card. The numbered outline marks the
region or regions to recall. In **Hide all, reveal one**, other groups remain
covered after **Show Answer**. In **Hide one, reveal one**, the other groups
are visible from the start. Answer text attached to the tested regions appears
only after reveal. Grade recall with the normal Again/Hard/Good/Easy controls.
