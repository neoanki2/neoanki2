---
title: iPhone and iPad
description: Navigate, study, author, and transfer content with NeoAnki2 on iOS and iPadOS.
audience: user
nav_order: 2
parent: User Guide
permalink: /user/iphone-ipad/
---

# iPhone and iPad

The optional **Fit study area** Card setup setting keeps large text prompts
centered and scaled to the available study space. It adapts as the phone rotates
and leaves **Show Answer** visible; the revealed answer remains at its normal
reading size. The setting syncs with the item type.

Home loads deck totals and authoring choices before you open a scoped item
browser. A multi-item move succeeds for the entire selection or asks you to
refresh a changed selection. Typed answers keep your submitted text beside the
expected answer after checking; explanations remain under **Explanation**.

The **Statistics** tab on iPhone and sidebar destination on iPad open the same
reports as Mac: Overview, Activity, Memory, and Workload. Its scope filter selects
a deck; **View Session Statistics** opens a completed session's details. Tap a
deck in Home to see its total, new, learning, and mature card counts below the
study controls.
Home and deck screens omit duplicate Statistics and Browse links; use the
Statistics and Library destinations instead. Tracking remains automatic. See [Statistics](../statistics/) and
[Learning time](../learning-time/) for definitions and recording rules.

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

On iPhone and iPad, open **Create → Item Types & Card Setups** to define lists
and set up generated cards. Edit item-owned rows in **Add Item** or **Edit
Item**. To practice a deck separately, turn off **Include in All Decks study**
in its deck settings and use **Study** from the deck itself.

## Navigate on iPhone and iPad

On iPhone, five labeled tabs stay available at the bottom:

- **Home** shows All Decks, Unassigned, individual deck scopes, current due
  counts and the primary Study action.
- **Library** browses, searches, selects, moves, edits, and deletes items.
  Item details show populated fields followed by the maturity of each generated
  card. Open a synced course's lesson item here to read its text and play its audio.
- **Create** adds items and decks, manages item types and Card setups, transfers
  files, opens deck builders, and manages offline vocabulary packs.
- **Statistics** explores activity, memory, sessions, and read-only workload scenarios.
- **Settings** contains iCloud sync, reminders, browsing privacy, grading, and
  scheduling controls.

On iPad and other regular-width layouts, the same five destinations appear in
a persistent sidebar with the selected destination in the detail area. Rotate
the device freely: compact layouts use tabs and regular layouts use the split
view. System Back controls return through nested screens.

Open **Library → Known Words**. Choose the learning
language, then tap **Add Word**. **Mark Known** saves the word to that list.
**Create Cards** uses an example sentence to make two study cards for the
selected deck or Unassigned, including a Cloze card you answer by typing.

When you return to the app, Home and deck screens check your local library
for due cards. **Checking due cards…** appears while the first count is loading.
The displayed count stays visible during later refreshes, including while
iCloud downloads media. Counts also update when the next cards become due
while the app is open. If a check fails, choose **Try Again**.

The Home Screen app icon shows the due-card count across All Decks, even when
you are browsing a single deck. NeoAnki2 asks for badge permission when cards
are first due. The badge updates after study, undo, authoring, and refreshes;
it works with reminders and iCloud disabled. See
[App icon due count](../sync-reminders-widgets/#app-icon-due-count) for permission
and background-refresh details.

## Study

Open **Japanese Academy - Level 1** and tap **Study** to read lessons and
practice the vocabulary that follows each one. Lesson text, images, and audio
scroll in the study area while **Continue** stays visible. An unread
introductory lesson can be studied even when its deck has zero due cards.
When you reveal a vocabulary answer, the word and sentence recordings play
in order. Tap **Play Audio** on either recording to replay it.

Choose **Study** from All Decks, Unassigned, or a deck. The session opens full
screen and uses the same due-card queue and seven interactions as the Mac app:
Reveal, Type Answer, Choose, Arrange, Record, Audio Submission, and Cloze.

Once a deck is caught up, tap **Study Extra Cards** on the deck or on its
regular session completion screen. Choose the batch size, then tap
**Start Extra Session**. The batch uses the same full-screen study controls.
See [Study extra new cards](../studying/#study-extra-new-cards).

On a Record card, tap **Record Answer**, then **Stop Recording**. **Compare
Recording** appears when your recording is ready, and you can replay it while
grading your recall. To study without recording, tap **Reveal & Self-Grade**.

The first card becomes readable while the rest of the queue is validated. You
can reveal its answer during preparation; grading and skipping become available
after validation finishes. A failed load shows **Could Not Start Session** with
**Try Again**, rather than reporting an empty or completed session.

Reveal or check the response, then grade it when the interaction uses FSRS. The
default choices are Again, Hard, Good, and Easy. In **Settings → Study**, enable
**Use Fail / Pass grades** to show only Fail and Pass; they schedule as Again
and Good, respectively. Every Again keeps the card in the current session and
returns it after the cards already waiting, including after consecutive
failures. The card remains in the remaining count until it is remembered or
you end the session. **Skip** moves the current card to the end of the session
without grading it or changing its schedule. Edit updates the current item and
the remaining queued cards generated from it. For a generated poem line, Edit
opens the whole poem so line order and its generated cards stay in sync.
For an ordinary item, **Save** shows progress and returns to study after the
change is stored. Removing a cloze group removes its retired card from the
remaining session. Newly generated cards can join the session when it checks
for more due cards at the end of the queue. A failed save keeps the editor
and your correction available to retry.
**End** leaves immediately;
completion reports reviews and saved submissions separately.

Undo updates the review total and the unique card/item counts together, while
preserving earlier reviews of the same card. Starting a new session clears the
previous session's counts, answer input, and undo action.

After a grade is saved locally, the next card is ready while badges, reminders,
and widgets refresh in the background. These updates also follow review undo
without delaying the study controls. Leaving study refreshes the full Home
summary, including maturity progress.

The mobile study view supports native images, image occlusion, audio, video,
rich text, cloze selection, microphone permission and recording, Dynamic Type,
dark appearance, increased contrast, Reduce Motion, and portrait or landscape
layouts.
Image Occlusion cards reveal the current mask group while keeping the other
groups concealed.
On Focus cards, the question remains first after reveal and the expected answer
appears immediately below it, followed by supplemental answer details. This
preserves the reading order of continuations such as poetry. VoiceOver focus
moves to the newly revealed answer without changing that semantic order.

Independent cards use the same ±15% interval variation and related-card spacing
as Mac. Only one new relative is introduced per study day, including examples
saved for the same expression as separate Context Example items. Poetry and
prose keep their schedules: only eligible parts enter a session, in source order.
Skip and failed recalls return on later passes. See
[Study queue order](../studying/#study-queue-order).

## Author and organize

Open **Create → Add Word** to find a sentence from an installed dictionary and
save a meaning-recall and Cloze pair. The same composer is available from
**Known Words → Add Word → Create Cards**.

Use **Create → New Item** or the add action in a scope. Choose the deck and item
type, then fill its typed fields. The primary picker shows this deck's types;
**Use another type…** opens common types and explicit linked reuse. Changing
decks with entered content asks before attaching the type or clearing the draft.
Visual descriptions are optional. The
Library supports item detail, editing, multi-selection, bulk move, and bulk
delete. In an empty library, **Add First Item** has a 44-point touch target even
at the largest accessibility text size in landscape. After you add an item,
the toolbar offers **Add Item**. The Saved Responses shortcut keeps the
local-only status readable with increased contrast and accessibility text
sizes. Deleting items or changing
Card setups warns before removing saved spoken responses.

Use **Create → Item Types & Card Setups** to edit fields and Card setups in one
Studio save. Selecting a setup pushes its fillable static layout. Layout,
Answer method, Availability, and Learning route use the same shared editor as
macOS. Study uses the same predefined, non-scrolling stage and fixed footer.
Its content, response, status, and action regions reserve their space in order,
so controls and text remain inside the screen.
Deck-provided item types start read-only. Unlock the original for editing when
changes should affect its existing items and decks, or duplicate it for an
independent editable type.

**Deck Settings → Manage Item Types** controls attachments, the default, and
parent inheritance. Unlocking an imported type keeps it scoped to its deck;
**Make Available Everywhere** is a separate action.

Deck settings support rename, nesting, daily new-card limits, progress reset,
and deletion policies. After **Delete and Unassign Items** succeeds, NeoAnki2
closes Deck Settings and the removed deck's detail screen, returning to the
previous deck list; its former items remain available under **Unassigned**.
**Settings → Study → New day begins** sets the local rollover time and saves
automatically. Retention, maximum
interval, content-cohort learning, probation, and fallback are fixed automatic
behavior with no controls or status surface. Maintenance runs locally after
eligible sessions, sync, startup, or idle time; it never runs inline while a
grade is saved.

Inside **Add Word**, choose **Use Custom Item Type…** for dictionary-assisted
field filling. Look up a word, set up the dictionary–deck pair once, and add the
prepared item. Each pair remembers its item type, field mappings, and preferred
content variants on this device. Add stays above the keyboard, and the flow
stays open for the next word. See [Quick vocabulary capture](../authoring-items/#add-a-word-quickly).

The standard **New Item** form contains the selected type's fields. For
dictionary-assisted capture, choose **Add Word → Use Custom Item Type…**.
Install packs through **Settings → Vocabulary Packs**. See
[Quick vocabulary capture](../authoring-items/#add-a-word-quickly).

## Import, export, and build decks

Use **Settings → Import or Export** to choose JSON, CSV, portable `.neodeck`, or
authored `.neoanki` content through the system document picker. Export prepares
a portable `.neodeck` bundle for the selected deck and presents the system save
sheet. The same [format and conflict rules](../import-export/) apply on Mac and
iOS.

**Create → Build Deck** offers guided **Poem Deck** and **Prose Deck** builders.
Created poems and prose passages are placed in their selected parent
decks. Editing a generated unit from item details opens the whole source
editor for that passage.
**Vocabulary Packs** imports and removes local `.neovocab` directories. Packs
and generated previews stay on the device until you explicitly import their
result into the library.

Builder previews show the actual cue and hidden answer for each card. A poem
adds **Recall the first line.** only when its title differs from its opening
line after ignoring punctuation, case, Unicode representation, and spacing.
Prose always includes one **Opening unit** card. The whole-source editor previews
opening-card additions and retirement before you save.

Saved Audio Submission responses remain available after a session ends.
Completion counts saved submissions separately from graded reviews; playback
and deletion remain in Saved Responses on the device where you recorded them.

## Mobile data and feature boundaries

The SQLite library, media, sync metadata, pre-sync backup, settings, saved
spoken responses, and vocabulary packs live in the app's private container.
Use portable export rather than trying to edit those files directly.

Optional iCloud sync transfers library structure, items, scheduling state,
review history, and shared media through the user's private CloudKit database.
Local saves start syncing within a short upload window. With the app active,
reviews and due counts can update while iCloud finishes downloading attachments.
Silent iCloud notifications
can fetch incoming changes in the foreground or during permitted background
execution, and received reviews refresh Home counts and the app icon badge.
iOS can delay background delivery; reopening the app performs a catch-up sync.
When enabled, imported vocabulary packs upload automatically; on another device,
choose when to download them from **Vocabulary Packs**. Downloaded packs work
offline. Device consent, reminder settings, and saved Audio Submission
recordings remain local. The macOS loopback automation API and Mac keyboard
command menus are not mobile features.

Continue with [iCloud, reminders, and widgets](../sync-reminders-widgets/) or
the [first study session](../first-study-session/).
