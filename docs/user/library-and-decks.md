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

Changing scope reloads both the item list and due-card count. Sidebar captions
show direct item counts for each named deck and recursive due counts for that
deck and its descendants. **Unassigned** reports its item and due counts
separately.

The detail title reflects the selected scope. **Study** is enabled only when
that scope has due cards; its badge shows the due count.

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

## Move an existing item

1. Select the item in the list.
2. In item detail, open the **Deck** menu.
3. Choose another deck or **Unassigned**.

The move happens immediately; there is no separate Save button. Counts and
the current scoped list refresh after the move. If the destination is outside
the active scope, return to the list or choose the destination scope to find
the item.

## Understand the item list

Each row shows:

- content from the item's first field as its title
- content from the second field as its subtitle
- the number of generated cards and the item type name

For media fields, the description is used when available; otherwise the media
kind is shown. Cloze text is shown with its blanks concealed. Select a row for
the complete field preview and item actions.
