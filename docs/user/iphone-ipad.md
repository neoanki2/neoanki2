---
title: iPhone and iPad
description: Navigate, study, author, and transfer content with NeoAnki2 on iOS and iPadOS.
audience: user
nav_order: 2
parent: User Guide
permalink: /user/iphone-ipad/
---

# iPhone and iPad

NeoAnki2 has a native app for iOS and iPadOS 17 or newer. It shares the same
library model, FSRS scheduler, item types, Card setups, and portable formats as
the Mac app. The interface adapts to the device instead of reproducing the Mac
window at a smaller size.

There is currently no public App Store listing or TestFlight invitation. The
official public download is the Mac release. Maintainers can build and archive
the mobile targets from source; see the
[iOS release checklist]({{ '/IOS_RELEASE/' | relative_url }}).

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Navigate on iPhone and iPad](#navigate-on-iphone-and-ipad)
- [Study](#study)
- [Author and organize](#author-and-organize)
- [Import, export, and build decks](#import-export-and-build-decks)
- [Mobile data and feature boundaries](#mobile-data-and-feature-boundaries)
</nav>

Maintainers can follow the [development setup](../developer/setup/) and
[iOS release checklist]({{ '/IOS_RELEASE/' | relative_url }}) for unsigned builds, devices, CloudKit,
widgets, and TestFlight.

## Navigate on iPhone and iPad

On iPhone, four labeled tabs stay available at the bottom:

- **Home** shows All Decks, Unassigned, individual deck scopes, current due
  counts, and the primary Study action.
- **Library** browses, searches, selects, moves, edits, and deletes items.
- **Create** adds items and decks, manages item types and Card setups, transfers
  files, opens deck builders, and manages offline vocabulary packs.
- **Settings** contains iCloud sync, reminders, browsing privacy, grading, and
  scheduling controls.

On iPad and other regular-width layouts, the same four destinations appear in
a persistent sidebar with the selected destination in the detail area. Rotate
the device freely: compact layouts use tabs and regular layouts use the split
view. System Back controls return through nested screens.

## Study

Choose **Study** from All Decks, Unassigned, or a deck. The session opens full
screen and uses the same due-card queue and seven interactions as the Mac app:
Reveal, Type Answer, Choose, Arrange, Record, Audio Submission, and Cloze.

Reveal or check the response, then grade it when the interaction uses FSRS. The
default choices are Again, Hard, Good, and Easy. In **Settings → Study**, enable
**Use Fail / Pass grades** to show only Fail and Pass; they schedule as Again
and Good, respectively. Edit updates the current item and the remaining queued
cards generated from it. End asks for confirmation; completion reports reviews
and saved submissions separately.

The mobile study view supports native images, audio, video, rich text, cloze
selection, microphone permission and recording, Dynamic Type, dark appearance,
increased contrast, Reduce Motion, and portrait or landscape layouts.
On Focus cards, the question remains first after reveal and the expected answer
appears immediately below it, followed by supplemental answer details. This
preserves the reading order of continuations such as poetry. VoiceOver focus
moves to the newly revealed answer without changing that semantic order.

## Author and organize

Use **Create → New Item** or the add action in a scope. Choose the deck and item
type, then fill its typed fields. Visual media requires a description. The
Library supports item detail, editing, multi-selection, bulk move, and bulk
delete. In an empty library, **Add First Card** keeps a high-contrast 44-point
target at the largest accessibility text size, including in landscape. The
Saved Responses shortcut also keeps the local-only status readable with
increased contrast and accessibility text sizes. Deleting items or changing
Card setups warns before removing saved spoken responses.

Use **Create → Item Types & Card Setups** to edit fields and Card setups in one
Studio save. Selecting a setup pushes its fillable static layout. Layout,
Answer method, Availability, and Learning route use the same shared editor as
macOS. Study uses the same non-scrolling adaptive stage and fixed footer;
overflowing content opens in a separate detail sheet.
Deck-provided item types start read-only. Unlock the original for editing when
changes should affect its existing items and decks, or duplicate it for an
independent editable type.

Deck settings support rename, nesting, daily new-card limits, progress reset,
and deletion policies. Scheduling settings expose study-day rollover, desired
retention, maximum interval, automatic-personalization status, active model
health, restore-defaults, and rollback controls. Optimization runs locally after
eligible sessions or idle time; it never runs inline while a grade is saved.

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
