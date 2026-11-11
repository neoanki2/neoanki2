---
title: iOS Release Checklist
description: iPhone and iPad signing details for the unified release command.
audience: developer
parent: Developer Guide
permalink: /IOS_RELEASE/
---

# iOS and iPadOS releases

Use the [unified release process](RELEASING.md):

```bash
./Scripts/release.sh
```

It publishes iOS only when mobile/shared production inputs changed and assigns
the same release version/build used by every other selected distribution. It
builds the Release archive and widget, signs through a disposable Keychain,
validates privacy manifests and provisioning, uploads once, waits for Apple's
processed build, reuses the listing/screenshots, and submits for automatic release.
There is no separate iOS version counter or routine UI-review ceremony.

The bundle IDs remain `com.neoanki2.ios` and `com.neoanki2.ios.widget`, the App
Group is `group.com.neoanki2.shared`, and optional sync uses the private
`iCloud.com.neoanki2.app` production container. Existing saved App Store Connect
credentials and distribution certificate/key are used; no Apple ID or Keychain
password is requested. Account agreements, an initial complete listing, current
privacy disclosures, and deployed production schema must already be configured.

`Platforms/iOS/AppStore/en-US.json` owns listing/reviewer details. Update App
Privacy when collection behavior changes, and replace screenshots when UI changes
make existing images inaccurate. Ordinary code releases reuse accurate assets;
they do not require fresh browser screenshots of unchanged declarations.

Receipts and recovery use `.build/releases/VERSION/` and `release-state.json` as
explained in [Releasing NeoAnki2](RELEASING.md). Upload, submitted, reviewed, and
publicly available are separate states. Apple controls review/availability.
The old `Scripts/release-ios.sh` publishing entry point is retired.

For explicit UI investigations, `Scripts/review-ios-app.py` and
`Scripts/capture-ios-app-store.py` remain available. They use owned disposable
Simulators and retain actual XCTest evidence; they are not default release gates.
Physical iPhone installation remains the separate
[deployment workflow](user/developer/setup.md), which does not publish a release.
