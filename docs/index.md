---
title: NeoAnki2 documentation
description: Learn how to organize knowledge, author native cards, and study with NeoAnki2.
nav_order: 1
---

# Learn deliberately

NeoAnki2 is a native macOS spaced-repetition app built around structured
knowledge, focused recall, and FSRS scheduling. It uses native text and media
instead of HTML card templates.

## Start here

- [Getting started](user/getting-started/) explains how to build and launch the
  current development release and where NeoAnki2 stores its library.
- [Library and decks](user/library-and-decks/) covers organization and scopes.
- [Authoring items](user/authoring-items/) and [content and
  media](user/content-and-media/) cover every supported field type.
- [Studying](user/studying/) explains interactions, grading, shortcuts, and
  session behavior.
- [Import and export](user/import-export/) describes JSON, CSV, `.neoanki`, and
  `.neodeck` workflows.

## What makes it different

- **Native content:** text, rich text, numbers, cloze spans, images, GIFs,
  audio, and video render as native SwiftUI.
- **Item types and templates:** model facts once, then generate one or more
  cards with reveal, typed, choice, arrange, record, or cloze interactions.
- **Modern scheduling:** Again, Hard, Good, and Easy reviews feed an FSRS
  scheduler.
- **Local-first:** the library and imported media stay on this Mac.

See the [complete feature index](features/) for the article, implementation,
tests, and screenshot associated with every documented capability.

## Current availability

NeoAnki2 does not yet publish signed application releases. The current app is
built from source and targets macOS 14 or newer. It intentionally does not
support Anki `.apkg` packages or HTML/CSS card templates.
