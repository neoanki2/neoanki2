---
title: Library and decks
description: Create, nest, rename, select, and safely remove decks while understanding All Decks and Unassigned.
audience: user
nav_order: 2
parent: User Guide
---

# Library and decks

The sidebar controls which items and due cards appear in the detail area.
Decks organize items without changing their item type or generated cards.

[![A populated library and its item list]({{ site.baseurl }}/assets/screenshots/library-populated.png)]({{ site.baseurl }}/assets/screenshots/library-populated.png)

## Choose a scope

Use one of the three kinds of sidebar row:

- **All Decks** shows every item, including items that have no deck.
- A **deck** shows items in that deck and all of its descendant subdecks.
  Starting a study session here uses the same recursive scope.
- **Unassigned** shows only items with no deck. It appears only while at least
  one unassigned item exists, keeping an empty library sidebar uncluttered.

Changing scope reloads the scope home and its counts. A deck's caption counts the
items and due cards in that deck **and all its subdecks**, which is the same
scope you get by selecting it — so a deck that only organizes subdecks reports
their contents rather than reading as empty. A caption says **No items** only
when the deck and everything under it is empty. **Unassigned** reports its own
item and due counts. Every count in one reload is measured at the same instant,
so the sidebar and the detail pane always agree.

Selecting a scope opens its **scope home**, described below.

## Create a top-level deck

1. Choose the **+** button in the deck sidebar toolbar.
2. Enter a non-empty name.
3. Choose **Create**.

Leading and trailing whitespace is removed. The new deck becomes the selected
scope. Choosing **Cancel** leaves the tree unchanged.

## Create nested decks

1. Control-click or right-click the intended parent deck.
2. Choose **New Subdeck**.
3. Enter a name and choose **Create**.

Parents with children appear as disclosure groups. Use the disclosure triangle
to expand or collapse them. Clicking a parent deck's row selects its scope
without changing whether its children are visible. When a child deck becomes
selected through another action, its ancestors expand so the selection remains
visible in the hierarchy.

[![Nested decks in the sidebar]({{ site.baseurl }}/assets/screenshots/decks-nested.png)]({{ site.baseurl }}/assets/screenshots/decks-nested.png)

Selecting a parent includes content in every level below it. Selecting a child
limits the list and study session to that child's subtree.

## Rearrange decks

Drag a deck to change its position or parent:

- Drop near the top or bottom edge of another deck to insert before or after it.
- Drop in the middle of another deck to make it a subdeck.
- Drop on the **Decks** section heading to move it to the top level.

The insertion line or highlighted folder previews the result before you drop.
NeoAnki2 prevents moves that would put a deck inside itself or one of its own
subdecks. The order and hierarchy persist after relaunching the app.

For a non-drag alternative, Control-click a deck and open **Move**. You can move
it up or down among siblings, out one level, to the top level, or directly into
another eligible deck. VoiceOver exposes move actions on each deck row as well.

## Set a daily new-card limit

1. Control-click or right-click the deck.
2. Choose **Deck Settings…**.
3. Turn on **Limit new cards per day**, choose the allowance, and save.

The setting is one shared allowance for the deck and all of its subdecks. A new
card graded anywhere in that subtree consumes one of the parent's slots. A
subdeck can add a stricter limit of its own; cards there must fit both limits.
Turn the limit off to remove that deck's cap, or set it to **0** to pause new
cards throughout its subtree while continuing scheduled learning and reviews.

Daily limits are local study preferences. They are not included in portable or
authored deck files. See [Scheduling](../scheduling/) for first-grade accounting,
undo behavior, and the configurable study-day rollover.

## Rename a deck

1. Control-click or right-click the deck.
2. Choose **Rename**.
3. Edit the name and choose **Save**.

Names cannot be empty after trimming whitespace. Renaming changes the label,
not the deck's items or hierarchy. Choose **Cancel** to retain the old name.

## Delete a deck

1. Control-click or right-click the deck.
2. Choose **Delete**.
3. Read the confirmation and choose **Delete Deck**.

**Deleting a deck destroys its contents.** It removes the deck, every subdeck
beneath it, every item in any of them, and the study cards those items
generated, along with all review history. Nothing moves to the parent deck, and
there is no undo.

Because a deck's sidebar caption counts its whole subtree, that caption tells
you what you are about to lose. To keep the items, move them out first — open
browse mode on the deck, select them, and use **Move to Deck** — then delete the
empty deck.

Cancel the confirmation or press Escape to keep the deck unchanged. If the
deleted deck was selected, NeoAnki2 returns to **All Decks**.

## Put new items in a deck

When a named deck is selected, **Add Item** preselects that deck. From **All
Decks** or **Unassigned**, a new item defaults to **Unassigned**. If the
library has decks, use the Deck picker in the add form to choose any deck or
Unassigned before saving.

The form asks for **Deck** before **Item Type** because imported decks can
provide purpose-built types. Under **For This Deck**, a declared default is
marked Recommended and selected automatically; a sole included type is also
selected automatically. If several included types have no default, choose one
before entering content. Ordinary reusable types remain available under
**Item Types**, including Basic as an intentional alternative. Types included
only with unrelated decks never appear.

The **Unassigned** empty state intentionally has no Add Item button; use the
toolbar's **Add Item** action instead.

## Read the scope home

Choosing a scope opens its home, which answers one question: is there anything
to study right now?

- The **due count** leads, with **Study** beside it. Studying is one click from
  the moment you pick a scope.
- When nothing is due, the count is replaced by when the next card comes back —
  for example, "The next card is due in 3 hours." There is no disabled Study
  button left sitting there without explanation.
- **Cards** breaks the scope down into **New**, **Learning**, and **Review**.
  Relearning cards count as learning, because relearning is a repair round.
- When a daily limit defers new cards, a note separates today's available new
  cards from the deferred backlog and reports when more become available.
- If cards in the scope keep lapsing, a note says how many. Rewriting a
  confusing item usually works better than repeating it.
- **Browse *n* Items** opens browse mode.

The scope home never shows an item's answer.

## Browse and search items

Open browse mode from the scope home link, from **Library ▸ Browse Items**, or
with ⌥⌘B. Press Escape or choose **Done** to return to the scope home.

Browse mode is a sortable table, one row per item:

| Column | Shows |
| --- | --- |
| Prompt | Content from the item's first field |
| Due | When the item's soonest card is due, or **Now** |
| State | New, Learning, Relearning, or Review for that card |
| Lapses | How many times the item's cards have been forgotten |
| Type | The item type name |
| Cards | How many cards the item generated |
| Answer | Hidden by default — see below |

Click a column header to sort by it; click again to reverse. Items with no
scheduled card group together at one end.

Browse displays up to 500 matching items at a time. The footer reports the
visible item range and current page; use its Previous Page and Next Page buttons
to move through larger result sets. Search and sorting still apply to the whole
scope, then return to the first page of the newly ordered or filtered results.

**The Answer column is hidden on purpose.** Reading an answer before you have
been asked the question spends the review. When you do need to verify content —
proofreading an import, hunting a typo — choose **Library ▸ Show Answer Column**
or press ⌥⌘A, and **Library ▸ Hide Answer Column** when you are done. Your choice
is remembered, so the column stays as you left it the next time you browse.
Control-clicking the table header works too.

Search still matches answer text whether or not the column is visible, so you
can find an item by a half-remembered answer without being shown it.

Use the search field to filter by prompt, answer, or item type. The window
subtitle reports how many of the scope's items are showing.

Double-click a row to open the item. Select several rows to act on them
together:

- **Move to Deck** moves the whole selection, including to **No Deck**.
- **Delete** asks for confirmation and removes the items and their cards.

## Move an existing item

1. Open browse mode and select the item, or open it from the table.
2. In item detail, open the **Deck** menu.
3. Choose another deck or **Unassigned**.

The move happens immediately; there is no separate Save button. Counts and the
current scoped list refresh after the move. If the destination is outside the
active scope, choose the destination scope to find the item.

For several items at once, select them in browse mode and use **Move to Deck**.
