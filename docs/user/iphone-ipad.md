---
title: iPhone and iPad
description: Build, navigate, study, author, and transfer content with NeoAnki2 on iOS and iPadOS.
nav_order: 2
parent: User Guide
permalink: /user/iphone-ipad/
---

# iPhone and iPad

NeoAnki2 has a native app for iOS and iPadOS 17 or newer. It shares the same
library model, FSRS scheduler, item types, templates, and portable formats as
the Mac app. The interface adapts to the device instead of reproducing the Mac
window at a smaller size.

There is currently no public App Store listing or TestFlight invitation. The
official public download is the Mac release. Maintainers can build and archive
the mobile targets from source; see the [iOS release checklist][ios-release].

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Build a development app](#build-a-development-app)
- [Navigate on iPhone and iPad](#navigate-on-iphone-and-ipad)
- [Study](#study)
- [Author and organize](#author-and-organize)
- [Import, export, and build decks](#import-export-and-build-decks)
- [Mobile data and feature boundaries](#mobile-data-and-feature-boundaries)
</nav>

## Build a development app

From a checkout with Xcode 26 and an iOS 17 or newer SDK, run:

```bash
./Scripts/build-ios.sh
```

This performs the repository's unsigned build validation for the iPhone/iPad
app and embedded WidgetKit extension. It does not install a build on a physical
device and does not create a distributable IPA. Running on hardware, CloudKit,
push updates, widgets, and TestFlight require the Apple identifiers,
entitlements, App Group, iCloud container, and profiles listed in the
[release checklist][ios-release].

## Navigate on iPhone and iPad

On iPhone, four labeled tabs stay available at the bottom:

- **Home** shows All Decks, Unassigned, individual deck scopes, current due
  counts, and the primary Study action.
- **Library** browses, searches, selects, moves, edits, and deletes items.
- **Create** adds items and decks, manages item types and templates, transfers
  files, opens deck builders, and manages offline vocabulary packs.
- **Settings** contains iCloud sync, reminders, browsing privacy, and
  scheduling controls.

On iPad and other regular-width layouts, the same four destinations appear in
a persistent sidebar with the selected destination in the detail area. Rotate
the device freely: compact layouts use tabs and regular layouts use the split
view. System Back controls return through nested screens.

## Study

Choose **Study** from All Decks, Unassigned, or a deck. The session opens full
screen and uses the same due-card queue and seven interactions as the Mac app:
Reveal, Type Answer, Choose, Arrange, Record, Audio Submission, and Cloze.

Reveal or check the response, then choose Again, Hard, Good, or Easy when the
interaction uses FSRS. Edit updates the current item and the remaining queued
cards generated from it. End asks for confirmation; completion reports reviews
and saved submissions separately.

The mobile study view supports native images, audio, video, rich text, cloze
selection, microphone permission and recording, Dynamic Type, dark appearance,
increased contrast, Reduce Motion, and portrait or landscape layouts.

## Author and organize

Use **Create → New Item** or the add action in a scope. Choose the deck and item
type, then fill its typed fields. Visual media requires a description. The
Library supports item detail, editing, multi-selection, bulk move, and bulk
delete. Its Saved Responses shortcut keeps the local-only status readable with
increased contrast and accessibility text sizes. Deleting items or changing
templates warns before removing saved spoken responses.

Use **Create → Item Types & Templates** to create or edit fields, templates,
interactions, prompt and answer slots, skills, and generation conditions.
Deck-provided item types start read-only. Unlock the original for editing when
changes should affect its existing items and decks, or duplicate it for an
independent editable type.

Deck settings support rename, nesting, daily new-card limits, progress reset,
and deletion policies. Scheduling settings expose study-day rollover and manual
FSRS optimization from review history.

## Import, export, and build decks

Use **Create → Import or Export** to choose JSON, CSV, portable `.neodeck`, or
authored `.neoanki` content through the system document picker. Export prepares
a portable `.neodeck` bundle for the selected deck and presents the system save
sheet. The same [format and conflict rules](../import-export/) apply on Mac and
iOS.

**Deck Builders** contains guided poem and installed-vocabulary builders.
**Vocabulary Packs** imports and removes local `.neovocab` directories. Packs
and generated previews stay on the device until you explicitly import their
result into the library.

## Mobile data and feature boundaries

The SQLite library, media, sync metadata, pre-sync backup, settings, saved
spoken responses, and vocabulary packs live in the app's private container.
Use portable export rather than trying to edit those files directly.

Optional iCloud sync transfers library structure, items, scheduling state,
review history, and shared media through the user's private CloudKit database.
Device consent, reminder settings, installed vocabulary packs, and saved Audio
Submission recordings remain local. The macOS loopback automation API and Mac
keyboard command menus are not mobile features.

Continue with [iCloud, reminders, and widgets](../sync-reminders-widgets/) or
the [first study session](../first-study-session/).

[ios-release]: https://github.com/neoanki2/neoanki2/blob/main/IOS_RELEASE.md
