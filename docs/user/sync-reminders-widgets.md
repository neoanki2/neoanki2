---
title: iCloud, Reminders, and Widgets
description: Opt in to private CloudKit sync, recover sync issues, schedule due-card reminders, and use the iOS widget.
audience: user
nav_order: 8
parent: User Guide
permalink: /user/sync-reminders-widgets/
---

# iCloud, Reminders, and Widgets

Saved library changes refresh native counts whether they come from this device,
the local API, or iCloud. A device-update warning after saving means the library
change is already stored; refresh to retry badge, reminder, or widget
publication rather than creating or importing the same content again. Saving
an item does not wait for those device updates or for iCloud to finish. The
local change remains usable while its counts and device indicators catch up.
On iPhone and iPad, returning to the app checks local due counts before waiting
for iCloud. Badge, reminder, and widget publication continues separately from
the visible count refresh.

Statistics also has an independent private iCloud zone for content-free review,
undo, lifecycle, and session evidence. Idempotent event identities prevent
repeated delivery from duplicating activity, and unrelated record arrival order
does not turn an explicit undo into a review. Statistics reports remain separate
from the operational app-icon due count, reminder schedule, and widget values.
See [Statistics](../statistics/) for legacy coverage and deletion rules.

Updated apps also synchronize active learning-time segments through a separate
private iCloud zone. Offline study joins combined totals after syncing, and
repeated delivery never duplicates time. Older apps keep ordinary library sync
but require an update to record or display learning time. A library report labels
time whose item has not arrived yet as waiting for synced content. This history
is separate from review scheduling, reminders, widgets, and app-icon due counts.
See [Learning time](../learning-time/).

iCloud sync is available in provisioned Mac, iPhone, and iPad builds. Daily
reminders and the Due Cards widget are iPhone/iPad services. The library remains
usable offline and each device keeps its own service preferences.

Grading and review undo save locally before updating app-icon badges, reminders,
and widgets in the background. These services read due counts and the next study
time without rebuilding maturity progress from the review history. A slow device
service does not keep **Saving review…** visible or prevent the next grade.
Leaving study refreshes the full Home summary with the latest saved results.

Vocabulary Sets and saved Context Example items use ordinary item and media
sync. Saving a set refreshes due counts, badges, reminders, and widget data.

Items saved through **Add Word** use ordinary library sync and update due counts,
including badges and the widget. Saved dictionary–deck capture configurations
remain local to each device and library; configure a pair separately on another
device even when its items and dictionary packs have synced.

Poem and prose creation saves the selected parent relationship with the deck.
After the local save, the deck and its items join ordinary library sync; badges,
reminders, and widgets refresh from committed library data. A dictionary pack's
download status is separate from the sync status of saved study items.

This guide follows the current `main` source. Before relying on sync in an
installed build, check that build's release notes and entitlements; an older
public Mac release or unsigned contributor build can operate locally without a
usable CloudKit container.

On Mac, **Unavailable in this build** means the executable does not have the
signed entitlement for NeoAnki2's private container. The sync toggle and
**Sync Now** remain disabled, and any saved opt-in is cleared without touching
the local library. This is a build capability, not an iCloud account error.

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Set up iCloud sync](#set-up-icloud-sync)
- [What syncs](#what-syncs)
- [Dictionary packs](#dictionary-packs)
- [Sync status and issues](#sync-status-and-issues)
- [Troubleshoot iCloud](#troubleshoot-icloud)
- [Daily reminders](#daily-reminders)
- [App icon due count](#app-icon-due-count)
- [Due Cards widget](#due-cards-widget)
</nav>

## Mac App Store and Homebrew libraries

The native Mac App Store build and Homebrew build use separate app identities
and local libraries. A Store installation does not silently open the Homebrew
library outside its sandbox. Transfer decks through portable export/import, or
opt each installation into the same private iCloud library. Each installation
keeps its own sync consent and notification permissions.

Allowing the app icon badge does not enable iCloud sync or daily reminders.
Daily reminders and the Due Cards widget remain iPhone/iPad services; the native
Mac Store build provides its Dock badge and in-app due counts.

## Set up iCloud sync

CloudKit is off until you opt in on each device:

1. Sign in to iCloud in system Settings and confirm iCloud Drive is available.
2. On iPhone or iPad, open NeoAnki2 **Settings** and choose **Enable iCloud
   Sync…**. On Mac, open **NeoAnki2 → Settings → iCloud** and turn on **Sync
   this Mac**. If that control is disabled and Status says **Unavailable in
   this build**, install a separately provisioned build before continuing.
3. Read the consent message, then choose **Create Backup & Enable**.
4. Keep the app open until Status becomes **Current**, or open **Sync Issues**
   if it becomes **Needs attention**.
5. Repeat these steps on every other Mac, iPhone, or iPad you want to sync.
   Consent is deliberately device-local.

On Mac, wait for the local library to finish opening if the iCloud tab is not
visible yet. The Study tab can appear first because its preferences do not
depend on the library or CloudKit.

Before its first upload, NeoAnki2 creates and verifies a SQLite backup in the
app container. It then merges the local and private CloudKit libraries; neither
library is silently replaced wholesale. Local SQLite remains authoritative, so
authoring and study continue when the network or iCloud is unavailable.

Use **Sync Now** for an immediate attempt. NeoAnki2 also synchronizes when it
becomes active, about 250 milliseconds after committed local changes, and when
iCloud sends a silent change notification. Incoming changes refresh Home,
Browse schedules, and due counts as soon as they commit, rather than waiting
for the ordinary count timer. The library checks for missed notifications about
every three seconds while active. On Mac it continues checking about every ten
seconds while another app has focus, so the Dock badge can catch up.

Pending changes, including downloaded images, remain recoverable after an app
update. The updated app resumes its saved queue when it next runs, preserving
existing reviews and card schedules.

Large media transfers save progress in small batches and reuse files already
installed. On iPhone and iPad, media for the deck you have open or are studying
gets priority. NeoAnki2 also requests background processing so transfers can
continue when iOS grants runtime after you leave the app. If iOS interrupts
the transfer, the next sync continues from saved progress. A newly synced deck
appears after its required files have finished installing.

Updates can arrive within a few seconds while both apps are active, but there
is no fixed delivery-time guarantee. iOS controls background execution and can
delay or coalesce silent notifications; opening the app performs a catch-up
sync. System-granted background refresh remains available as another recovery
path.

Turning off **Sync this device** on iOS or **Sync this Mac** on macOS stops that
device's sync and leaves its local library intact. It does not erase the private
CloudKit library or change other devices.

After enabling sync or receiving library changes, Home refreshes its deck and
due-card counts. Edits made while a sync batch is uploading remain pending for
a later batch, so you can keep authoring offline. Interrupted transfers retain
their pending work and resume when the service becomes available.

Background refresh updates reminder and widget information when iOS grants
execution time. If iOS expires that work, it stops safely and can continue on a
later refresh; opening the app remains the way to request a current summary.

## What syncs

Choosing **Continue** on a Japanese Academy lesson saves its reading progress
on the lesson item. Devices using the same iCloud library can pick up at the
next unread lesson after that update syncs.

Incoming media is stored before its accompanying items are committed. If an
image arrives in a later sync batch, it is associated with the items already
referencing it and retained during cleanup.

A deck imported on Mac can appear on iPhone and iPad through iCloud. Large
courses may spend time downloading and verifying media before the deck appears.

Card schedules are checked against their saved review history when sync commits
and when a library opens. A delayed card snapshot cannot replace a newer grade;
previously affected libraries repair their due counts automatically. Review
undo records remain effective even if the old reviewed card arrives later.

Explicit Known Words marks and removals sync through your private iCloud
library. Words retain their learning-language scope across devices. Vocabulary
sets sync as library items, and review-based entries are derived from the
saved review history.

Deck type attachments, defaults, inheritance overrides, explicit global
availability, and imported editing protection sync independently of the schema.
Unlocking a type does not make it global. Update other devices before changing
type organization because older clients do not understand these scope records.
Organization alone leaves card identities and due dates unchanged, so reminder,
widget, and app-icon counts continue to describe the same existing cards.

Private CloudKit sync includes decks, item types and their persisted templates
(shown as Card setups), items, card
state, immutable review and revert history, and shared content-addressed media.
First reviews also carry their original deck and study day, so introducing new
cards on one device consumes the same daily allowance on your other devices.
This includes first grades saved during an extra study session.
An upgrade restores missing allowance entries from older synced reviews using
the current deck and study-day settings when the original context is unavailable;
entries already recorded on the device are preserved.
Immutable history is unioned deterministically. Concurrent edits to mutable
resources accept one version while preserving the other as a conflict copy
when it can be restored.

Item Type Studio keeps its field and Card setup edits in one draft. **Save**
commits that complete definition locally so it can sync as one item-type
change; **Cancel** discards the draft, so no partial Studio edits are uploaded.
Generated prose units and their cards use the same library sync path as other
items. A whole-passage edit is committed locally as one change before its
resulting items and card state are eligible to sync.

These remain local to each device:

- the iCloud opt-in itself;
- the Fail / Pass grading-control preference;
- reminder time and scope;
- persistent Audio Submission recordings and their private-only media; and
- widget snapshots, which contain aggregate due information only.

Use portable deck export when you need an explicit file transfer or archive.

## Dictionary packs

When iCloud sync is enabled, imported vocabulary packs upload automatically to
your private iCloud library. Other devices receive the dictionary catalog
automatically; the dictionary files download only when you choose **Download**.

Open **Library → Vocabulary Packs…** on Mac or **Settings → Vocabulary Packs** on
iOS. **On This Device** lists packs available offline. **In iCloud** shows the
available dictionaries and their download sizes. Choose **Download** to install
one, or cancel a download and resume it later. The catalog refreshes while the
app is running. **Sync Now** also checks for changes. Use **Refresh** in the
Vocabulary Packs toolbar when packs are listed. If the list is empty, use
**Refresh from iCloud** or **Retry iCloud Sync** in the empty state.

**Remove from Device** frees local storage and keeps the uploaded copy and saved
cards. Disabling sync stops transfers; installed dictionaries remain available
offline. If another version of the same pack is available, **Replace Download**
asks before replacing it. The existing version stays usable until the new copy
has downloaded and passed validation.

Large packs consume iCloud storage, network bandwidth, and temporary local
storage during installation. Uploads retry automatically. A pack appears on
other devices only after its complete upload, and interrupted transfers reuse
completed chunks when retried. Dictionary transfer progress and errors appear
in Vocabulary Packs, separately from the card library's sync status.

## Sync status and issues

**Offline** means local work is available but CloudKit cannot currently
transfer. **Syncing** means a batch is in progress. **Current** means the last
attempt completed without a retained issue. **Account unavailable** means the
iCloud account, entitlement, or container cannot be used. **Needs attention**
means one or more recoverable batches or conflicts were preserved.

Mutable conflicts resolve automatically. The synced version stays in place. If
the preserved item, deck, or item type has different content, NeoAnki2 restores
it as a separate copy and syncs that copy. Identical content does not create a
duplicate. Recovered decks and item types have **(Recovered)** in their names. Card
scheduling conflicts keep the accepted state and archive the prior state;
they do not create duplicate items or cards.

No conflict decision or review screen is required. Prior versions and deletion
conflicts remain archived in local sync metadata. Recovery is idempotent, so
restarting or retrying does not create additional copies of the same conflict.
Transfer and validation failures retry automatically; a failure that cannot be
safely recovered remains visible in the sync status.

If iCloud invalidates its connection, NeoAnki2 reconnects on the next sync
attempt while preserving pending uploads and downloaded changes. Reviews made
only on an iPhone or iPad can then continue syncing to an idle Mac without
turning sync off or resetting either library.

The iPhone and iPad **Sync Issues** view remains available for unresolved
operational failures. **Retry** attempts synchronization again; **Dismiss**
removes an issue record.

Review the summary before dismissing. Invalid remote batches are staged outside
domain tables and applied transactionally, so a rejected batch does not partly
rewrite the library.

**Current** describes this device's last completed sync attempt; it does not
confirm that every other device has caught up. Compare the same deck scope on
both devices at approximately the same time, because scheduled cards can become
due even when no new reviews are submitted.

When both apps are active, reviews, undos, and library edits update automatically.
Opening the app starts a catch-up check immediately. Large attachments can arrive
after the cards that reference them. A locked iPhone updates when iOS grants the
app background time.

## Troubleshoot iCloud

If one device is behind, inspect its sync status even if the other device says
**Current**. Each device has its own incoming queue. Failed incoming changes
are retained for retry; keep the library and sync settings intact while updating
the affected app so it can apply those saved changes.

If Status is **Account unavailable**:

1. Confirm the device is signed in to iCloud and is not using a managed account
   that restricts CloudKit.
2. Confirm the build is an officially provisioned build. Unsigned development
   builds cannot use the production container.
3. Reopen NeoAnki2, choose **Sync Now**, and check **Sync Issues**.

If Status says **Unavailable in this build**, there is nothing to retry from
that executable. Keep using the local library or install a build provisioned
for NeoAnki2's CloudKit container. Repeated launches remain safe and do not
create the pre-merge backup until sync can actually start.

If Status is **Offline**, keep studying locally, check the network and iCloud
service, then retry. Rate limits, a busy zone, and temporary CloudKit failures
also use the non-blocking Offline state.

If another device's edit seems missing, open both devices in turn, choose
**Sync Now**, and verify each says **Current**. Do not delete either local app
container as a sync remedy. Export important decks before destructive device or
iCloud account changes.

## Daily reminders

Open **Settings → Daily Reminder** and enable **Remind me**. NeoAnki2 requests
alert and sound permission at this point, even if you already allowed app-icon
badges. Choose a time and either **All
Decks** or one deck as the scope.

A reminder is scheduled only while that scope has due cards. When recalculation
finds zero due cards, NeoAnki2 removes the pending reminder. Tapping a reminder
deep-links into a study session for its scope.

If permission was denied, enable notifications for NeoAnki2 in iOS Settings,
then turn **Remind me** on again. Reminder preferences are local and do not sync
to other devices.

## App icon due count

The Mac Dock icon and the iPhone/iPad Home Screen icon show the number of cards
currently available to study across the whole library. Selecting one deck does
not narrow this count. Suspended cards and new cards deferred by daily limits
are excluded. The badge clears when no cards are due, even when a deck can
offer an extra study batch.
Switching the Mac window into or out of [Full Screen](../getting-started/#navigate-the-library)
does not change the library-wide due count shown by its Dock badge.

On Mac, iPhone, and iPad, NeoAnki2 requests badge permission when cards are first due.
Badges work with daily reminders and iCloud sync turned off. If badges are
disabled, allow **Badge application icon** on Mac or **Badges** on iPhone/iPad
for NeoAnki2 in system notification settings. Returning to the Mac app reapplies
the count even if it has not changed.

Counts refresh as you use the app and when you reopen it. iOS background refresh
can update the badge when the system grants execution time; it does not provide
an exact schedule while the app is closed.

## Due Cards widget

Add **NeoAnki2 — Due Cards** from the iOS widget gallery. Supported families
include small, medium, inline, circular, and rectangular widgets.

The widget shows only aggregate information: total due count, the next due time
when nothing is due, and up to three deck summaries in the medium family. It
never exposes prompts, answers, or saved responses. Tapping the widget starts
All Decks study; a deck row in the medium widget opens that deck's scope.

NeoAnki2 publishes a new snapshot after refreshes and library or study changes;
WidgetKit reloads on its own timeline. NeoAnki2 requests another timeline
after 30 minutes, but iOS may deliver it later. If data looks stale, open
NeoAnki2 and wait for Home to refresh. If the widget is empty, confirm the app
and widget were installed from the same signed build with the shared App Group
entitlement, then remove and re-add the widget.
