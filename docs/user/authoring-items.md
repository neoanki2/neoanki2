---
title: Authoring items
description: Create, edit, move, and delete structured study items without losing track of their generated cards.
nav_order: 3
parent: User Guide
---

# Authoring items

An item stores one structured fact or prompt. Its item type determines the
fields you fill in and the templates that generate study cards.

## Add an item

1. Select the destination deck if you want the new item preassigned there.
2. Choose **Add Item** in the empty state or toolbar, choose **File ▸ New Item**,
   or press Command-N.
3. Choose a **Deck** or **Unassigned**.
4. Confirm the recommended type under **For This Deck**, or deliberately choose
   a reusable type under **Item Types**.
5. Complete the required fields.
6. Choose **Save** or press Return when Save is enabled.

[![The Add Item form]({{ site.baseurl }}/assets/screenshots/item-add.png)]({{ site.baseurl }}/assets/screenshots/item-add.png)

The first text-capable field receives keyboard focus. Tab and Shift-Tab move
between controls. A manual item-type change that would clear entered content
asks for confirmation. Changing deck while fields are empty resolves the new
deck's policy; changing deck after entering content retains the current type
and values.

The selected item type is fixed when the item is created. The current UI
cannot change an existing item's type later. To use a different type, create a
new item and delete the old one after checking the result.

## Meet validation requirements

Fields marked **(optional)** may be left empty. All other fields are required,
and whitespace-only text does not count as content. Save remains disabled
until the visible required content is present.

Additional content rules are checked when needed:

- A required number must parse as a numeric value.
- A required cloze field needs text and at least one valid marked blank.
- Every attached image or GIF needs a non-empty image description, even when
  the media field itself is optional.
- A required media field needs an attached file of its declared kind.
- Tags are trimmed, normalized, deduplicated in their original order, and
  limited to 256 non-empty values of at most 1,024 UTF-8 bytes each.

If saving fails, the form remains open and displays an error. Correct the
field and save again.

## Use text and rich text

Text-capable fields provide a native editor and formatting toolbar. Select
text, then toggle **Bold**, **Italic**, **Underline**, **Strikethrough**,
**Highlight**, or **Code**. The **More Formatting** menu adds superscript,
subscript, small/default/large text, adaptive system colors, links, and
**Clear Formatting**. A plain Text field stores ordinary text when no
formatting is used and preserves semantic rich spans when formatting is
applied; a Rich Text field always stores rich spans.

[![Rich-text formatting while authoring]({{ site.baseurl }}/assets/screenshots/item-rich-text.png)]({{ site.baseurl }}/assets/screenshots/item-rich-text.png)

Formatting is native data, not HTML or CSS. See [Content and
media](../content-and-media/) for number, cloze, and media procedures.

## Cancel or discard

While adding a new item, **Cancel** immediately closes the form and discards
the unsaved item.

While editing an existing item:

- **Cancel** closes immediately if nothing changed.
- If fields changed, NeoAnki2 asks **Discard item changes?**
- Choose **Keep Editing** to return to the form.
- Choose **Discard Changes** to restore the saved item and close the editor.

Saving closes the form and refreshes the current library scope.

## Open item detail

Select an item row to open its detail view.

[![An item's detail view]({{ site.baseurl }}/assets/screenshots/item-detail.png)]({{ site.baseurl }}/assets/screenshots/item-detail.png)

The preview displays non-empty fields in item-type order. The first two fields
receive prompt-and-answer emphasis; later fields include their field names.
Below the preview, NeoAnki2 shows the generated card count and item type.

Use the Deck menu here to move the item immediately. Deck assignment is not
part of the edit sheet.

## Edit an item

1. Open item detail.
2. Choose **Edit**.
3. Change field content.
4. Choose **Save**.

A card you are reviewing can be corrected without leaving the session; see [Fix
a card during a session](../studying/#fix-a-card-during-a-session).

Editing preserves the item's type, tags, and deck assignment while rebuilding
field values from the form. Generated cards are reconciled: cards whose
generation conditions or cloze groups still exist preserve their identity and
history, while cards that no longer generate are deleted. Recreating removed
content later creates a new, never-reviewed card. The item type picker and deck
picker are therefore absent. After saving, the detail preview and library row
update.

## Delete an item

1. Open item detail.
2. Choose **Delete**.
3. Confirm with **Delete Item**.

The confirmation states how many generated study cards will also be removed.
Deleting an item removes the item and its generated cards; it cannot be undone.
Append-only review logs are retained when items or cards are deleted, for
history integrity, but no longer belong to an active card. Outcomes that were
not undone can still contribute to later scheduling optimization.
Database migrations and performance indexes do not change this retention rule. An
explicit **Reset All Progress** action in Deck Settings is the exception: it
permanently removes review history for the selected deck subtree.
Local API token verifiers are stored outside the library database and its
snapshots, so restoring library content does not authorize an API client.
Media no longer referenced by any item is eligible for cleanup. Choose
**Cancel** to keep the item.

Deleting a deck is broader, not gentler: it deletes the deck's subdecks and every
item inside them too. See [Delete a
deck](../library-and-decks/#delete-a-deck).
