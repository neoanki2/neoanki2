---
title: Scheduling
description: Understand FSRS grading and safely optimize scheduling after 100 usable review outcomes.
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
set a limit. A limit of **0** pauses new cards in that deck without hiding
learning or review cards.

The allowance belongs to the exact deck that contains each card. When you study
a parent or **All Decks**, each included deck contributes its own allowance;
one deck cannot consume another deck's slots. Unassigned cards remain
unlimited. The scope home keeps **New** as the full backlog while explaining how
many due new cards are available today and how many are deferred.

A new card consumes one slot when you grade it for the first time, including
**Again**. Ending a session before grading does not consume a slot. Undoing that
first grade restores the slot. Learning, relearning, and review cards never
count toward this limit.

Choose **Scheduling → Scheduling Settings…** to set when a new study day begins
in local time. The default is **4:00 AM**. The app follows the Mac's current
time zone, and deferred new cards become available at the next rollover.

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

## Optimize scheduling for your history

Choose **Scheduling → Optimize Scheduling…**. NeoAnki2 fits this profile's FSRS
21 parameters to its saved review outcomes. Saved 19-parameter FSRS-5 profiles
are migrated with the official compatibility mapping: their learned weights
are preserved, short-term decay starts disabled, and the forgetting curve
retains FSRS-5's fixed decay until the next optimization. The menu changes to
**Optimizing Scheduling…** and is disabled until the operation finishes.

Optimization is deterministic and uses review sequences with at least two
valid reviews for a card, beginning with its new-card review. The first review
establishes state; each later review in that sequence contributes one usable
outcome. Invalid or incomplete history is excluded.

When tuning finds a better fit, the result reports:

- how many review outcomes were used; and
- the percentage reduction in log loss, a measure of prediction error.

The current app has no retention control: the target remains the built-in
**90%**, and the maximum interval remains **36,500 days**. Optimization tunes
FSRS weights only. It does not rewrite cards' existing due dates; new parameters
take effect as later grades schedule those cards.

If the existing parameters already fit as well as the optimizer can determine,
NeoAnki2 reports that no change was needed. This is a successful result, not an
error. Existing cards and review history remain in place; only the saved
scheduling parameters for the profile are updated.

Review logs are append-only and survive item/card deletion. Unless a grade was
explicitly undone, outcomes from a deleted studied item can still contribute to
later optimization. Do not create and grade artificial duplicates to influence
the optimizer.

[![Scheduling optimization result showing observations and fit]({{ site.baseurl }}/assets/screenshots/scheduling-result.png)]({{ site.baseurl }}/assets/screenshots/scheduling-result.png)

## Insufficient data

Optimization requires at least **100 usable review outcomes**. This is not
necessarily the same as 100 button presses: a card needs a prior review before
a later review supplies an outcome for fitting.

If there are too few, NeoAnki2 shows **Could Not Optimize Scheduling**, states
the required and currently available counts, and asks you to keep studying and
try again later. Nothing is changed. There is no benefit to fabricating grades
or repeatedly optimizing; grade honestly, allow cards to return over time, and
retry after accumulating more history.

Other optimization failures leave the current parameters unchanged. If the
history cannot produce valid parameters, try again after more normal reviews.
If parameters cannot be saved, close and reopen the app, verify the library
folder is writable, and retry.

## Practical guidance

- Study due cards regularly rather than forcing large one-time sessions.
- Choose the grade that describes recall, not the interval you hope to receive.
- Use **Undo Last Grade** or **Command-Z** immediately after an accidental
  grade; the card and review history are restored.
- Run optimization occasionally after substantial new history, not after every
  session.
- Treat `.neodeck` exports as content exchange, not scheduling backups. To
  preserve progress, back up the whole local library folder.

The 100-outcome threshold and other documented limits are checked against
production constants by the automated [documentation claims registry](../maintaining-documentation/#high-risk-factual-claims).
