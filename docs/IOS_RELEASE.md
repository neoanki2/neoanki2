---
title: iOS Release Checklist
description: Build, provision, verify, and upload NeoAnki2 for iPhone and iPad.
parent: Reference
---

# iOS and iPadOS release checklist

NeoAnki2 supports iOS/iPadOS 17 and newer. Local signing is team-neutral. The
repository contains the real application and widget targets, privacy manifest,
usage descriptions, icon, launch configuration, entitlements, versions, and
App Store Connect export options.

## Automated preflight

1. Run `swift test --parallel` and `bash Scripts/validate-architecture.sh`.
2. Run `bash Scripts/validate-xcode-build-paths.sh`.
3. Run `Scripts/build-ios.sh` for an unsigned simulator build. On a machine
   without an installed Simulator runtime, set `NEOANKI_SKIP_ASSETS=1`; CI must
   run the normal asset-catalog build.
4. Build `NeoAnkiiOS` in Release for `generic/platform=iOS` with signing
   disabled, then validate the application and embedded widget products.
5. Run iPhone SE/large iPhone/iPad UI journeys in portrait and landscape,
   light/dark, accessibility Dynamic Type, Reduce Motion, and Increased Contrast.

## Apple team provisioning

- Register `com.neoanki2.ios` and `com.neoanki2.ios.widget`.
- Register App Group `group.com.neoanki2.shared` and attach both targets.
- Create `iCloud.com.neoanki2.app`, enable private CloudKit, and attach the app.
- Enable push notifications and Background Tasks for the app identifier.
- Deploy the verified CloudKit schema from Development to Production.
- Create App Store distribution profiles for the app and widget and grant the
  release team access to the App Store Connect record.

## Functional release acceptance

- Install signed builds on two physical devices signed into different test
  iCloud accounts. Opt each device in independently; verify the pre-upload
  backup, offline edits, first merge, mutable conflict recovery, immutable
  review union, media transfer, push-triggered sync, and restart recovery.
- Verify reminders are requested only after opt-in and are removed when the
  selected scope has no due cards.
- Verify all widget families show only aggregate due information and deep-link
  into the chosen scope.
- Archive the app, validate it in Organizer/App Store Connect, export with
  `Platforms/iOS/ExportOptions.plist`, upload to TestFlight, and complete an
  internal tester install.

The signed two-device CloudKit test and TestFlight upload are the only expected
external blockers until a paid Apple Developer team is available.
