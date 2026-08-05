---
title: NeoAnki2 documentation
description: Start studying in five minutes, find a task, or understand NeoAnki2's learning model.
nav_order: 1
---

# Learn deliberately

NeoAnki2 is a native macOS spaced-repetition app built around structured
knowledge, focused recall, and FSRS scheduling. It uses native text and media
instead of HTML card templates.

## Start

- [Install or build and launch](user/getting-started/)
- [Complete your first study session](user/first-study-session/)

## Tasks

- [Find a guide by goal](user/tasks/)
- [Browse the complete user guide](user/)

## Understand

- [Learn the core concepts](user/concepts/)
- [Read how studying works](user/studying/)

## Troubleshoot

- [Diagnose an app problem](user/troubleshooting/)
- [Fix build or launch problems and report an issue safely](user/support/)

## Advanced

- [Customize item types and templates](user/item-types-and-templates/)
- [Import or export content](user/import-export/)
- [Use the deck authoring CLI](user/cli/)
- [Browse implementation and format references](reference/)

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

NeoAnki2 publishes universal, checksummed, provenance-attested macOS releases
through its official Homebrew tap after every tested update to `main`. Releases
are ad-hoc signed but are not yet Apple-notarized. The app targets macOS 14 or
newer and intentionally does not support Anki `.apkg` packages or HTML/CSS card
templates.

---

**Next:** [Install or build NeoAnki2](user/getting-started/)

**Related:** [Choose a task](user/tasks/) · [Understand the learning model](user/concepts/)
