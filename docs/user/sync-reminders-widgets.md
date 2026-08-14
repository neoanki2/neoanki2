---
title: iCloud, Reminders, and Widgets
description: Opt in to private CloudKit sync, recover sync issues, schedule due-card reminders, and use the iOS widget.
nav_order: 8
parent: User Guide
permalink: /user/sync-reminders-widgets/
---

# iCloud, Reminders, and Widgets

iCloud sync is available in provisioned Mac, iPhone, and iPad builds. Daily
reminders and the Due Cards widget are iPhone/iPad services. The library remains
usable offline and each device keeps its own service preferences.

This guide follows the current `main` source. Before relying on sync in an
installed build, check that build's release notes and entitlements; an older
public Mac release or unsigned contributor build can operate locally without a
usable CloudKit container.

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Set up iCloud sync](#set-up-icloud-sync)
- [What syncs](#what-syncs)
- [Sync status and issues](#sync-status-and-issues)
- [Troubleshoot iCloud](#troubleshoot-icloud)
- [Daily reminders](#daily-reminders)
- [Due Cards widget](#due-cards-widget)
</nav>

## Set up iCloud sync

CloudKit is off until you opt in on each device:

1. Sign in to iCloud in system Settings and confirm iCloud Drive is available.
2. On iPhone or iPad, open NeoAnki2 **Settings** and choose **Enable iCloud
   Sync…**. On Mac, open **NeoAnki2 → Settings → iCloud** and turn on **Sync
   this Mac**.
3. Read the consent message, then choose **Create Backup & Enable**.
4. Keep the app open until Status becomes **Current**, or open **Sync Issues**
   if it becomes **Needs attention**.
5. Repeat these steps on every other Mac, iPhone, or iPad you want to sync.
   Consent is deliberately device-local.

Before its first upload, NeoAnki2 creates and verifies a SQLite backup in the
app container. It then merges the local and private CloudKit libraries; neither
library is silently replaced wholesale. Local SQLite remains authoritative, so
authoring and study continue when the network or iCloud is unavailable.

Use **Sync Now** for an immediate attempt. NeoAnki2 also synchronizes when it
becomes active, after debounced local changes, and during system-granted
background refresh. Background timing is controlled by iOS and is not an exact
schedule.

Turning off **Sync this device** on iOS or **Sync this Mac** on macOS stops that
device's sync and leaves its local library intact. It does not erase the private
CloudKit library or change other devices.

## What syncs

Private CloudKit sync includes decks, item types and templates, items, card
state, immutable review and revert history, and shared content-addressed media.
Immutable history is unioned deterministically. Concurrent edits to mutable
resources accept one version while preserving the other as a conflict copy
when it can be restored.

These remain local to each device:

- the iCloud opt-in itself;
- reminder time and scope;
- installed offline vocabulary packs;
- persistent Audio Submission recordings and their private-only media; and
- widget snapshots, which contain aggregate due information only.

Use portable deck export when you need an explicit file transfer or archive.

## Sync status and issues

**Offline** means local work is available but CloudKit cannot currently
transfer. **Syncing** means a batch is in progress. **Current** means the last
attempt completed without a retained issue. **Account unavailable** means the
iCloud account, entitlement, or container cannot be used. **Needs attention**
means one or more recoverable batches or conflicts were preserved.

On iPhone or iPad, open **Sync Issues** to inspect each issue:

- **Retry** removes that issue and attempts synchronization again.
- **Restore as New Copy** recreates a preserved mutable resource with a new
  identity, keeping both versions.
- **Dismiss** removes the issue record without restoring its conflict copy.

Review the summary before dismissing. Invalid remote batches are staged outside
domain tables and applied transactionally, so a rejected batch does not partly
rewrite the library.

The current Mac settings panel reports the issue count but does not expose the
mobile restore and dismiss controls. Use a synced iPhone or iPad to inspect a
restorable issue, or preserve both local libraries and report it before making
destructive changes.

## Troubleshoot iCloud

If Status is **Account unavailable**:

1. Confirm the device is signed in to iCloud and is not using a managed account
   that restricts CloudKit.
2. Confirm the build is an officially provisioned build. Unsigned development
   builds cannot use the production container.
3. Reopen NeoAnki2, choose **Sync Now**, and check **Sync Issues**.

If Status is **Offline**, keep studying locally, check the network and iCloud
service, then retry. Rate limits, a busy zone, and temporary CloudKit failures
also use the non-blocking Offline state.

If another device's edit seems missing, open both devices in turn, choose
**Sync Now**, and verify each says **Current**. Do not delete either local app
container as a sync remedy. Export important decks before destructive device or
iCloud account changes.

## Daily reminders

Open **Settings → Daily Reminder** and enable **Remind me**. NeoAnki2 requests
notification permission only at this point. Choose a time and either **All
Decks** or one deck as the scope.

A reminder is scheduled only while that scope has due cards. When recalculation
finds zero due cards, NeoAnki2 removes the pending reminder. Tapping a reminder
deep-links into a study session for its scope.

If permission was denied, enable notifications for NeoAnki2 in iOS Settings,
then turn **Remind me** on again. Reminder preferences are local and do not sync
to other devices.

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
