---
title: Chrome companion
description: Read with vocabulary highlights, mark known words, and turn web-page text into NeoAnki2 study cards.
audience: user
nav_order: 11
parent: User Guide
permalink: /user/chrome-companion/
---

# Chrome companion

The optional NeoAnki2 Companion extension saves selected text as a Basic card
through the [local automation API](../local-api/). Suggestions come from an
offline vocabulary pack already installed in NeoAnki2. You can edit or supply
the answer yourself.

## Install from a checkout

1. In Chrome, enter `chrome://extensions` and enable **Developer mode**.
2. Choose **Load unpacked** and select `Extensions/Chrome` inside your NeoAnki2
   checkout. Keep that directory at a stable location.
3. Pin **NeoAnki2 Companion** using Chrome's Extensions menu.
4. Keep NeoAnki2 running and enable **Settings → Local API → Enable local
   automation API**.
5. In the extension's **Settings**, check the port (default `8766`) and choose
   **Connect**. Approve **NeoAnki2 Chrome Companion** in NeoAnki2. Keep the
   extension settings tab open until it says it is connected.
6. Choose a local vocabulary pack, or **None** for manual answers.

This is a local unpacked extension, not a Store download. After updating the
checkout, choose **Reload** for the extension on `chrome://extensions`. Moving
its folder may require pairing again.

## Save selected text

Highlight a word or phrase and click the extension's toolbar icon. Review Front
and Back, choose an existing deck or Unassigned, and choose **Save card**. The
extension remembers the last deck and appends the source page's title and URL
to Back.

A single exact dictionary match fills Back automatically. Multiple matches or
prefix matches appear as choices. Suggestions never overwrite your edited
answer; clear Back first to use another suggestion. Missing dictionaries or
unmatched phrases still allow manual answers.

Selectable YouTube transcript text works with this same flow. Automatic caption
capture, AI generation, audio, and bulk imports are outside this version.

## Use Reading Mode

Open the companion on a web page, expand **Reading Mode**, and choose your
learning language and the language you want to use for meanings. Select
**Start Reading Mode**. Underlines show what you still need:

- Dotted: words you haven't assessed yet.
- Dashed: words you marked as not known.
- Solid: words you're studying with cards.

Known words, ignored words, and numbers appear as ordinary text. The badge in
the corner shows how much of the page you know, such as
"Reading · Ukrainian · 82% known · 14 new". Ignored words and numbers don't
count. Reading Mode stays on as you follow links on the same site in this tab.
Use **Stop** to remove the highlights.

Click an underlined word or select a phrase to open its panel. It shows the
word's status (Known, Learning, Not known, Unassessed, or Ignored), why a word
is known (marked by you, from reviews, or kept from deleted cards), and
**Cloze recall** once you can produce the word. Known and ignored words open
with Option-click (Alt-click), so an ordinary click still selects text.

The definition appears in the panel. Reading Mode checks the selected pack
first, then tries other installed packs for the learning language when it needs
a definition in your chosen meaning language. The selected definition fills
**Meaning** in the card set and serves as the Cloze hint.

For Ukrainian definitions and literary examples, install the СУМ-11 examples
pack in NeoAnki2 and select it in the companion’s **Settings**. If the local
dictionary has no result, enter a meaning yourself.

- **I know this** marks the word known while reading. **Remove from Known**
  marks it not known again.
- **Ignore** hides names, brands, and loanwords from underlines and from the
  coverage count.
- **Use review history** clears your choice and lets your reviews decide.
- **Undo** reverses your last change in the panel.
- **Create card set** uses the selected word and its sentence to make one
  meaning-recall card and one Cloze card for producing the word. Review the
  meaning and Cloze preview before saving. You can choose a dictionary example
  for Cloze, or use one for both cards when the page has no usable sentence.
  The saved set includes the sources used. The Deck field remembers your last
  choice for each learning language, including **Unassigned**.

These choices apply to the word as a whole. When the dictionary offers several
meanings, choose one only for **Create card set**.

### Mark the rest of a page as known

After you've opened the words you don't know, choose **Mark the rest as known**
in the badge. The panel shows the count and a scrollable list of every word it
will mark. It skips words you opened on this page, words you're studying, and
words you already marked not known or ignored. Choose **× (Ignore)** beside a
word to save it as ignored when you choose **Apply changes**. Choose **↶ (Keep)**
to put it back among the words to mark known. **Undo** reverses the whole batch.

### Dictionary forms

With a vocabulary pack selected, Reading Mode recognizes other forms of a word
you know. If you know *книжка*, then *книжку* on a page counts as known too.
Words you mark are saved with their dictionary form when the pack has exactly
one. Without a pack, only the same spelling matches.

### Estimate your level

In extension **Settings**, **Estimate my level** shows 20 sample words from
each frequency band of your pack: the most common 1,000 words, then 1,001–3,000,
3,001–5,000, and 5,001–10,000. Tick the words you know. If you know at least
80% of the samples in the first bands, choose **Mark the top N words as known**.
Words that already have a status and sample words you left unticked are skipped.
**Undo** reverses the step.

### When NeoAnki2 isn't running

Reading Mode keeps a copy of your known words in Chrome. If NeoAnki2 is closed,
the badge says "NeoAnki2 is not running — showing saved words" and the
underlines use that copy. Changes need NeoAnki2 running.

If you paired the companion before Reading Mode was added, reconnect in
**Settings** and approve Known Words access in NeoAnki2. If the companion says
"Update NeoAnki2 to use this version of Reading Mode", the app is older than
the extension; update NeoAnki2, then start Reading Mode or open **Settings**
again.

## Recover an unfinished card

Closing the popup preserves your draft. **Use selection** starts over with the
current selection after confirming that the draft can be discarded.

If a save loses its connection, **Retry save** repeats the same request safely.
The fields remain locked until it is resolved or you discard the draft. A card
may already have been saved even if its response was lost; check NeoAnki2 before
discarding an unresolved draft or changing the connection.

If access was revoked, open extension Settings and connect again. If NeoAnki2
is unreachable, keep it running, enable Local API, and check that both port
settings agree. If Basic is missing or incompatible, create or repair a Basic item type with Front and Back
text fields and unconditional reveal card in NeoAnki2; the extension does not
change your card setups.

## Permissions and data

The extension reads selected text when invoked and uses IPv4 loopback
(`127.0.0.1`) for the NeoAnki2 API. All dictionary lookups use installed packs
through this local connection.
It requests `library.read`, `items.write`, and
`vocabulary.read`. Reading Mode and **Estimate my level** also use
`known-words.read` and `known-words.write`. Its token, unfinished draft, and the
saved copy of your known words are stored locally in Chrome, with access
restricted to trusted extension contexts, rather than Chrome sync.
Cards saved into NeoAnki2 follow the app's sync settings.

Use **Disconnect** in extension Settings while NeoAnki2 is reachable to revoke
the client, or revoke it directly from NeoAnki2's Local API settings.

**Related:** [Local API](../local-api/) · [Author items](../authoring-items/)
