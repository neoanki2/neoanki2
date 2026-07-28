---
title: Concepts and glossary
description: Understand how knowledge becomes independently scheduled retrieval cards in NeoAnki2.
nav_order: 20
parent: User Guide
---

# Concepts and glossary

NeoAnki2 separates what you know, how you practice it, and when you practice it.
The shortest useful model is:

```text
Item type defines fields and templates
                  ↓
Item fills those fields with one piece of knowledge
                  ↓
Each applicable template generates one card
                  ↓
Each card keeps its own reviews, memory state, and due date
```

## The model in one example

A Basic item can store Front = “Capital of France” and Back = “Paris.” Its
starter template turns those fields into one reveal card. If an item type has
two applicable templates, one item can generate two cards—for example,
country → capital and capital → country—and each card is scheduled
independently.

A deck does not generate cards or choose their review intervals. It groups
items, defines a scope for browsing and studying, and can optionally throttle
how many of its own new cards are introduced each study day. A parent deck's
scope includes its descendant decks.

## Glossary

**Item**  
One structured piece of knowledge. It stores field values and optionally
belongs to a deck.

**Item type**  
The reusable schema for items: which fields they contain and which templates
can generate cards. Basic and Cloze are starter item types, not special
hard-coded subjects.

**Field**  
One named value in an item, such as Front, Back, image, audio, number, or cloze
text. A field definition sets its content type and whether it is required.

**Template**  
A data recipe that selects a prompt, an answer, and an interaction. One
applicable template generates one card for an item.

**Card**  
One retrieval probe generated from an item and a template. A card carries its
own memory state, so sibling cards from the same item can become due at
different times.

**Interaction**  
How a card asks you to respond: reveal, type, choose, record, cloze, or arrange.
Automatic checking, when available, gives feedback; you still choose the grade.

**Deck**
A hierarchical organizer and study scope. Deleting a deck deletes everything
inside it — subdecks, items, and their cards. Move items out first if you want
to keep them.

**Due card**  
A card whose saved due date has arrived. A study session loads the cards due
now in the selected scope; future cards are not included.

**Study session**  
A due-card queue reviewed as prompt → response or reveal → grade. Failed cards
return in repair rounds after the other due cards until they are recalled.

**Review / review log**  
One saved Again, Hard, Good, or Easy result. NeoAnki2 appends a review record
and updates the card's memory state.

**Again / Hard / Good / Easy**  
The four self-grades, also available as 1–4. They express recall quality and
feed scheduling; automatic correctness feedback does not select a grade.

**Memory state**  
Per-card scheduling data including difficulty, stability, phase, review and
lapse counts, and due date.

**FSRS**  
The scheduler that updates memory state from review history and chooses the
next due date for a target retention. Exact intervals depend on the card's
history, elapsed time, scheduler parameters, and deterministic variation.

**All Decks / Unassigned**  
Library scopes. All Decks includes every item; Unassigned includes only items
without a deck.

## A useful design rule

Store a coherent fact once as an item, then use templates for the distinct
retrieval routes worth practicing. Do not duplicate an item merely to reverse
the prompt and answer. Each generated card remains an atomic, independently
scheduled test.

---

**Next:** [Choose a task](../tasks/)

**Related:** [Item types and templates](../item-types-and-templates/) · [Scheduling](../scheduling/)
