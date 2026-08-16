---
title: Troubleshooting
description: Match NeoAnki2 app symptoms to safe recovery steps without risking the local library.
audience: user
nav_order: 10
parent: User Guide
---

# Troubleshooting

NeoAnki2 reports recoverable problems in an error banner or alert. With
VoiceOver, the message is announced and focused. Read the complete message
before retrying; it normally identifies the missing file, invalid field, data
requirement, or unavailable action.

## Find your symptom

- **A Terminal command, build, signing step, or launch failed:** use [Build,
  launch, and support](../support/).
- **The app says Could Not Start:** see [Startup problems](#startup-problems).
- **iCloud, a reminder, or the widget is not current:** use [iCloud, reminders,
  and widgets](../sync-reminders-widgets/#troubleshoot-icloud).
- **The app looks empty, loading, or caught up:** see [Empty and loading
  states](#empty-and-loading-states).
- **Import or export failed:** see [Import and export errors](#import-and-export-errors).
- **An item, cloze, or media file cannot be saved:** see [Item and media
  errors](#item-and-media-errors).
- **Recording is unavailable:** see [Microphone and recording](#microphone-and-recording).
- **Study shows a message, or you are looking for an optimization command:** see
  [Study and scheduling messages](#study-and-scheduling-messages).
- **You need to report a reproducible bug:** follow [safe issue-report and
  redaction guidance](../support/#report-an-issue-safely).

## Where the library is stored

The normal library is local to your macOS user account:

```text
~/Library/Application Support/neoanki2/
  neoanki2.sqlite
  media/
  Vocabulary Packs/
```

The SQLite file contains decks, item types, items, generated cards, review
history, and scheduling state. Imported media is copied into the adjacent
managed `media` directory with content-addressed filenames.
Validated offline dictionaries are immutable `.neovocab` directories under
`Vocabulary Packs`; both the app and the local API read that same managed
location. Do not rename, edit, or partially copy an installed pack while
NeoAnki2 is running.

For a safe manual backup:

1. Quit NeoAnki2 completely.
2. Copy the entire `neoanki2` folder, including the database and `media`.
3. Keep the copy on a reliable, access-controlled volume.

Do not edit the database, rename managed media, replace individual files while
the app is running, or open a `.neodeck` as the library database. A `.neodeck`
omits learner progress and is not a complete backup.

To restore a complete backup safely:

1. Quit NeoAnki2 and confirm no Terminal-attached instance remains.
2. In `~/Library/Application Support/`, rename the current `neoanki2` folder to
   a dated name such as `neoanki2-damaged-2026-07-27`. Preserve it until the
   restore is verified.
3. Copy the backed-up **whole** `neoanki2` folder into Application Support.
   Do not merge individual database or media files.
4. Confirm your macOS account can read and write the restored folder.
5. Launch the same or a newer compatible NeoAnki2 source revision. Check
   **All Decks**, open an item containing media, and confirm due counts appear.
6. If verification fails, quit immediately, preserve the failed restored copy,
   and put the renamed original folder back before seeking support.

Do not use a build older than the one that last opened the backup. Cloud-syncing
the live folder while NeoAnki2 is running has not been validated as a backup
method.

## Startup problems

During launch, **Starting…** is normal briefly. **Could Not Start** means the
library could not be opened or bootstrapped.

[![Could Not Start state with a local-library error]({{ site.baseurl }}/assets/screenshots/error-startup.png)]({{ site.baseurl }}/assets/screenshots/error-startup.png)

The documentation shows this state in dark appearance; the same recovery text
and icon appear when macOS uses light appearance.

- **Couldn't open your library:** confirm the Application Support folder is
  available and writable. If it is on redirected or managed storage, restore
  normal access, then relaunch.
- **Created by a newer version:** do not force it open with an older build.
  Return to the newer compatible build or restore a backup made by this build.
- **Couldn't read this library / database may be damaged:** quit the app,
  preserve the current folder as evidence, and restore a known-good complete
  backup. Do not run ad hoc SQLite repair commands on your only copy.
- **Some library data couldn't be read:** preserve the library and restore a
  backup or seek support. Item Types may separately offer a controlled
  **Archive Original and Repair** action for an unreadable type; it preserves
  the damaged definition and does not delete existing items.

## Empty and loading states

These states are informational:

- **No decks yet:** create a top-level deck with **New Deck**. Items may still
  exist under **All Decks** or **Unassigned**.
- **No Items Yet:** add an item; templates generate its cards.
- **No Items in Deck:** add an item while that deck is selected.
- **No Unassigned Items:** every item currently belongs to a deck.
- **No Item Types:** create an item type to define fields and templates.
- **Select an Item Type:** choose a type in the left pane.
- **No Templates:** add a template; an item without templates generates no
  study cards.
- **You're caught up / Nothing Due Right Now:** there is nothing due in the
  current scope. The scope home names the time the next card returns; this is
  not a scheduling error.
- **Session Complete:** all due cards loaded for that session were handled.

**Loading decks…**, **Loading items…**, **Loading item types…**, **Loading due
cards…**, **Importing…**, and **Transferring deck…** indicate active work. Avoid
starting another transfer. If a state never completes, quit normally, relaunch,
and retry once.

If **Settings** temporarily shows only the Study tab during startup, wait for
the library to finish opening. Local API and iCloud settings appear once their
library-backed services are ready.

## Import and export errors

- **Choose a JSON or CSV file:** use the File import for `.json`/`.csv`, or
  **Import Deck…** for `.neodeck`/`.neoanki`.
- **File larger than 5 MB / row or field limit:** split a JSON or CSV import
  into smaller valid files.
- **No item type named…:** create that item type first or correct JSON's
  `itemType`. CSV lets you choose an existing type in the sheet.
- **Unknown field / required value missing:** make headers and JSON keys match
  the selected type exactly, and supply every required field.
- **Relative media paths:** choose the folder against which those paths
  resolve. Keep every referenced file inside it, with the expected kind and
  supported signature.
- **Could not read/open selected file:** verify it still exists, is a regular
  accessible file, and is not being replaced by another process; choose it
  again.
- **Item Type Conflict:** choose **Use Matching Local Type** only for an exact
  schema match, **Import as New Type** to keep the revision, or **Cancel**.
- **Unsupported portable version / invalid package:** obtain a valid file from
  a compatible NeoAnki2 build. Renaming another file to `.neodeck` does not
  convert it.
- **Add Item asks me to choose a type:** the deck offers several included
  types and its author did not declare a default. Choose the matching type
  under **For This Deck**; Basic and other reusable types remain under
  **Item Types**.
- **An imported type is missing from the main list:** expand **Included with
  Decks** in Item Types. Included-only schemas start read-only and are grouped
  by their owning deck. Use **Unlock for Editing…** to adopt the existing
  definition and update its existing items, or **Duplicate as Item Type…** for
  an independent copy.
- **Disk is full / could not export:** free space and choose a writable
  destination. Failed portable transfers are atomic and should not leave
  imported partial content.

Successful JSON, CSV, authored, and portable imports do not deduplicate item
content. If duplicates were imported, delete the unwanted items manually;
reimporting again will add more copies.

## Item and media errors

- **Required field:** enter a nonblank value. Images and GIFs also require an
  image description for VoiceOver.
- **Invalid item type:** check that field names are unique and templates have
  complete prompt, answer, interaction, and generation settings.
- **Cloze error:** enter text, select at least one character, avoid overlapping
  blanks, and mark again if edits made a saved range stale.
- **Unsupported or ambiguous media:** choose a standard file of the requested
  kind. A filename extension alone is not enough; NeoAnki2 checks file bytes.
- **File too large:** choose a smaller file. Current per-file limits depend on
  media kind.
- **Media file couldn't be read / invalid location:** confirm the source still
  exists and choose it again. Import only from locations macOS allows the app
  to access.
- **Image unavailable / preview unavailable:** the managed media may be missing
  or unreadable. Restore the complete database-and-media backup together.

Supported authored media is documented in the
[authored deck format]({{ site.baseurl }}/AUTHORED_DECK_FORMAT/). Active content such as
HTML, SVG, scripts, and playlists is intentionally unsupported.

## Microphone and recording

Record cards ask for microphone permission the first time recording starts. If
access is off, open **System Settings → Privacy & Security → Microphone**,
enable NeoAnki2, then retry. A managed Mac may show **restricted** access that
only an administrator can change.

If recording cannot start, check the selected/input microphone in macOS and
retry. Use **Command-R** to start or stop, and **Command-P** to play back. Study
recordings are temporary comparison aids: they are created in the system
temporary directory and removed when replaced, when the card changes, or when
the study view closes. They are not attached to the item or retained as review
history.

Audio Submission cards are different: the draft stays temporary until you
choose **Save & Complete**, then it appears under **Library → Saved Responses**.
If saving fails, use the inline retry while the draft is retained. Submitted
responses are persistent on this device but are not uploaded through Cloud sync.

## Study and scheduling messages

- **Enter an answer, or reveal it to self-grade:** type a nonblank response, or
  use Right Arrow.
- **No usable answer options / nothing to arrange / no checkable answer:** the
  card's content cannot support automatic checking. Review the revealed answer
  and self-grade; then fix the item or template.
- **There is no recent review to undo:** undo is no longer available for this
  state.
Scheduling optimization reports nothing, successfully or otherwise: it runs
automatically at the end of a session and only when review history warrants it.
If you are looking for an **Optimize Scheduling** command, there isn't one, and
its absence is not a fault. A library with under 400 usable interday review
outcomes across at least 100 cards has simply not been fitted yet; keep studying
normally. Optimization counts usable later reviews in card histories, not
simply every button press. When a fit
cannot be made or saved, the parameters already in use continue to schedule
normally and a later session tries again.

All current interaction types—reveal, type, choose, record, audio submission, cloze, and
arrange—are supported. Automatic correctness checking can still be unavailable
when a card lacks suitable answer content; grading remains self-assessed.

For iPhone/iPad iCloud status, retained conflicts, notification permission, or
stale widget data, use the dedicated [iCloud, reminders, and widgets
guide](../sync-reminders-widgets/). These services are intentionally
non-blocking: an Offline sync state or denied reminder permission does not make
the local library unavailable.

## Intentional limitations

NeoAnki2 currently has no Anki `.apkg`/`.colpkg` import or export, shared-deck
catalog, HTML/CSS rendering, `{{Field}}` templates, progress-bearing portable
export, or legacy SM-2 scheduler. Do not work around these limits by renaming
files or injecting HTML into text fields.

---

**Next:** [Build, launch, and issue-report support](../support/)

**Related:** [Task index](../tasks/) · [Shortcuts and accessibility](../shortcuts-accessibility/)
