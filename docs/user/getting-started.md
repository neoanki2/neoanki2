---
title: Getting started
nav_order: 1
parent: User Guide
---

# Getting started

NeoAnki2 is a native, local-first macOS spaced-repetition app. The project does
not currently publish releases, installers, or a signed application download.
To use it today, build it from source.

## Requirements

- macOS 14 or newer
- Git
- A Swift 6 toolchain, normally installed with a current version of Xcode or
  the matching Xcode Command Line Tools

The repository is a Swift package. It does not include an end-user Xcode
project for the app.

## Build and launch the app

From the repository root, run:

```bash
./Scripts/run-app.sh
```

This builds a debug executable, assembles and ad-hoc signs
`.build/NeoAnki2.app`, and opens it. The generated bundle is a development
build inside the checkout; the script does not install it in `/Applications`.
Re-run the script after pulling source changes.

To run the executable directly from Terminal instead:

```bash
./Scripts/run-app.sh cli
```

The CLI mode builds with `swift build -c debug` and launches with
`swift run NeoAnki2`. Keep that Terminal window open while the app is running.

## First launch

NeoAnki2 creates a new local library and seeds two starter item types:

- **Basic**, with required Front and Back text fields
- **Cloze**, with a required cloze Text field and optional rich-text Context

The starter types define how items generate cards. They do not add sample
items or decks, so a new library opens to **All Decks** with an empty state.

![An empty library with the Add Item action]({{ site.baseurl }}/assets/screenshots/library-empty.png)

Choose **Add Item** to create a first Basic item, or use the **+** button in
the deck sidebar to organize items in a deck first. See [Authoring
items](../authoring-items/) for the complete item workflow.

## Know where your data lives

The normal library is stored in:

```text
~/Library/Application Support/neoanki2/
```

That directory contains:

- `neoanki2.sqlite`, the library database
- `media/`, the app-managed copies of attached images, GIFs, audio, and video

NeoAnki2 creates these files automatically and keeps data on this Mac. For a
manual backup, quit the app and copy the whole `neoanki2` directory so the
database and media remain together. Editing the database or hash-named media
files by hand can break references.

Removing the source checkout or rebuilding `.build/NeoAnki2.app` does not
remove the library. Deleting the Application Support directory does.

## Navigate the library

The main window is a split view:

- The sidebar contains **All Decks**, the deck tree, and **Unassigned**.
- The detail area shows the selected scope's item list, empty state, item
  detail, or the active task.

Double-click an item row to open its detail. Select another sidebar scope to
filter the list and clear the current item selection. The sidebar can also be shown
or hidden with the standard macOS split-view controls.

NeoAnki2 uses focused, detail-only modes while adding an item, managing item
types, or studying. The sidebar collapses automatically to make room, but can
still be revealed with the normal sidebar control. Leaving the task restores
the full split view. Reduced Motion is respected when these columns change.

## Current compatibility limits

NeoAnki2 is a rewrite, not an Anki-compatible client. It does not support:

- Anki `.apkg` packages or shared-deck import
- HTML/CSS card templates
- Changing an existing item's item type after creation

Its own JSON, CSV, `.neoanki`, and `.neodeck` workflows are separate from
Anki's formats.
