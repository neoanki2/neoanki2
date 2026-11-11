---
title: Mac App Store Release
description: Native Mac Store signing and packaging in the unified release process.
audience: developer
parent: Developer Guide
permalink: /MAC_APP_STORE_RELEASE/
---

# Mac App Store releases

Use the [unified release process](RELEASING.md):

```bash
./Scripts/release.sh
```

Mac changes publish both Mac App Store and Homebrew using the same version/build
and immutable source. Shared changes also publish iOS; iOS-only changes leave
both Mac distributions alone. There is no separate Mac Store version counter.

The Store app uses `com.neoanki2.ios`, App Sandbox, user-selected file access,
production push and private production CloudKit. Homebrew uses
`com.neoanki2.app`, Developer ID signing, and accepted notarization. These are
intentionally different signed binaries with matching release numbers.

Store export requires the saved Apple Distribution certificate/key and the
Mac Installer Distribution certificate/key. The adapter validates production
profiles, actual bundled privacy manifests, universal architectures, signatures,
package version/source, and the upload receipt. It never tries to run the raw
Apple Distribution export or substitutes ad hoc/Developer ID signing for Store
signing. No TestFlight installation or desktop review is part of routine release.

`Packaging/AppStore/en-US.json` owns the native listing/reviewer information.
Keep screenshots and privacy disclosures accurate when product behavior changes.
The controller reuses them for ordinary releases, waits for canceled prior
submissions to finish, attaches the exact processed replacement build, and
submits for automatic release. See [Releasing NeoAnki2](RELEASING.md) for progress,
partial completion, retries, and version reservations. The old
`Scripts/release-macos-app-store.sh` publishing entry point is retired.

For a specifically requested native Store UI investigation,
`Scripts/review-macos-app.py` remains an optional tool. It requires the exact
Apple-re-signed TestFlight candidate and a fresh isolated test container. It
never deletes a user's Store library or turns failed/missing evidence into a
pass. Existing Homebrew libraries remain outside the Store sandbox; transfer
content using optional sync or portable deck files when requested.
