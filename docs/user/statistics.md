---
title: Statistics
description: Explore study activity, memory, progress, sessions, and future workload in one shared screen.
audience: user
parent: User guide
---

# Statistics

Open **Statistics** from the Mac or iPad sidebar or the iPhone tab bar.
Mac, iPhone, and iPad use the same screen and calculations.
Session completion offers **View Session Statistics**, filtered to that session.
Home and deck screens retain due counts and study actions; reports live here.

## Explore your history

Choose All Decks, Unassigned, or a deck, optionally including subdecks. Choose
Today, 7/30/90 days, Year, All Time, or custom dates. More filters narrows reviews
by item type, card setup, skill, or answer method. Unknown means older evidence
did not record that classification.

- **Overview:** review and distinct-card totals, active learning time, observed
  recall, streaks, annual review/time heatmap, trends, and upcoming scheduled cards.
- **Activity:** review and time trends, cumulative activity, introductions,
  grades, weekday/hour activity, deck/skill/method comparisons, sessions, pace,
  and review history.
- **Memory:** current card progress, recall, Maintaining history, introduction
  cohorts, stability/difficulty/recall/interval/lapse distributions, calibration,
  and cards worth inspecting.
- **Workload:** actual scheduled due dates and backlog, estimated minutes,
  and read-only scenarios.

Select a time bucket, calendar day, grade, or memory histogram category to
inspect details. Hovering keeps following charts in place: the detail line has
reserved space before a value is selected. Chart data tables expose exact values without relying on
color or pointer hover. Chart Export actions save their underlying data as CSV;
the toolbar exports the report's aggregate data.

## What the numbers mean

**Reviews** count completed, non-undone grades, including repeated attempts.
Distinct cards and distinct items are separate counts. A **streak** counts
consecutive study days with at least one review, including Again. Before today's
first review, yesterday's streak remains current until today's rollover ends.
There are no streak freezes, rewards, or daily-goal requirements.

**Observed recall** uses the first spaced review of a card per study day, after
at least one elapsed day. Acquisition and immediate repair attempts are excluded.
Again is a failure; Hard, Good, and Easy are successes. Counts and a 95% interval
show how much evidence supports the percentage. Self-assigned grades describe
your recorded judgment, not an independent examination.

**Active learning time** includes unfinished attempts and follows the existing
[learning-time rules](../learning-time/). Graded-attempt durations are separate:
only usable recorded durations contribute to pace summaries. They are never
added to active time. Prompt/answer splits and linked session review counts
require reviews recorded by updated apps. Cumulative minutes begin with the first
recorded time bucket; earlier review-only history does not imply timed activity.
Lateness comparisons exclude reviews without a recorded prior due date.

**Maintaining** uses NeoAnki's existing progress definition. Cohorts group cards
by their first introduction month and show when they first reached Maintaining;
later regressions do not erase that milestone. Historical progress is shown only
where saved evidence supports it, within the selected dates. Current-state charts
explicitly describe now. Memory histograms exclude suspended cards; the labeled
stability/difficulty density matrix includes all studied cards.

**Estimated remembered cards** sums FSRS recall probabilities over eligible
studied cards. It estimates cards, not a count of independently proven facts.
Stability describes memory durability; difficulty describes how slowly it grows.
Time-of-day patterns describe your activity and do not prove a best study time.

The study calendar has one cell for every day in the selected year. Switch between
review counts and active learning minutes; stronger color means more activity.
Month names run across the top and weekdays stay on the leading edge. Daily cells
stay approximately square; compact screens scroll the chart horizontally. Days
with no activity remain visible, and an empty year is labeled explicitly.

## Dates, moves, deletion, and sync

Study days follow your configured rollover and this device's time zone. Active
segments crossing a boundary contribute only their overlapping duration. Distinct
simultaneous sessions on two devices both count; repeated sync does not duplicate
an event.

By default, historical totals follow the item's current deck. Advanced review
analysis can instead use its recorded deck at study time; active time continues
to follow current item location. Deleted content appears in All Decks under
Deleted Content, outside live deck totals.

Updated apps preserve content-free statistical history when you delete content.
Explicit undo removes the review contribution, while reset preserves completed
activity. No card text, submitted answers, or recordings are copied into
statistics evidence. Older deletion and undo records cannot always be
separated; ambiguous legacy reviews are excluded.

Statistics evidence syncs through its own private iCloud zone. Older apps keep
ordinary library sync but do not record every new measurement. Earlier history
is limited to the evidence saved by those app versions. The definitions in this
guide explain those limits; the Statistics screen has no separate explanatory
footer.

## Workload scenarios

Scheduled cards show **current due dates**, with backlog in today's bucket.
This differs from a simulated forecast, which includes repeated reviews and
forgetting. Estimated minutes use your median usable attempt duration.

Run a 30- or 90-day scenario with configured settings, zero/custom new-card pace,
or a chosen desired retention. Changed scenarios are compared with current
settings. Existing due dates stay fixed; changed retention applies after the
next simulated review. Deck and parent limits, today's consumed introductions,
and finite unseen-card inventory still apply.

Scenarios assume all due work is completed each day. Successful grades use
sufficient applicable history; otherwise remembered responses assume Good.
Acquisition and immediate repair also assume Good. Bands show the 10th–90th
percentile of model outcomes, not guarantees about your future performance.
Scenarios never change actual cards, due dates, or settings, and can be canceled.
