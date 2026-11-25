---
title: Personal vocabulary and immersion research
description: Research and proposed design for known words, sentence mining, and browser companions in NeoAnki2.
audience: developer
permalink: /proposals/personal-vocabulary-and-immersion/
---

# Personal vocabulary and immersion research

Research from November 19, 2026. The design below is a proposal.

NeoAnki2 could give language learners a personal vocabulary library that spans
decks and includes terms they have never studied with flashcards. An optional
language feature would use that library to connect reading and sentence mining
to ordinary NeoAnki2 items. Each generated card would keep its own review
history and schedule.

## What existing tools do

| Tool | Observed behavior | Implication for NeoAnki2 |
| --- | --- | --- |
| LingQ | Users can mark terms Known or Ignored and revise those statuses. Known words leave its review queue. [LingQ status guide](https://lingq-support.groovehq.com/help/can-you-explain-a-lingqs-status) | Make vocabulary judgments reversible. Give card suspension its own control. |
| Migaku | Its published explanation describes deriving Known from review intervals as well as other statuses for deciding what to highlight. [Migaku learning statuses](https://migaku.com/blog/youtube/supercharge-your-language-learning-tracking-learned-words) | Review history can suggest knowledge when a card has an explicit lexical target. |
| Language Reactor | Exports distinguish phrases, words with or without context, and lemmas versus surface forms. [Language Reactor export guide](https://www.languagereactor.com/help/export) | Save the target and its original occurrence so users can recover both. |
| Lute | Parent terms link inflections such as *hablo* to *hablar*. [Lute manual](https://luteorg.github.io/lute-manual/background.html) | Resolve inflections when the available language data supports it. |
| jpdb | Tracks vocabulary across decks and selects examples around a target the learner is studying. [jpdb overview](https://www.jpdb.io/) | A vocabulary library becomes useful across decks and can help prioritize examples. |

## Where it fits in NeoAnki2

| Existing surface | Proposed role |
| --- | --- |
| `LexicalEntry` in `Sources/NeoAnkiVocabularyKit/Models.swift` already provides language, forms, pronunciations, and senses. | Use installed packs for lookup and enrichment. A personal term retains its own identity when a pack is replaced or removed. |
| `ContextTarget` in `Sources/NeoAnkiApplication/ContextAuthoring.swift` carries expression, language, meaning, forms, and optional pack, entry, and sense references. | Use it as the bridge from contextual authoring to an explicit term link. Use an explicit field mapping when linking other item types. |
| `Item` and `Skill` in `NeoAnkiCore` describe study content and what a card practices. | Keep studying and scheduling on their existing paths. Use the declared target and skill if review history later informs vocabulary estimates. |
| The Chrome companion already saves selected text as a Basic card and looks up suggestions from a local pack. | Extend the existing capture entry point to display a term's status and offer marking known, saving context, and creating a linked item. [Chrome companion guide]({{ '/user/chrome-companion/' | relative_url }}) |

Tags and special item types could approximate the workflow quickly, but would
require creating items for already-known words and reconciling labels across
decks. An optional feature with its own vocabulary records addresses both
problems. A general concept model across subjects would require decisions about
identity and knowledge in domains where the language use case supplies little
evidence.

## Terms, encounters, and study items

- A **personal term** has a stable ID, language, and display form. It can be a
  word or phrase and may have alternate forms, a reading, part of speech,
  optional dictionary references, and provenance for its status.
- A **saved encounter** records the sentence, the actual selected text and its
  span, and available source details such as page title, URL, or playback time.
  A term can have several encounters. A saved sentence can wait in an inbox
  until the learner chooses to make a card. Media can follow later.
- A **study item link** associates an explicit target with an ordinary item.
  Several items in different decks can practice the same term. Deleting the
  last linked item removes the link and preserves the personal term.

Match by language and use normalized text as a lookup aid. A durable term ID
lets *went* resolve to *go* and lets two meanings of *bank* stay distinct when
the user or dictionary provides enough information. Start with coarse word
and phrase matches. Leave ambiguous instances unassessed until they can be
resolved. Japanese and Chinese require language-aware segmentation for
automatic page analysis.

## What Known means

Start with reading recognition. **Known** means “I usually understand this
term when reading it in context.” A user can also mark a term **Unknown** or
clear the judgment. A missing record is **Unassessed**, which is common when
an experienced learner first imports a list or starts using the app.

Treat **Ignored** as a display preference and show **Learning** when linked
cards are being studied. These can coexist with a knowledge judgment. Marking
a term Known leaves its cards eligible for review under their current schedules.
An explicit judgment takes precedence over any later inference from reviews.
A successful review can support an estimate for the declared target and skill.
Listening recognition and production may warrant separate judgments later.

## First workflow and delivery order

1. Add an optional **My Vocabulary** view with a language filter, search,
   manual status changes, and bulk import and export. Support a plain word list
   so users can bring existing knowledge into the app without creating cards.
   Keep these records in the app and plan for offline use and iCloud sync.
2. Link personal terms to existing contextual targets and explicitly mapped
   items. Add scoped local API access for vocabulary state. Keep authorization
   separate from pack management and item creation. [Vocabulary API]({{ '/VOCABULARY_API/' | relative_url }})
3. Add **I know this**, **Save sentence**, and **Create card** to the Chrome
   companion. The first updates a term, the second keeps the original example,
   and the third creates a linked study item. Treat NeoAnki2 as the authority
   and use a local browser cache for reads when the Mac app is unavailable.
4. Use batch lookups or an incremental snapshot for page analysis. Later, add
   highlighting, one-unfamiliar-term suggestions, and vocabulary coverage that
   shows how much text is unassessed. Coverage estimates how much vocabulary a
   user recognizes in a passage. Overall comprehension also depends on context
   and grammar.
5. Use review history to suggest vocabulary judgments after term links and
   skill mappings have proved reliable.

The first end-to-end milestone is a user marking a term Known in NeoAnki2,
seeing the judgment in Chrome, and saving a new sentence with no change to
their review queue. Test that the same spelling in another language has its
own status and that removing a deck or pack preserves the term.
