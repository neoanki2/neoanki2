---
name: release
description: Merge release changes into main, publish affected NeoAnki2 apps to the Stores and Homebrew with one shared version, and upgrade the local Mac; preview, resume, or inspect a release. Use for release, ship, publish, or Homebrew/app-store release requests. Physical iPhone installation uses deploy-iphone instead.
---

# Release NeoAnki2

Every release must come from `main`. Merge first, then build and publish from
the resulting `main` revision:

1. Preserve and commit the requested local changes, include relevant existing
   release work, and create or update its PRs using authenticated `gh`. Complete
   required checks and merge the changes into `main`. Confirm that GitHub reports
   the PRs as `MERGED`; an auto-merge request or an open PR is insufficient.
2. Update a clean local `main` checkout to the remote `main` revision containing
   those changes. Preserve unrelated working-tree changes when switching or use
   an isolated checkout. Record the resulting `main` SHA as the release source;
   after a squash or rebase merge, use the resulting main revision rather than
   the original PR head.
3. Run the unified controller from that checkout only after confirming that it
   enforces this ordering:

```bash
./Scripts/release.sh
```

Current local changes are intentional release input and must be merged before
publication. Finish source integration before invoking the controller to reserve
a release version, build release artifacts, sign, upload, or publish. The
controller requires a clean checkout matching remote `main` and records that
revision as its source.
Artifacts, release tags, and receipts must identify the recorded `main` revision.
If required checks or branch protection block merging, stop before these release
phases and report the concrete blocker. Do not publish while auto-merge is queued
or bypass branch protection to proceed.

Starting the command on `main` is insufficient if the controller then creates a
release branch and publishes its unmerged snapshot. If its implementation or
the release guide still uses publication before merge, correct that ordering
before using the controller for publication.

After source integration, the command handles change detection, version
reservation, relevant headless checks, parallel builds, signing, Store
upload/submission, Homebrew publication, and receipts.
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
  Before resuming publication, verify that the saved source is a release prepared
  from `main` after its changes were merged. For an older unmerged candidate,
  integrate its changes first and prepare from the resulting `main` revision;
  do not relabel old artifacts or receipts as main-built. Preserve already
  published channels and their history. Read-only `--plan` and `--status` do not
  require a merge.
  Never blindly resend an uncertain upload, overwrite a reserved version, rerun
  an unchanged failed check, or downgrade a channel. Keep receipts and logs.
- Preserve Developer ID/Store signing, production CloudKit, privacy/package
  validation, and accepted Mac notarization. Do not strip quarantine or weaken
  signing. Use `gh` authentication for GitHub; never the GitHub connector.
- A release request includes upgrading this Mac after Homebrew publication.
  Refresh the tap, run `brew upgrade --cask neoanki2/tap/neoanki2`, verify the
  installed version and signature, and launch NeoAnki2 exactly once. Terminate
  the running app if necessary for a safe upgrade, preserving its library and
  settings. Perform this step rather than handing the user a command. An iOS-only
  release with no newer Mac version needs no local upgrade. Do not install
  TestFlight or manipulate Store containers; no other GUI interaction is allowed.

Read [the release guide](../../../docs/RELEASING.md) for setup, version examples,
checkpoint behavior, and recovery. Return selected versions/source, each channel's
actual state, the local installed version, and the receipt path. Name concrete blockers without inventing
acceptance passes or requesting confirmation already granted by the release request.
