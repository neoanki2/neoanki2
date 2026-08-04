---
title: Scheduling
description: Understand FSRS grading and how scheduling tunes itself after 100 usable review outcomes.
nav_order: 8
parent: User Guide
---

# Scheduling

NeoAnki2 uses FSRS-6 (Free Spaced Repetition Scheduler) to decide when each card
is due. You do not set an interval while studying. Instead, reveal the answer
and describe your recall:

- **Again (1):** you did not remember. The card remains due immediately and
  enters the session's repair queue.
- **Hard (2):** you remembered with difficulty. FSRS may schedule the next
  review later the same day.
- **Good (3):** you remembered correctly.
- **Easy (4):** it was too easy; wait longer before the next review.

Each grade updates that card's memory state and appends a review outcome. A new
or newly imported card starts never-reviewed and is due immediately. Portable
and authored deck imports do not carry scheduling history.

## Limit new cards per day

To pace unfamiliar material, Control-click a deck, choose **Deck Settings…**,
and turn on **Limit new cards per day**. Existing decks are unlimited until you
set a limit. A limit of **0** pauses new cards in that deck and its subdecks
without hiding learning or review cards.

The allowance is shared by the deck and its entire subtree. When you set a
parent deck to 20, at most 20 new cards total are available from that parent and
all of its subdecks that study day. A subdeck can add a stricter limit of its
own; cards in that subdeck must fit both allowances. Unassigned cards remain
unlimited. The scope home keeps **New** as the full backlog while explaining
how many due new cards are available today and how many are deferred.

Deck-included item types affect which fields and templates are offered while
authoring; they do not create a separate allowance. New cards generated from
those types consume the destination deck's existing daily allowance in the
same way as cards from ordinary Item Types.

A new card consumes one slot when you grade it for the first time, including
**Again**. Ending a session before grading does not consume a slot. Undoing that
first grade restores the slot. Learning, relearning, and review cards never
count toward this limit.

Choose **Scheduling → Scheduling Settings…** to set when a new study day begins
in local time. The default is **4:00 AM**. The app follows the Mac's current
time zone, and deferred new cards become available at the next rollover.

## Reset a deck's progress

Control-click a deck, choose **Deck Settings…**, then choose **Reset All Progress…**
to return every card in that deck and its subdecks to New. NeoAnki2
shows a destructive confirmation before committing the reset. Items, deck
settings, and suspended-card state are preserved; review history and the
schedule derived from it are permanently removed for the affected cards. The
operation cannot be undone, so back up the library first when that history
matters.

Learning and relearning use criterion-based **repair rounds**, not fixed minute
intervals. NeoAnki2 finishes the current queue, then shows every failed card
again. Again moves that card to the end of the next repair round; Hard, Good,
or Easy lets it graduate. Rounds continue until every card is recalled or you
end the session. Unfinished cards stay due immediately for the next
session. Repair rounds are an acquisition policy, not a fixed-time learning
step: they deliberately do not wait. After successful recall, FSRS-6 chooses
the next due time from the card's stability. That due time keeps fractional-day
precision, so a weak short-term memory can return in hours while established
memories normally return in days or longer.

## Optimization happens on its own

There is no **Optimize Scheduling** command, and you never need to remember to
run one. NeoAnki2 fits this profile's FSRS 21 parameters to its saved review
outcomes by itself, at the end of a study session, whenever accumulated history
has grown enough for a new fit to mean anything. Saved 19-parameter FSRS-5
profiles are migrated with the official compatibility mapping: their learned
weights are preserved, short-term decay starts disabled, and the forgetting
curve retains FSRS-5's fixed decay until the next optimization.

Nothing is announced. A better fit changes only how later grades schedule cards,
which is not something to acknowledge mid-study, and a fit that cannot be made
leaves the working parameters in place. The end of a session looks the same
either way.

Optimization is deterministic and uses review sequences with at least two
valid reviews for a card, beginning with its new-card review. The first review
establishes state; each later review in that sequence contributes one usable
outcome. Invalid or incomplete history is excluded.

The current app has no retention control: the target remains the built-in
**90%**, and the maximum interval remains **36,500 days**. Optimization tunes
FSRS weights only. It does not rewrite cards' existing due dates; new parameters
take effect as later grades schedule those cards. Existing cards and review
history remain in place; only the saved scheduling parameters for the profile
are updated.

Review logs are append-only and survive item/card deletion. Unless a grade was
explicitly undone, outcomes from a deleted studied item can still contribute to
later optimization. Do not create and grade artificial duplicates to influence
the optimizer.

[![Library after a study session, with no optimization prompt]({{ site.baseurl }}/assets/screenshots/scheduling-result.png)]({{ site.baseurl }}/assets/screenshots/scheduling-result.png)

## When a fit is attempted

Fitting requires at least **100 usable review outcomes**. This is not
necessarily the same as 100 button presses: a card needs a prior review before
a later review supplies an outcome for fitting. Below that, sessions end without
a fit and nothing changes.

Past the first fit, NeoAnki2 refits when review history has grown by **25%**
since the previous attempt, with a floor of **50 new reviews** so a small
library is not refitted constantly, and after **30 days** once any new history
exists. Unchanged history is never refitted: the same reviews cannot produce a
different answer, however long ago they were read.

Because this is automatic, there is nothing to retry and no benefit to
fabricating grades. Grade honestly and let cards return over time. If a fit
cannot be made from the available history, or its result cannot be saved, the
parameters already in use continue to schedule normally and a later session
tries again.

## Practical guidance

- Study due cards regularly rather than forcing large one-time sessions.
- Choose the grade that describes recall, not the interval you hope to receive.
- Use **Undo Last Grade** or **Command-Z** immediately after an accidental
  grade; the card and review history are restored.
- Treat `.neodeck` exports as content exchange, not scheduling backups. To
  preserve progress, back up the whole local library folder.

The 100-outcome threshold and other documented limits are checked against
production constants by the automated [documentation claims registry](../maintaining-documentation/#high-risk-factual-claims).
