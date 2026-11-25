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
**Start Reading Mode**. Dotted underlines mark unassessed vocabulary and solid
underlines mark words you’re studying. Known words appear as ordinary text.
Reading Mode stays on as you follow links on the same site in this tab. Use
**Stop** to remove the highlights.

Click an underlined word or select a phrase to open its actions. **I know this**
records that you understand it while reading. Use **Undo** if you tapped by
mistake. **Create card set** uses the selected word and its sentence to make
one meaning-recall card and one Cloze card for producing the word. Review the
meaning and Cloze preview before saving. The dictionary is optional.

If you paired the companion before Reading Mode was added, reconnect in
**Settings** and approve Known Words access in NeoAnki2.

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

The extension reads selected text when invoked and connects only to IPv4
loopback (`127.0.0.1`). It requests `library.read`, `items.write`, and
`vocabulary.read`. Reading Mode also uses \`known-words.read\` and \`known-words.write\`. Its token and unfinished draft are stored locally in Chrome,
with access restricted to trusted extension contexts, rather than Chrome sync.
Cards saved into NeoAnki2 follow the app's sync settings.

Use **Disconnect** in extension Settings while NeoAnki2 is reachable to revoke
the client, or revoke it directly from NeoAnki2's Local API settings.

**Related:** [Local API](../local-api/) · [Author items](../authoring-items/)
