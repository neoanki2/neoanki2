---
title: Getting started
description: Install, update, and safely remove the official NeoAnki2 Mac release.
audience: user
nav_order: 1
parent: User Guide
---

# Getting started

NeoAnki2 is a native, local-first spaced-repetition app for Mac, iPhone, and
iPad. Homebrew is the recommended Mac installation because it verifies the
release and simplifies updates. The same official Mac build is also available as a direct DMG from the
[download page]({{ site.baseurl }}/download/). Maintainers and contributors can
build the current source checkout for macOS or iOS. There is not yet a public
App Store or TestFlight download; see the [iPhone and iPad guide](../iphone-ipad/).

## Install the official Mac release

On macOS 14 or newer with Homebrew installed, run:

```bash
brew install --cask neoanki2/tap/neoanki2
```

Homebrew downloads the universal DMG from the matching GitHub release, verifies
its cask checksum, and installs `NeoAnki2.app` in `/Applications`. Every tested
update merged to `main` publishes a new release and updates the cask.

If you do not use Homebrew, open the [download page]({{ site.baseurl }}/download/)
and choose **Download DMG**. Open the disk image, then move `NeoAnki2.app` to
Applications. The Homebrew and direct-download options contain the same app.

Release artifacts are ad-hoc signed and provenance-attested, but are not yet
Apple-notarized. If macOS blocks the first launch, Control-click **NeoAnki2** in
Applications, choose **Open**, then confirm **Open**. Do not disable Gatekeeper
globally.

The public Mac release and ordinary source-built app bundles do not carry the
private CloudKit entitlement, so the iCloud settings report **Unavailable in
this build** and keep the library local. An iCloud container requires a separately provisioned and signed build.
This does not affect manual backups, deck export, studying, or authoring.

To update later, run:

```bash
brew update
brew upgrade --cask neoanki2
```

Your library is not replaced by installation or upgrade; it remains in
`~/Library/Application Support/neoanki2/`.

The study-composition upgrade is the exception that requires a one-time,
headless template-definition migration before first launch. Follow the
[`neoanki-template-migrator`](cli.md#migrate-a-version-1-template-library) backup, plan,
apply, and verify sequence; the app refuses legacy definitions without moving
them into quarantine.

## Build from source

Source builds, toolchain checks, headless commands, shared-library cautions, and
platform builds are maintained in the
[Developer Guide](../developer/setup/). They are not required to install or use
the official Mac release.

## Update

For an official Homebrew installation, use:

```bash
brew update
brew upgrade --cask neoanki2
```

For development checkouts and unreleased builds, follow the
[development setup and update guidance](../developer/setup/). Never discard local
source changes blindly or run two builds against one library.

## Uninstall or remove the checkout

1. Quit NeoAnki2.
2. For a Homebrew installation, run `brew uninstall --cask neoanki2`.
3. To keep your study data for a future installation, stop here.
4. To remove all NeoAnki2 data too, first make any backup you intend to keep,
   then delete `~/Library/Application Support/neoanki2/`.

Deleting the data folder permanently removes the library and managed media.
There is no in-app uninstall or recovery after deleting it without a backup.

## First launch

NeoAnki2 creates a local library and seeds two starter item types:

- **Basic**, with required Front and Back text fields
- **Cloze**, with a required cloze Text field and optional rich-text Context

The starter types define how items generate cards. They do not add sample
items or decks, so a new library opens to **All Decks** with an empty state.

[![An empty library with the Add Item action]({{ site.baseurl }}/assets/screenshots/library-empty.png)]({{ site.baseurl }}/assets/screenshots/library-empty.png)

Documentation screenshots use dark appearance for consistency. NeoAnki2
normally follows your current macOS appearance setting.

App-level preferences are under **NeoAnki2 → Settings**. The **Study** tab
includes the device-local Fail / Pass grading option; Local API and iCloud tabs
appear after the library finishes opening. An unprovisioned build clears a
previously saved iCloud opt-in instead of attempting to initialize a container
that its signature cannot access.

Do not stop at the empty screen: the [five-minute first study
session](../first-study-session/) creates one Basic item, reviews its generated
card, and confirms the scheduler recorded the result.

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
- The detail area shows the selected scope's home, browse mode, item detail, or
  the active task.

Selecting a scope opens its home: what is due, what to study, and a link into
browse mode. Browse mode is where you search items and open one for editing;
open it with **Command-Option-B** and leave it with **Escape**. The sidebar can
also be shown or hidden with the standard macOS split-view controls.

When the scope home reports cards that have been forgotten repeatedly, choose
**Review Affected Items** to open Browse with only their source items showing.
Open a row to inspect or edit it. If the content is already clear, select its
row and choose **Mark Selected OK**; the item leaves this attention list until
one of its cards lapses again. Choose **Done** to return to the scope home, or
**Show All Items** to clear the filter.

The Home summary is prepared while the app window opens, so its counts and
primary study action are ready with the rest of the library view.

NeoAnki2 uses focused, detail-only modes while adding an item, managing item
types, or editing a template. The sidebar collapses automatically to make room;
the template builder also hides the Item Types list and outer Done action while
it is open. Study replaces the library split view with a full-window review
surface, so sidebar controls are unavailable until the session ends. Leaving
Study restores the library and its previous sidebar visibility. Reduced Motion
is respected when columns change.

Leaving a study session returns you to the scope home with its counts already
revised. NeoAnki2 may also retune its scheduler against your review history at
that moment; this is silent and changes nothing on screen. See
[Scheduling](../scheduling/#optimization-happens-on-its-own).

## Current compatibility limits

NeoAnki2 is a rewrite, not an Anki-compatible client. It does not support:

- Anki `.apkg` packages or shared-deck import
- HTML/CSS card templates
- Changing an existing item's item type after creation

Its own JSON, CSV, `.neoanki`, and `.neodeck` workflows are separate from
Anki's formats.

---

**Next:** [Complete your first study session](../first-study-session/)

**Related:** [Troubleshooting](../troubleshooting/) · [Concepts and glossary](../concepts/) · [Developer guide](../developer/)
