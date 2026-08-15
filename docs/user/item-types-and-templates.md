---
title: Item Types and Templates
description: Define reusable fields and templates that generate accessible, interactive study cards.
nav_order: 4
parent: User Guide
---

# Item Types and Templates

An **item type** defines the fields an item stores. Its **templates** turn those fields into study cards: each template chooses what appears on the prompt and answer, how the learner responds, and when the card should exist.

Open **Item Types** from the library to manage both. The left column lists your
editable types first, followed by a **From Decks** section; the detail shows
fields and templates for the selected type.

[![The Item Types manager]({{ site.baseurl }}/assets/screenshots/item-types.png)]({{ site.baseurl }}/assets/screenshots/item-types.png)

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Starter item types](#starter-item-types)
- [Included with decks](#included-with-decks)
- [Create and edit an item type](#create-and-edit-an-item-type)
- [Repair a damaged definition](#repair-a-damaged-definition)
- [Create, edit, and delete templates](#create-edit-and-delete-templates)
- [Choose an interaction](#choose-an-interaction)
- [Build prompt and answer sides](#build-prompt-and-answer-sides)
- [Advanced settings](#advanced-settings)
</nav>

## Starter item types

NeoAnki2 creates two ordinary starter types on first run:

- **Basic** has required Text fields named **Front** and **Back**. Its **Card** template prompts with Front, answers with Back, and uses Reveal.
- **Cloze** has a required Cloze field named **Text** and an optional Rich Text field named **Context**. Its **Cloze** template shows Text with the current blank concealed plus Context on the prompt, then Text on the answer. Each distinct blank group generates a separate card.

Starter types are not protected system definitions. You may edit or delete them under the same rules as a custom type.

## Included with decks

Imported, deck-specific schemas appear under **From Decks**. Each owning deck
has its own disclosure row, labeled with the deck's current path and included
type count. Expand a deck to see its read-only types. They do not crowd the
main editable list.

An included-only definition starts read-only. You can inspect its fields,
templates, and owning deck, but Edit, Delete, and Add Template are unavailable.
Choose **Unlock for Editing…** to adopt that same definition into your normal
Item Types. The confirmation reports how many existing items and decks use it.
Its identity does not change, so those items and the imported deck policy keep
using it; later field and template edits affect all of them.

Choose **Duplicate as Item Type…** instead when you want an independent editable
copy. Existing items and the imported deck policy continue using the original.
If import reused a type that was already a normal Item Type, it remains editable
and appears only in the main list.

## Create and edit an item type

Choose **Add** above the type list. A new draft starts with required **Front** and **Back** Text fields. Enter a type name, then configure each field:

- **Name:** must not be blank and must be unique within the type, ignoring case.
- **Type:** Text, Rich Text, Number, Audio, Image, GIF, Video, or Cloze.
- **Required:** controls whether an item must supply a value for that field.

Use **Add Field** to append another field. Use each row’s arrows to move it up or down, and use the remove control to delete an unreferenced field. These compact row controls provide a consistent click target and remain keyboard reachable. Field order affects item editing, display, and automatic skill derivation. A type edited in the app must retain at least two fields, so remove controls disappear at two.

Save is available only when the type has a nonblank name, at least two fields, and complete, unique field names. A newly created type must also have at least two text-like fields so NeoAnki2 can create its initial **Card** template from the first two of them.

Editing preserves field identities and existing templates. You cannot remove a field used by a template’s prompt, answer, or card-generation condition. Edit or delete those references first. Changing a field type can also make an existing cloze or media configuration invalid; NeoAnki2 reports the validation problem instead of saving an inconsistent definition. If a removed field or type-changed field contains stored content, NeoAnki2 reports the affected item count and requires a separate confirmation before saving.

Cancel closes an unchanged draft immediately. If there are edits, choose **Discard Changes** or **Keep Editing**.

### Delete an item type

The Delete action is available only when no items use the selected type. Delete or move through any dependent items first. Confirmation removes the item type and all of its templates. This applies to starter and custom types alike.

## Repair a damaged definition

If NeoAnki2 cannot read an item-type definition, it keeps other types available and shows the damaged type with **Repair**. Items linked to an unreadable type are skipped until it is repaired.

Choose **Repair**, then **Archive Original and Repair**. NeoAnki2 archives the unreadable definition, preserves the existing items, and installs a minimal editable replacement with required Text fields named Front and Back and a default Card template. The archived source is retained for recovery; repair does not reconstruct custom fields or templates from unreadable data. Review the replacement and existing items before studying. A definition whose identifier itself is invalid requires manual recovery and cannot use this flow.

## Create, edit, and delete templates

Select an item type and choose **Add Template**, or select an existing template to edit it. A template needs:

1. A nonblank name.
2. At least one complete prompt slot.
3. At least one complete answer slot.
4. A valid interaction and, when enabled, a complete generation rule.

Save is disabled until these requirements are met. Cancel asks before discarding edits. Editing an existing template also offers Delete with confirmation; deleting a template can remove cards generated by it and cannot be undone. An item type must always retain at least one template, so its final template cannot be deleted.

[![The template editor]({{ site.baseurl }}/assets/screenshots/template-editor.png)]({{ site.baseurl }}/assets/screenshots/template-editor.png)

## Choose an interaction

The Interaction selector provides seven study experiences:

- **Reveal:** recall mentally, reveal the answer, and self-grade.
- **Type answer:** type a response for automatic comparison, then self-grade.
- **Choose:** select from answer-derived options, check, then self-grade.
- **Arrange:** reorder answer units, check the sequence, then self-grade.
- **Record:** make and optionally replay a temporary audio recording before comparing with the answer.
- **Audio Submission:** record one persistent, local-only spoken response, then
  save and complete without revealing an answer or changing FSRS. Its answer
  side is empty and its skill output is Audio.
- **Cloze:** conceal the current cloze group in the prompt and reveal it with the answer.

Type, Choose, and Arrange depend on usable text representations from the answer side. Record requires microphone permission for recording but always permits reveal-and-self-grade. Audio Submission requires a prompt and clears the answer side after explicit confirmation when converting an existing template. A Cloze template must reference exactly one Cloze field on its prompt side; selecting Cloze automatically changes an always-visible prompt slot for a Cloze field to **Hidden until answer**.

## Build prompt and answer sides

Prompt and answer sides are ordered lists of **slots**. A simple template has one field slot on each side. Select the prompt field that supplies the cue and the answer field that supplies the reference response.

Open **Advanced** to expose source and presentation controls. **Add Prompt Slot** and **Add Answer Slot** build richer sides, and the arrows reorder their elements. A slot may be removed while more than one exists; each side must still contain at least one valid slot when saved.

Slot order matters. It controls the order content is rendered, the first field summarized in the type view, which fields contribute to automatic answer checking, and which first prompt and answer fields are used for automatic skill mapping.

## Advanced settings

[![Advanced template settings]({{ site.baseurl }}/assets/screenshots/template-advanced.png)]({{ site.baseurl }}/assets/screenshots/template-advanced.png)

### Skill mapping

With **Derive from the first prompt and answer fields** enabled, NeoAnki2 maps the first field-backed prompt and answer slots to modalities:

- Text, Rich Text, Number, and Cloze become Text.
- Audio becomes Audio.
- Image and GIF become Image.
- Video becomes Video.

It derives **Recognize** when the prompt field comes before the answer field in the item type, and **Recall** when their order is reversed.

Turn automatic derivation off to choose the skill explicitly. Input and Output offer Text, Audio, Image, Video, Diagram, None, Free response, Selection, Spatial, and Sequence. Operation offers Recognize, Recall, Discriminate, Classify, Locate, Order, Apply, Explain, and Reproduce. Skill mapping describes the cognitive route stored on generated cards; it does not itself change the selected study interaction.

### Field and literal sources

A slot’s **Source** can be:

- **Field:** dynamic content from the current item.
- **Literal text:** fixed wording such as “Translate:” or “Explain why:”.

Every field slot must select a field, and literal text cannot be blank. Literal slots can clarify a multi-part prompt without adding redundant data to each item.

### Multiple slots

Use multiple slots to combine labels, context, and media. For example, a prompt can contain the literal “Name this structure,” an Image field, and a Context field, while the answer can contain Name and Explanation fields. Reorder slots to match the reading sequence.

### Reveal behavior

Each slot can be:

- **Always visible:** shown before and after answer reveal.
- **Hidden until answer:** replaced by a non-revealing placeholder before reveal.
- **Blurred until answer:** images and GIFs are visibly blurred; other content is concealed by a placeholder.

Cloze values are handled specially: the surrounding sentence remains readable while only the current blank is masked. Hidden media is not resolved before reveal, which avoids exposing it to assistive technology or loading it prematurely.

### Media behavior

Audio, GIF, and Video field slots can use **Default**, **Autoplay**, **Play on tap**, or **Loop**. Image fields and non-media or literal slots support Default only. Changing a slot’s source or selecting a field incompatible with the current behavior resets it to Default. Unsupported media behavior prevents an invalid template from being saved.

### Card-generation conditions

Enable **Only generate this card when…** to make a template conditional for each item. Rules can test:

- **Field is not empty**
- **Field is empty**
- **All rules match**
- **Any rule matches**

All and Any can contain nested child rules. Every field rule must select a field, and every All or Any group must contain at least one complete child. If the condition is false, that template generates no card for that item. This is useful for optional media—for example, create a listening card only when Audio is present. Without a condition, the template generates normally for every valid item; Cloze still generates one card per distinct blank group.
