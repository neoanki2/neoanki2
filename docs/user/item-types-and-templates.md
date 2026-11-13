---
title: Item Types and Card Setups
description: Define reusable fields and fill the static layouts that generate accessible study cards.
audience: user
nav_order: 4
parent: User Guide
---

# Item Types and Card Setups

Learning-time history belongs to the studied item, rather than a generated card
or Card setup definition. Regenerating cards for a surviving item preserves its
time. Editing item types or Card setups is excluded from active study timing.
See [Learning time](../learning-time/).

An **item type** defines the fields that store one piece of knowledge. Its
**Card setups** decide which fields appear on a study card, which of five
static layouts presents them, and how the learner answers. The saved data model
calls a Card setup a `Template`; the friendlier name is only a change in the
app's interface.

Open **Item Types** on Mac, or **Create → Item Types & Card Setups** on iPhone
and iPad. The Item Type Studio edits fields and Card setups together and saves
the complete definition as one change.
Each generated card has its own maturity status. Editing a Card setup preserves
that status when the card identity survives reconciliation; a newly generated
card starts Not started. Sync repairs stale schedules on surviving cards from
their review history without replacing their Card setups or suspension settings.

Due counts, including the app icon badge, count generated cards rather than
items. An item with multiple Card setups can therefore contribute more than
one due card. After saving a definition, library refreshes update those counts
to reflect the cards that are currently eligible for study.

Saved item-type definitions use the same [iCloud sync](../sync-reminders-widgets/)
path as items and reviews. Committed edits start an upload after a short debounce;
offline edits remain queued until a connection is available.

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

For dictionary-assisted authoring, include at least two Text or Rich Text
fields. The Add Item editor lets you choose which field supplies the lookup
word and which receives the dictionary text. This does not add or change a
Card setup; the selected item type continues to determine the generated cards.
See [Dictionary lookup](../authoring-items/#fill-fields-from-a-dictionary).

The focused **Add Word** flow uses an existing item type too. Its **Card Setup**
maps dictionary content to that type's fields and saves the mapping for the
dictionary–deck pair. Editing one word does not change that mapping. If a field
is deleted or its type changes, repair the pair's setup before adding again;
the app does not silently redirect content to another field.

## Start with a complete item type

Choose **New Item Type**. A new type already contains required Text fields
named **Front** and **Back** and a valid Reveal Card setup that asks with Front
and answers with Back. Name the type, adjust the fields and setup if needed,
then choose **Save** once for the whole definition.

NeoAnki2 also creates ordinary Basic and Cloze starter types on first run.
Basic uses Front → Back Reveal. Cloze stores marked blanks in a Cloze field and
generates an independently scheduled card for each distinct blank group.
Starter types follow the same edit and deletion rules as custom types.
Generated Poem Line items are edited as one poem on iPhone and iPad, so changing
line order also updates the generated Card setups and their sequence together.
The Prose Deck builder includes a **Prose Unit** type with one Reveal card per
unit. Its stored order and separators reconstruct the passage in the whole-text
editor; changing a unit's cue or answer retires that card and creates a new one.

## Edit fields and Card setups together

An image field can hold a selected or pasted image with no description; the
image description is optional. An image-occlusion item generates study cards
from its masks or groups, so an image without masks does not yet produce cards.
See [Images and image occlusion](../content-and-media/) for attachment,
replacement, and mask-editing steps.

On Mac, Studio takes over the Item Types window while a draft is open. The
library navigator and its Done action return after Save or Cancel with the
previous item type still selected. One compact rail contains the item-type
name, **Card setups**, then **Fields**; the selected card remains visible in the
main canvas without scrolling.

Select content directly on the card to highlight it and open its contextual
controls. At the default window width, use the labeled **Inspector** button for
setup, selected-content, and Advanced settings. On a wide window, the same
inspector stays open as a trailing pane. On iPhone and iPad, select a Card setup
to push the existing stacked editor at the device's adaptive width. System Back
returns to the complete item-type draft without saving it; use the draft's
top-level **Save** or **Cancel** action when the whole definition is ready.

For each field, set:

- **Name:** nonblank and unique within the type, ignoring case.
- **Type:** Text, Rich Text, Number, Audio, Image, Image Occlusion, GIF, Video,
  or Cloze.
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

Card setups control the content inside the Study Stage, not the surrounding
session chrome. On Mac, every layout keeps the shared scope/progress header,
its visible **End Session** control and **More** menu, a fixed response/status region, and the fixed
primary-action or grading footer. The Study Stage reserves those regions and
its bottom padding before giving the remaining space to the static card
composition; it does not scroll or scale the template. Changing a layout
therefore cannot move session actions offscreen or embed them in the authored
card composition.

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
- **Image Occlusion** starts with an Image Occlusion field and creates one
  setup for its mask groups; each generated card conceals the other groups
  while testing one group.
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

Item types and Card setups define both how knowledge is presented and the
stable content cohort used by automatic scheduling. Each generated card keeps
the cohort derived from its item-type and Card-setup identities even when its
item moves between decks. A cohort with too little evidence silently inherits
the global model; once its own history passes the optimizer's evidence and
safety gates, it can use personalized parameters without exposing controls or
changing existing due dates merely because the cohort was created.

## Use item types included with decks

Custom item types belong to decks. Open a deck's settings and choose **Manage
Item Types** to create a type, attach an existing definition, choose a default,
or remove an attachment. Subdecks inherit their parent's choices until you turn
off **Use parent’s types**. An empty custom set uses the types available everywhere.

The Add Item picker shows this deck's types. **Use another type…** opens common
types and explicit reuse from another deck. Reuse links the same definition;
**Make an independent copy** keeps future changes separate. Type changes ask
before clearing entered content. When switching decks, you can attach the current
type and keep the draft, keep the original deck, or clear the draft and choose again.

**Available Everywhere** is a deliberately small collection, initially Basic and
Cloze. Creating a type asks where it belongs. **Make Available Everywhere** is an
explicit action; unlocking an imported definition does not change its availability.
Imported definitions start protected until you unlock or duplicate them.

Existing libraries are organized automatically using imported ownership and item
usage. Types used in several decks retain one linked identity. Unused types and
types used only by unassigned items appear under **Needs Organization**, where you
can attach them to a deck or make them available everywhere. No items, generated
card identities, scheduling, or review history are changed by this organization.

Removing an attachment changes future authoring choices. Existing items stay
editable. Moving an item preserves its type without automatically adding that
type to the destination picker. Deck deletion retains definitions used elsewhere;
orphaned definitions appear under Needs Organization.

Linked definitions display their deck usage. Saving edits that affect multiple
attached decks lists those decks and offers an independent copy. Existing
field-change and generated-card safeguards still apply.

Scope and editing protection sync independently from the definition. Update all
devices to this version before changing type organization; older clients do not
understand the new scope records. Portable format 7 preserves defaults and empty
inheritance overrides, and the importer continues reading supported older formats.
Imported types remain scoped to their decks.

## Repair or delete an item type

If a definition is unreadable, choose **Repair**, then **Archive Original and
Repair**. NeoAnki2 archives the damaged definition, preserves linked items, and
installs a minimal editable replacement with Front, Back, and a Basic Card
setup. Repair cannot reconstruct unreadable custom fields or setups, so inspect
the result before studying.

Delete is available only when no items use the selected editable type. The
confirmation removes the type and all of its Card setups. Included read-only
types must first be unlocked or duplicated according to the outcome you want.

## Save a mobile Studio draft

On iPhone and iPad, Studio keeps field reordering and Card setup changes in one
draft. Open a field to move it, return to the setup, and choose **Save** only
when the complete definition is ready. **Cancel** discards the draft.

The shared editor offers Layout, Answer method, Availability, and Learning
route screens. A Media Aside layout requires a Media component; select a
compatible layout before saving if the setup contains only text. Scroll a
control fully into view before activating it, especially with large text.
