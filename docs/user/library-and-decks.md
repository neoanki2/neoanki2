---
title: Library and decks
description: Create, nest, rename, select, and safely remove decks while understanding All Decks and Unassigned.
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
- **Unassigned** shows only items with no deck.

Changing scope reloads the scope home and its counts. Sidebar captions show
direct item counts for each named deck and recursive due counts for that deck
and its descendants. **Unassigned** reports its item and due counts separately.
Every count in one reload is measured at the same instant, so the sidebar and
the detail pane always agree.

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

Parents with children appear as disclosure groups. Expand or collapse them to
navigate the hierarchy.

[![Nested decks in the sidebar]({{ site.baseurl }}/assets/screenshots/decks-nested.png)]({{ site.baseurl }}/assets/screenshots/decks-nested.png)

Selecting a parent includes content in every level below it. Selecting a child
limits the list and study session to that child's subtree.

## Rename a deck

1. Control-click or right-click the deck.
2. Choose **Rename**.
3. Edit the name and choose **Save**.

Names cannot be empty after trimming whitespace. Renaming changes the label,
not the deck's items or hierarchy. Choose **Cancel** to retain the old name.

## Delete a deck safely

1. Control-click or right-click the deck.
2. Choose **Delete**.
3. Read the confirmation and choose **Delete Deck**.

Deleting a deck does **not** delete its items or subdecks:

- Items directly in the deleted deck move to its parent.
- If the deleted deck was top-level, its direct items become unassigned.
- Direct subdecks move to the deleted deck's parent.
- If the deleted deck was top-level, its direct subdecks become top-level.

The operation preserves the rest of each nested subtree. Cancel the
confirmation or press Escape to keep the deck unchanged. If the deleted deck
was selected, NeoAnki2 returns to **All Decks**.

## Put new items in a deck

When a named deck is selected, **Add Item** preselects that deck. From **All
Decks** or **Unassigned**, a new item defaults to **Unassigned**. If the
library has decks, use the Deck picker in the add form to choose any deck or
Unassigned before saving.

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
