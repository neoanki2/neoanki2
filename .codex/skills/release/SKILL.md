---
name: release
description: Publish affected NeoAnki2 apps to iOS App Store, Mac App Store, and Homebrew with one shared version; preview, resume, or inspect that release. Use for release, ship, publish, or Homebrew/app-store release requests. Physical iPhone installation uses deploy-iphone instead.
---

# Release NeoAnki2

For a release request, run the repository's single command:

```bash
./Scripts/release.sh
```

Current local changes are intentional input. The command handles snapshot/PR,
change detection, version reservation, relevant headless checks, parallel builds,
signing, Store upload/submission, Homebrew publication, and receipts.
Do not reconstruct these phases or invoke the retired per-platform/fast/ship
entry points. Do not run a release merely because the user asks to develop or
edit the release process.

- iOS-only changes publish iOS. Mac-only changes publish Mac Store and Homebrew.
  Shared app dependencies select both. Docs/tests/controller changes alone do
  not release apps. `--plan` previews without publication.
- Every selected artifact uses the same marketing version and build. Unchanged
  apps retain their last version and skip that release number. Do not allocate
  independent Store/Homebrew versions.
- The controller runs relevant headless tests once. Do not add broad UI journeys,
  screenshot capture, fresh privacy browser reviews, physical acceptance, or
  independent review ceremonies to routine publication. Add checks only for the
  actual changed behavior or an explicit request.
- Store processing/review is external. Report uploaded, submitted, and available
  separately; automatic release after approval is not an approval guarantee.
- Resume with `./Scripts/release.sh --resume VERSION`; inspect with `--status`.
  Never blindly resend an uncertain upload, overwrite a reserved version, rerun
  an unchanged failed check, or downgrade a channel. Keep receipts and logs.
- Preserve Developer ID/Store signing, production CloudKit, privacy/package
  validation, and accepted Mac notarization. Do not strip quarantine or weaken
  signing. Use `gh` authentication for GitHub; never the GitHub connector.
- Publication does not install or launch apps. Do not install TestFlight,
  manipulate Store containers, replace the local Homebrew app, or launch GUI
  applications as part of release. A requested local upgrade is separate.

Read [the release guide](../../../docs/RELEASING.md) for setup, version examples,
checkpoint behavior, and recovery. Return selected versions/source, each channel's
actual state, and the receipt path. Name concrete blockers without inventing
acceptance passes or requesting confirmation already granted by the release request.
