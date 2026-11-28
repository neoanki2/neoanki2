---
title: Authoring items
description: Create, edit, move, and delete structured study items without losing track of their generated cards.
audience: user
nav_order: 3
parent: User Guide
---

# Authoring items

After a successful save, a refresh or device-update warning does not mean the
item must be saved again. Refresh the library first. Selection moves preserve
content edits made after selection, and reject the entire move if any selected
item changed its deck assignment. Item detail can show a maturity warning while
keeping its fields available.

Updated apps retain content-free statistical evidence when an item or generated
card is removed. Explicit undo excludes a review; deleting content preserves
completed activity under **Statistics**. No card text, submitted answers, or
recordings are copied into this evidence. See [Statistics](../statistics/).

Deleting an item also preserves its recorded learning time under **Deleted
Content** in All Decks. Moving an item transfers its previous time to the current
deck, and regenerating its cards preserves that history. Time spent authoring or
editing is excluded. See [Learning time](../learning-time/).

An item stores one structured fact or prompt. Its item type determines the
fields you fill in and the Card setups that generate study cards.

With [iCloud sync](../sync-reminders-widgets/) enabled, a committed save starts
syncing within a short upload window. Another active device refreshes its loaded
Browse rows when the change arrives, even while attachments are still downloading.
Offline edits remain queued locally. Browse refreshes saved items against your
current search text and sort order.

## Known Words and vocabulary card sets

Open **Library → Known Words** and choose the language you’re learning. Known
Words tracks each language separately and lists each dictionary headword once.
A saved dictionary form or an unambiguous match in an installed pack can group
forms such as *пагорків* and *пагорок*. You can find the row by searching either
its headword or a saved form. On Mac, open the filter menu to switch between
**Known**, **Learning**, **Not known**, and **Ignored**. The menu counts headwords
for the selected language.

Use **Add Word** and choose **Mark Known** to record a word or phrase you already
understand. You can also mark words from
[Chrome Reading Mode](../chrome-companion/#use-reading-mode).

Choose **Create Cards** in **Add Word** to practice a term in context. Give it a short
meaning and a sentence containing the term. **Understand in context** asks
what the highlighted term means. **Complete the sentence** hides the exact
occurrence from the sentence with a native Cloze blank. Recall the missing form
aloud or type it to compare, then choose your grade. Both cards have their own
review schedules.

Words can become **Known · From reviews** after spaced, successful meaning
recall. **Cloze recall** reflects production separately. Known words from
deleted card sets stay known and show **Kept from deleted cards**.
Japanese Academy recognition cards saved as Vocabulary Sets contribute to
**Japanese**. Unlearned course words start in **Learning**, and successful
spaced reviews can move them to **Known**.

Choose **Known**, **Learning**, **Not known**, or **Ignored** above the list to
see each group. Open a word's actions to correct it: **I Know This**, **Remove
from Known**, or **Ignore** for names, brands, and loanwords you don't want
highlighted while reading. **Use Review History** discards your judgment and
returns the word to the automatic estimate. **Undo** reverses the last change.

**I Know This** marks the word itself, so it counts as known in every meaning.
A card set still practices the meaning you gave it.

Use **Word List → Import Word List…** to add a text, CSV, or TSV file with one
word or phrase per line, or **Paste Word List…** to paste one. The preview shows
how many words will be marked known and which lines were skipped. A CSV or TSV
file with a header row can also set `judgment`, `sense`, and `lemma` columns.
After importing, choose **Undo** to reverse the whole import. **Export Word
List…** saves the selected language as a CSV file you can import again.

For Vocabulary Sets with examples, **Add Word** can create a set or append to
a matching set in the same deck. Choose Recognition, Cloze, or both for the
example. Edit its **Examples** list to update the sentence or its card choices.
Each generated card retains its schedule when its row and blank group are kept.

## Add an item

1. Select the destination deck if you want the new item preassigned there.
2. Choose **Add Item** in the empty state or toolbar, choose **File ▸ New Item**,
   or press Command-N.
3. Choose a **Deck** or **Unassigned**.
4. Choose from this deck’s item types. Use **Use another type…** to attach a
   common type, link one from another deck, or create a type for this deck.
5. Complete the required fields.
6. Choose **Save** or press Return when Save is enabled.

After saving, the deck overview includes the cards generated by the item.
An item can generate several cards or, for a standalone course lesson, none.

[![The Add Item form]({{ site.baseurl }}/assets/screenshots/item-add.png)]({{ site.baseurl }}/assets/screenshots/item-add.png)

The first text-capable field receives keyboard focus. Tab and Shift-Tab move
between controls. A manual item-type change that would clear entered content
asks for confirmation. Empty drafts resolve the destination deck's types. If
a populated draft's type is unavailable in another deck, choose **Attach Type
and Keep Content**, **Keep Original Deck**, or explicitly clear the content.

The selected item type is fixed when the item is created. The current UI
cannot change an existing item's type later. To use a different type, create a
new item and delete the old one after checking the result.

## Learn a word or phrase in context

Choose **Create → Add Word** on iPhone or iPad, or **File → Add Word…** on
Mac. Inside a deck, **Add Word** uses that deck as the destination. From **Known
Words → Add Word**, choose **Create Cards**.

1. Enter a word or phrase and choose its learning and meaning languages.
2. Choose **Find Examples** to search installed packs. Choose a dictionary
   meaning and example if more than one matches. For Ukrainian, the updated
   СУМ-11 pack provides literary quotations and their citations.
3. Check the meaning, the exact form to blank, and the Cloze preview. Choose a
   deck or **Unassigned**, then choose **Add Cards**.

You can enter a sentence and meaning yourself. When the dictionary has no usable
sentence, **Generate Example** uses Apple Intelligence on supported devices and
languages. Generated examples are labeled in the preview. The selected source
is saved with the item.

Existing **Context Example** items remain editable and studyable, with their
audio and review history. They follow the [related-card scheduling rules](../studying/#study-queue-order).

## Create image occlusion items

Choose the **Image Occlusion** starter in Item Types, then create an item of
that type. Its focused image editor supports drawing and grouping rectangular
masks, both masking modes, and card previews. See [Image occlusion](content-and-media.md#image-occlusion)
for the complete authoring workflow.

## Meet validation requirements

Fields marked **(optional)** may be left empty. All other fields are required,
and whitespace-only text does not count as content. Save remains disabled
until the visible required content is present.

Additional content rules are checked when needed:

- A required number must parse as a numeric value.
- A required cloze field needs text and at least one valid marked blank.
- Image, GIF, and image occlusion descriptions are optional; adding one supplies
  a more informative accessibility label.
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

Discarding a draft attachment keeps the same image if a saved item uses it,
including an item received through sync.

While adding a new item, **Cancel** immediately closes the form and discards
the unsaved item.

While editing an existing item:

- **Cancel** closes immediately if nothing changed.
- If fields changed, NeoAnki2 asks **Discard item changes?**
- Choose **Keep Editing** to return to the form.
- Choose **Discard Changes** to restore the saved item and close the editor.

Saving closes the form and refreshes the current library scope. On iPhone and
iPad, local due counts update separately from the broader library and maturity
summary, so those later updates do not hold the Study action.

## Add a word quickly

Open **Add Word**, then choose **Use Custom Item Type…** to map dictionary
content into a deck's existing item type. The form carries over the word and
selected deck. If you leave the deck unassigned, the last dictionary–deck pair
is restored.

1. Choose a deck and an installed dictionary, then type or paste a word or phrase.
2. On first use of a pair, choose **Set Up**. Select one of this deck’s item types and
   choose the content for each field: typed word, dictionary headword/form,
   pronunciation text/audio, meaning, example, or content you enter yourself.
   Look up a word first to see actual examples and supplied pronunciation variants.
3. Save the setup. A unique relevant match prepares the fields automatically;
   choose the relevant entry, meaning, or pronunciation when several are supplied.
4. Edit the prepared fields or fill required content, then choose **Add**.
   Optional fields are under **More details**. The sheet stays open with an empty
   word input so you can add another word; choose **Done** to finish.

The app remembers each dictionary–deck combination separately on this device.
Choosing a deck restores its last dictionary; choosing a dictionary keeps the
current destination deck. Renames preserve the setup. Deleted or changed fields
require reviewing the mappings. Edits to one word do not alter the saved setup.

For example, a pronunciation field can receive just the dictionary’s stressed
spelling or IPA rather than a complete dictionary entry. Meaning and example
fields receive their selected content separately. Required fields still need
values; the app does not invent missing meanings, examples, or pronunciations.

Lookup uses installed dictionaries and works offline. Import a dictionary from
the capture sheet if needed, or use **Enter Manually** when no suitable entry is
available. On Mac, arrow keys navigate matches, Return chooses a highlighted
match, **Command-Return** adds a valid word, and Escape requests closing the sheet.

## Fill fields from a dictionary

Choose **Add Word → Use Custom Item Type…** to set up an installed
dictionary and a deck's item type, then map dictionary content
to its fields. The app remembers that setup for the dictionary–deck pair.
Standard **Add Item** uses the selected type's fields directly and has no
dictionary lookup section. See [Add a word quickly](#add-a-word-quickly) and
[item types](../item-types-and-templates/#choose-an-answer-method).

## Open item detail

Select an item row to open its detail view.

[![An item's detail view]({{ site.baseurl }}/assets/screenshots/item-detail.png)]({{ site.baseurl }}/assets/screenshots/item-detail.png)

The preview displays non-empty fields in item-type order. The first two fields
receive prompt-and-answer emphasis; later fields include their field names.
On iPhone and iPad, field names label the reading sections.
Below the preview, NeoAnki2 shows the generated card count, item type, and
each card's maturity status. These statuses describe long-term recall and do
not reveal a card's answer before study.

Use the Deck menu here to move the item immediately. Deck assignment is not
part of the edit sheet.

## Edit an item

Edit a Japanese Academy lesson from its item detail in the Library. Keep the
reading and its vocabulary in the same lesson deck so Study can put the
reading before the associated new cards.

1. Open item detail.
2. Choose **Edit**.
3. Change field content.
4. Choose **Save**.

A card you are reviewing can be corrected without leaving the session; see [Fix
a card during a session](../studying/#fix-a-card-during-a-session).

Editing an item generated by the Poem builder opens **Edit Poem** instead of the
single-item form. Edit the canonical poem source, keeping the same nonblank line
count and using blank lines only for stanza boundaries. Choose **Preview
Changes** to inspect every prompt, answer, and stanza-spacing update, then
**Save Changes** to apply the coordinated repair atomically across the deck.
The preview also reports inconsistent stored context that the save will repair.
Changing the poem's line count is not supported yet.

For a generated **Prose Unit** item, **Edit Card** opens the whole passage.
Review the updated cues before saving. You may insert, remove, or revise units;
cards with unchanged cues and answers keep their review history. New or changed
units receive new cards, and unused cards are retired. The editor keeps
manually adjusted boundaries in paragraphs whose text did not change.

For other item types, editing preserves the item's type, tags, and untouched
field values, including formatting and language metadata. On Mac, use the
item detail's Deck menu to move the item; on iPhone and iPad, the ordinary
editor also offers a Deck picker. The item type stays fixed. Generated cards
are reconciled: cards whose generation conditions or cloze groups still exist
preserve their identity and history, while cards that no longer generate are
deleted. Recreating removed content later creates a new, never-reviewed card.
After saving, the detail preview and library row update.

Save shows progress while storing the change and prevents a second submission.
A successful save can finish before counts, badges, reminders, or widgets
refresh. A refresh warning does not mean the stored edit failed; reopen the
item to inspect the saved content instead of creating another copy.

## Delete an item

1. Open item detail.
2. Choose **Delete**.
3. Confirm with **Delete Item**.

The confirmation states how many generated study cards will also be removed.
Deleting an item removes the item and its generated cards; it cannot be undone.
Append-only review logs are retained when items or cards are deleted, for
history integrity, but no longer belong to an active card. Historical assignment snapshots keep retained outcomes attributable to their original
item type and Card setup cohort after deletion. Outcomes that were not undone
can therefore still contribute to global and attributable cohort optimization.
Database migrations and performance indexes do not change this retention rule. An
explicit **Reset All Progress** action in Deck Settings starts a new scheduling
history origin for the selected deck subtree. Earlier immutable review evidence
is retained for audit and sync integrity but is excluded from replay, previews,
and future optimizer input after that origin, including after the original card
or item is deleted.
The deck-order migration only adds a persistent sibling position used by the
sidebar. It does not rewrite items, cards, or append-only review outcomes.
Local API token verifiers are stored outside the library database and its snapshots,
so restoring library content does not authorize an API client.
Choosing **Mark Selected OK** in the repeated-lapse Browse filter does not edit
the item or rewrite its review history. It stores only an acknowledgement of
each affected card's current lapse count; a later lapse makes the item need
attention again, and resetting progress clears the acknowledgement.
The one-shot template-definition migration likewise preserves item, card,
review-log, saved-response, and media identities; it changes only the item type's
validated composition definition and its derived revision records.
Daily new-card introductions are reconstructed from retained first-review
evidence when upgrading an older library. This restores the consumed
allowance without creating new reviews or changing card maturity. New synced
reviews carry the original introduction deck and study day; deleting or moving
an item does not rewrite that historical quota context.

Media no longer referenced by any item is eligible for cleanup. Choose
**Cancel** to keep the item.

Deleting a deck is broader, not gentler: it deletes the deck's subdecks and every
item inside them too. See [Delete a
deck](../library-and-decks/#delete-a-deck).

Custom item type setup offers **Use another type…** for explicit reuse. An existing
pair mapping remains readable if its type is later detached from the deck;
detaching does not rewrite stored field mappings or existing words.
