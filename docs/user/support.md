---
title: Support and issue reporting
description: Find runtime help and report NeoAnki2 issues without exposing private study data.
audience: user
nav_order: 41
parent: User Guide
---

# Support and issue reporting

Start with the [troubleshooting guide](../troubleshooting/) for startup,
library, import, media, recording, study, and scheduling symptoms. Preserve the
library before attempting recovery, and never publish its database or media.

Source-build, Git, Swift toolchain, signing, and Xcode failures belong in the
[Developer Guide](../developer/setup/), not the end-user troubleshooting path.

## Report an issue safely

Open a [GitHub issue](https://github.com/neoanki2/neoanki2/issues) with:

1. a short symptom and what you expected;
2. exact steps starting from launch;
3. whether you installed with Homebrew, a direct DMG, or built from source;
4. macOS and NeoAnki version information; for a source build also include:

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
