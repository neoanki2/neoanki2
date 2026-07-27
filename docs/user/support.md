---
title: Build, launch, and support
description: Diagnose source-build and runtime symptoms, then report NeoAnki2 issues without exposing private study data.
nav_order: 41
parent: User Guide
---

# Build, launch, and support

Start with the symptom you can observe. Commands below assume Terminal is at
the repository root unless stated otherwise.

## `git`, `swift`, or developer tools are missing

Run:

```bash
xcode-select -p
swift --version
git --version
```

Expected result: `xcode-select` prints an installed developer directory,
`swift --version` reports Swift 6, and Git reports a version. If macOS says a
command is unavailable, install or update Xcode or its Command Line Tools.

If Xcode is installed but not selected, use Xcode's **Settings → Locations →
Command Line Tools** to select it, then repeat the checks. Do not change the
selected developer directory unless you know which installed Xcode should own
the build.

After a new Xcode installation, open Xcode once and allow it to install required
components. Accept the displayed license before returning to Terminal. If
Terminal still reports initialization or license errors, finish those prompts
in Xcode rather than running undocumented privileged workarounds.

## Swift reports a version older than 6

The package declares Swift tools 6.0 and macOS 14. An older compiler cannot
build it. Update Xcode, select that Xcode's command-line tools, and verify:

```bash
swift --version
```

Expected result: the first line contains `Swift version 6`.

## Clone fails

Use the public HTTPS URL:

```bash
git clone https://github.com/neoanki2/neoanki2.git
```

- **Destination path already exists:** use the existing checkout or choose a
  different empty parent directory; do not clone on top of files.
- **Network, DNS, proxy, or authentication error:** confirm GitHub is reachable
  in your environment. The public HTTPS clone should not require a GitHub
  credential.

## Build stops with an error

First confirm you are in the checkout:

```bash
test -f Package.swift && test -x Scripts/run-app.sh && echo "Repository root OK"
```

Expected result: `Repository root OK`.

Then rerun the supported build path and preserve its complete output:

```bash
./Scripts/run-app.sh
```

A success ends with **App bundle ready at .../.build/NeoAnki2.app** followed by
**Launching NeoAnki2...**. The script runs `swift build -c debug`, copies the
executable into an app bundle, clears extended attributes, and ad-hoc signs the
bundle. The first error before those success lines is usually the useful one.

Do not delete the library to fix a compiler or signing error. Build artifacts
are under `.build/`; user data is in Application Support and is independent of
the checkout.

## The bundle is ready, but no window appears

Try the Terminal-attached mode:

```bash
./Scripts/run-app.sh cli
```

Expected result: **Building NeoAnki2...**, then **Running NeoAnki2...**, and an
app window while that Terminal process remains active. Any runtime diagnostic
stays visible in Terminal and is useful in an issue report.

If another NeoAnki2 process is already running, quit it normally and retry
once. If CLI mode opens the window but bundle mode does not, report that
distinction.

## The app shows `Could Not Start`

This means the app launched but could not open or bootstrap its local library.
Do not repeatedly rebuild: follow [Startup problems in
Troubleshooting](../troubleshooting/#startup-problems). Preserve the complete
library folder before restoring a backup or seeking help.

## The app opens, but content seems missing

Confirm the selected sidebar scope. **All Decks** includes every item;
**Unassigned** includes only items without a deck. Rebuilding or deleting
`.build/NeoAnki2.app` does not delete the normal library.

The normal data location is:

```text
~/Library/Application Support/neoanki2/
```

Do not move, edit, or publish files from that folder while diagnosing the UI.
See [safe backup and recovery](../troubleshooting/#where-the-library-is-stored).

## Report an issue safely

Open a [GitHub issue](https://github.com/neoanki2/neoanki2/issues) with:

1. a short symptom and what you expected;
2. exact steps starting from launch;
3. whether you used bundle mode or `./Scripts/run-app.sh cli`;
4. macOS, Swift, and source revision output:

   ```bash
   sw_vers -productVersion
   swift --version
   git rev-parse HEAD
   ```

5. the first relevant error and enough surrounding output to show which
   command failed; and
6. whether the problem also occurs after quitting normally and retrying once.

Before posting, redact:

- your macOS account name and home-directory path;
- item prompts, answers, tags, deck names, and media descriptions;
- screenshots containing private study material or filenames;
- imported source content and absolute paths;
- access tokens, credentials, remote URLs containing usernames, and other
  secrets.

Do **not** attach `neoanki2.sqlite`, the `media/` directory, a complete library
backup, or private import files to a public issue. Those can contain the
knowledge you study, review history, scheduling state, and original media.
Create a minimal disposable example instead: a new item with neutral text such
as `Question` / `Answer`, or a tiny synthetic import that reproduces the
problem. Never modify your only library copy to make a reproduction.

The repository does not currently document a built-in diagnostic export or a
private support-upload channel. If maintainers request more data, agree on a
private, minimal transfer before sharing it.

---

**Next:** [Troubleshoot app behavior](../troubleshooting/)

**Related:** [Getting started](../getting-started/) · [Shortcuts and accessibility](../shortcuts-accessibility/)
