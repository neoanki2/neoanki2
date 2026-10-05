---
title: Support and issue reporting
description: Find runtime help and report NeoAnki2 issues without exposing private study data.
audience: user
nav_order: 41
parent: User Guide
---

# Support and issue reporting

For NeoAnki2 support, contact Oleksii Grachov at
[grachov.alexey@gmail.com](mailto:grachov.alexey@gmail.com). Include your app
version, device model, iOS/iPadOS or macOS version, and steps to reproduce the
problem. See the [privacy policy](../privacy/) for data-handling information.
The [third-party software notices](../third-party-notices/) reproduce the
upstream scheduling-code copyright notices and licenses.

Start with the [troubleshooting guide](../troubleshooting/) for startup,
library, import, media, recording, study, and scheduling symptoms. Preserve the
library before attempting recovery, and never publish its database or media.

Source-build, Git, Swift toolchain, signing, and Xcode failures belong in the
[Developer Guide](../developer/setup/), not the end-user troubleshooting path.

## Report an issue safely

Open a [GitHub issue](https://github.com/neoanki2/neoanki2/issues) with:

1. a short symptom and what you expected;
2. exact steps starting from launch;
3. your device model, iOS/iPadOS or macOS version, and NeoAnki2 app version;
4. whether you installed from the App Store, TestFlight, Homebrew, a direct
   DMG, or built from source;
5. the exact visible error message and, for a command failure, the relevant
   output; and
6. whether the problem also occurs after closing the app normally and opening
   it again once.

### iPhone and iPad

Find your device model and iOS/iPadOS version in **Settings → General → About**.
For TestFlight builds, include the version and build number shown in TestFlight.
For App Store installations, include the installed app version shown in
**Settings → General → iPhone Storage** or **iPad Storage → NeoAnki2**.

For optional iCloud sync, include the status shown in **NeoAnki2 → Settings →
iCloud Sync** and whether sync is enabled on each affected device. Do not send
your Apple Account password or private study content. For reminders, report
the selected time and scope and whether iOS allows NeoAnki2 notifications.

Do not delete and reinstall the app as a troubleshooting step without first
exporting your library. A reinstall can remove on-device study data and saved
spoken responses. Portable deck exports do not include those personal
recordings, so keep the app installed if you need to preserve them.

### Mac and source builds

For a source build, also include the output of:

```bash
sw_vers -productVersion
swift --version
git rev-parse HEAD
```

These commands run on the Mac used to build the app; iPhone and iPad users do
not need to run them.

Before posting, redact:

- your account name, Apple Account address, and home-directory path;
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
