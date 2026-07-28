---
title: Getting started
description: Verify the macOS toolchain, clone NeoAnki2, and launch its development app bundle.
nav_order: 1
parent: User Guide
---

# Getting started

NeoAnki2 is a native, local-first macOS spaced-repetition app. The project does
not currently publish releases, installers, or a signed application download.
To use it today, build it from source.

## Before you start

You need:

- macOS 14 or newer;
- Git; and
- Xcode or Xcode Command Line Tools with a Swift 6 toolchain.

The package itself declares macOS 14 and Swift tools 6.0. There is no end-user
Xcode project; the included scripts build the Swift package.

In Terminal, verify the prerequisites:

```bash
sw_vers -productVersion
xcode-select -p
swift --version
git --version
```

Expected results:

- `sw_vers` begins with `14` or a newer major version.
- `xcode-select` prints a developer directory such as
  `/Applications/Xcode.app/Contents/Developer` or
  `/Library/Developer/CommandLineTools`.
- `swift --version` reports Swift 6.
- `git --version` reports an installed Git version.

If a command is missing or Swift is older than 6, install or update Xcode,
select its developer tools, and repeat these checks. See [build and launch
support](../support/) before trying workarounds.

## Clone the source

Choose a parent directory, then run these exact commands:

```bash
git clone https://github.com/neoanki2/neoanki2.git
cd neoanki2
```

Expected result: Git prints that it cloned into `neoanki2`, and the second
command leaves Terminal at the repository root. If you already have this
checkout, do not clone it again; open Terminal at its root instead.

## Build and launch

From the repository root, run:

```bash
./Scripts/run-app.sh
```

The first build may need longer than later builds. A successful run includes:

```text
Building NeoAnki2...
App bundle ready at .../.build/NeoAnki2.app
Launching NeoAnki2...
```

The script builds a debug executable, assembles and ad-hoc signs
`.build/NeoAnki2.app`, then asks macOS to open it. The app window should appear
at **All Decks**. The bundle stays inside the checkout; nothing is installed in
`/Applications`.

To keep the process attached to Terminal instead, run:

```bash
./Scripts/run-app.sh cli
```

Expected result: Terminal prints **Building NeoAnki2...** and **Running
NeoAnki2...**, then the app window appears. Keep that Terminal window open
while this mode is running.

## Install to /Applications

Running from the checkout means launching through a script every time. To use
NeoAnki2 the way you use any other Mac app — Spotlight, Launchpad, the Dock —
install it:

```bash
./Scripts/install-app.sh --restart
```

Expected result:

```text
Building NeoAnki2 (release)...
Assembling NeoAnki2.app...
Installing to /Applications/NeoAnki2.app...
Installed NeoAnki2 (abc1234, build 90) at /Applications/NeoAnki2.app
```

This is a release build, not the debug build `run-app.sh` produces, and it is
signed with no entitlements — the test bundle grants itself debugger attachment
and Apple Events so automated tests can drive it, and the copy you study with
does not need either. The commit it came from is recorded in the bundle, so you
can always tell which build you are running:

```bash
/usr/libexec/PlistBuddy -c 'Print :NeoAnkiGitRevision' \
  /Applications/NeoAnki2.app/Contents/Info.plist
```

A `-dirty` suffix means the checkout had uncommitted changes when you installed.

`--restart` quits a running NeoAnki2 before replacing it and launches the new
build afterwards. Without that flag, a running instance stops the install rather
than risking two processes writing one library. To install somewhere else, pass
`--dest ~/Applications`.

Your library lives in `~/Library/Application Support/neoanki2/` either way, so
the installed app and a build launched from the checkout read the same data.
Never run both at once.

## Update the development build

Quit NeoAnki2, preserve a current library backup, then run from the checkout:

```bash
git status --short
git pull --ff-only
./Scripts/run-app.sh
```

Expected result: `git status` is empty before the update, Git fast-forwards (or
reports that the checkout is current), and the rebuilt app launches. If status
shows local source changes, do not discard them blindly; commit, move, or review
them before pulling. If the updated build reports that an older build cannot
read the library, return to the updated build or restore a compatible backup.

If you installed to `/Applications`, substitute `./Scripts/install-app.sh
--restart` for `./Scripts/run-app.sh` in that sequence. Pulling new source does
not change the installed app until you install again.

## Uninstall or remove the checkout

1. Quit NeoAnki2.
2. Delete the source checkout to remove source code, `.build/NeoAnki2.app`, and
   build artifacts.
3. If you installed to `/Applications`, drag `NeoAnki2.app` to the Trash as well.
4. To keep your study data for a future checkout, stop here.
5. To remove all NeoAnki2 data too, first make any backup you intend to keep,
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

NeoAnki2 uses focused, detail-only modes while adding an item, managing item
types, or studying. The sidebar collapses automatically to make room, but can
still be revealed with the normal sidebar control. Leaving the task restores
the full split view. Reduced Motion is respected when these columns change.

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

**Related:** [Build and launch support](../support/) · [Concepts and glossary](../concepts/)
