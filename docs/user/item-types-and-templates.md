---
title: Item Types and Card Setups
description: Define reusable fields and fill the static layouts that generate accessible study cards.
audience: user
nav_order: 4
parent: User Guide
---

# Item Types and Card Setups

An **item type** defines the fields that store one piece of knowledge. Its
**Card setups** decide which fields appear on a study card, which of five
static layouts presents them, and how the learner answers. The saved data model
calls a Card setup a `Template`; the friendlier name is only a change in the
app's interface.

Open **Item Types** on Mac, or **Create → Item Types & Card Setups** on iPhone
and iPad. The Item Type Studio edits fields and Card setups together and saves
the complete definition as one change.

[![The Item Types manager]({{ site.baseurl }}/assets/screenshots/item-types.png)]({{ site.baseurl }}/assets/screenshots/item-types.png)

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Start with a complete item type](#start-with-a-complete-item-type)
- [Edit fields and Card setups together](#edit-fields-and-card-setups-together)
- [Fill a static layout](#fill-a-static-layout)
- [Choose an Answer method](#choose-an-answer-method)
- [Use Advanced settings](#use-advanced-settings)
- [Handle changes safely](#handle-changes-safely)
- [Use item types included with decks](#use-item-types-included-with-decks)
- [Repair or delete an item type](#repair-or-delete-an-item-type)
</nav>

## Start with a complete item type

Choose **New Item Type**. A new type already contains required Text fields
named **Front** and **Back** and a valid Reveal Card setup that asks with Front
and answers with Back. Name the type, adjust the fields and setup if needed,
then choose **Save** once for the whole definition.

NeoAnki2 also creates ordinary Basic and Cloze starter types on first run.
Basic uses Front → Back Reveal. Cloze stores marked blanks in a Cloze field and
generates an independently scheduled card for each distinct blank group.
Starter types follow the same edit and deletion rules as custom types.

## Edit fields and Card setups together

On Mac, Studio takes over the Item Types window while a draft is open. The
library navigator and its Done action return after Save or Cancel with the
previous item type still selected. One compact rail contains the item-type
name, **Card setups**, then **Fields**; the selected card remains visible in the
main canvas without scrolling.

Select content directly on the card to highlight it and open its contextual
controls. At the default window width, use the labeled **Inspector** button for
setup, selected-content, and Advanced settings. On a wide window, the same
inspector stays open as a trailing pane. On iPhone and iPad, select a Card setup
to push the existing stacked editor at the device's adaptive width.

For each field, set:

- **Name:** nonblank and unique within the type, ignoring case.
- **Type:** Text, Rich Text, Number, Audio, Image, GIF, Video, or Cloze.
- **Required:** whether every item must contain that value.

Add, rename, change, or remove fields in the draft. Card setup removals are
also drafts: **Undo Remove** restores the latest one until Save. The last Card
setup cannot be removed because every item type must be able to generate a
card.

Save stays reachable when the draft is invalid. Choosing it explains the
problems and moves focus to the first field, Card setup, content entry, or
Advanced rule that needs attention. Cancel closes an untouched existing
definition directly. A new item type always asks before discarding its new
identity and prefilled setup; edited definitions ask when they have unsaved work.

## Fill a static layout

Every Card setup begins with the compact recipe:

**Question → Answer method → Answer**

Choose fields for Question and Answer in the Inspector, then fill any empty
named hole directly on the canvas: **Instruction**, **Question**, **Media**,
**Context**, and **Answer**. Use **Add content** when a filled hole needs another
entry. A source can be a compatible field or **Fixed text**, such as
“Translate:” or “Explain why:”. Source pickers are searchable when the type has
many fields.

Choose one of five code-owned layouts:

- **Focus** emphasizes one question and a compact answer.
- **Split** gives question and answer comparable space.
- **Media Aside** places visual media beside supporting text.
- **Media Hero** gives an image, GIF, or video the dominant region.
- **Action Stage** gives an interactive Answer method room to work.

The initial recommendation is visible, but choosing another layout is sticky.
Later Question or Answer changes may produce a new recommendation; they never
silently replace your chosen layout or Learning route.

[![A fillable Card setup wireframe]({{ site.baseurl }}/assets/screenshots/template-editor.png)]({{ site.baseurl }}/assets/screenshots/template-editor.png)

A hole can contain more than one entry. Select an entry, then use the Inspector
to change its source, move it, duplicate it, or remove it; dragging is not
required. **Show Answer** switches the same canvas from question to revealed
state. Expected answers stay concealed before reveal even if an unusual older
definition placed them in another region.

Playback appears only for compatible media. Reveal and blur controls appear
for content that supports them, and Fixed text can be edited in the Inspector.
The canvas uses deterministic placeholders rather than personal item content
or media and never grades, records, or saves a response.

Older definitions may contain valid placements that do not correspond to a
named hole. They remain ordered under **Additional content** and round-trip
unchanged. Only **Move into named hole** converts one of those entries to the
current canonical placement.

## Choose an Answer method

**Add Card Setup** immediately creates a valid Basic Reveal setup. The adjacent
menu offers recipes that apply to the current fields:

- **Reverse** asks in the opposite direction.
- **Type Answer** compares typed text before self-grading.
- **Visual** uses compatible image, GIF, or video content and can be conditional.
- **Cloze** conceals the current blank in a Cloze field.
- **Audio Submission** saves one private spoken response on this device and
  completes without grading.

The Answer method picker also supports Reveal, Type Answer, Choose, Arrange,
Record, Audio Submission, and Cloze. Choose and Arrange need usable textual
answers. Record is a temporary compare-and-grade exercise. Audio Submission
has no expected answer: converting an existing setup asks before removing its
answer. If you switch back before Save, the Studio restores the stashed answer.

## Use Advanced settings

[![Advanced Card setup settings]({{ site.baseurl }}/assets/screenshots/template-advanced.png)]({{ site.baseurl }}/assets/screenshots/template-advanced.png)

Open **Inspector → Advanced** only when a setup needs conditional generation or
an explicit learning route.

### Availability

Turn on **Availability rule** to generate the Card setup only when a selected
field is present or absent. Start with one rule. Add **All** or **Any** groups
only when several nested rules are necessary. Incomplete field references are
reported before Save. Existing legacy definitions with empty **All** or **Any**
groups are preserved exactly rather than silently normalized.

Availability is useful for optional media: for example, generate a visual card
only when an Image field is present. With no rule, the setup normally generates
for every valid item; Cloze still generates once per distinct blank group.

### Learning route

The stored **Learning route** records input modality, output modality, and the
cognitive operation for generated cards. The Studio may recommend a route from
the current Question and Answer fields. Choose **Use recommendation** to adopt
it explicitly. Existing stored learning metadata remains authoritative until
you do.

## Handle changes safely

Save validates the complete candidate and summarizes consequences before
changing the library:

- Removing or changing a field reports affected populated items.
- Removing a referenced field clears those draft mappings, identifies every
  affected Card setup, and requires repair before Save.
- Removing a Card setup retires only the cards generated by that setup. Cards
  from surviving setup identities keep their scheduling and review history.
- Removing an Audio Submission setup reports the persistent spoken responses
  that will be deleted and requires confirmation.

These checks are performed again during the single save transaction. If the
library changed since confirmation, the save stops instead of applying a stale
authorization. Existing Card setup and content identities, order, conditions,
layout, Answer method, and Learning route remain unchanged when you open and
save without editing them.

## Use item types included with decks

Imported deck-specific schemas appear under **From Decks**, grouped by owning
deck. They start read-only and do not crowd the main editable list. You can
inspect their fields and Card setups.

Choose **Unlock for Editing…** to adopt the same definition. Its identity stays
the same, so existing items and deck policies continue using it. Choose
**Duplicate as Item Type…** for an independent editable copy instead; existing
items keep using the original.

## Repair or delete an item type

If a definition is unreadable, choose **Repair**, then **Archive Original and
Repair**. NeoAnki2 archives the damaged definition, preserves linked items, and
installs a minimal editable replacement with Front, Back, and a Basic Card
setup. Repair cannot reconstruct unreadable custom fields or setups, so inspect
the result before studying.

Delete is available only when no items use the selected editable type. The
confirmation removes the type and all of its Card setups. Included read-only
types must first be unlocked or duplicated according to the outcome you want.
