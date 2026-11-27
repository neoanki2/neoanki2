---
name: release
description: Merge release changes into main, publish affected NeoAnki2 apps to the Stores and Homebrew with one shared version, update the local Mac and paired iPhone, and clean up disposable release artifacts; preview, resume, or inspect a release. Use for release, ship, publish, or Homebrew/app-store release requests. Standalone physical iPhone installation uses deploy-iphone.
---

# Release NeoAnki2

## Time every release

The first action on a release request is to capture the UTC start time, before
inspecting the candidate, running checks, or invoking the controller. Append
the start to `neoanki2-release-timings.jsonl` in the directory returned by
`git rev-parse --path-format=absolute --git-common-dir`. Use this one append-only
JSON Lines history across linked worktrees and releases. Read-only previews
and status checks do not create timing entries.

- Put `release_id`, UTC `timestamp`, `phase`, and `event` on every new line.
  Assign the release ID before a version is reserved, then record the version,
  build, and source revision as they become known. Log each attempt's start,
  stop, and reason under the same release ID, including resumes and replacement
  candidates pursued to finish the same release request.
- Log phase starts, ends, and outcomes for candidate preparation, local checks,
  GitHub checks and merge, builds and signing, publication, local installations,
  and cleanup. Use timestamps from controller logs and
  receipts when available. Mark missing timings as unknown. Identify external
  waits and count overlapping phases only once when assessing elapsed time.
- Immediately before each final report, append its outcome and
  `elapsed_seconds` measured from the first start. Include pauses, retries,
  and cleanup. Record blocked reports and leave their release
  IDs open for resumption. A completed, abandoned, or no-op release closes its
  entry.
- Include a timing table with the current release and the four most recent
  completed versions. Give the selected channels, request-to-publication time,
  controller-to-publication time, and total delivery time for each, plus the
  absolute path to the timing log. Publication means every selected channel
  has been published or accepted for Store review. Use the first complete
  publication checkpoint or the earliest recorded confirmation. Report deferred
  delivery and later workflow changes separately. Use the delivery and cleanup
  milestone when later work extended the last completion entry. Skip abandoned
  releases. Label reconstructed intervals and mark missing measurements as unknown.
- For each PR candidate, record the CI run, revision, duration, and outcome.
  Show how much time elapsed before merge and how much was spent on failed
  candidates and their corrections. Measure from timestamps and count overlaps
  once.

## Integrate the release source

Every release must come from `main`. Merge first, then build and publish from
the resulting `main` revision:

1. Preserve and commit the requested local changes, including relevant existing
   release work. Complete the local pre-push checks below before publishing the
   branch or any PR update through authenticated `gh`. Push one validated batch,
   then create or update its PR. Complete required GitHub checks and merge into
   `main`. Confirm that GitHub reports the PR as `MERGED`; an auto-merge request
   or an open PR is insufficient.
2. Update a clean local `main` checkout to the remote `main` revision containing
   those changes. Preserve unrelated working-tree changes when switching; do not
   create a worktree or isolated checkout unless the user explicitly asks.
   Record the resulting `main` SHA as the release source; after a squash or
   rebase merge, use the resulting main revision rather than the original PR
   head.
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

## Local checks before every push

Enable the repository's pre-push hook with
`git config --local core.hooksPath Scripts/githooks`. Commit the intended
changes locally and integrate the latest GitHub main in this checkout. The
hook verifies the actual pushed commit and current GitHub main through
authenticated `gh`. It requires the pinned app CI Xcode build and runs the
full PR unit suites, strict documentation, and the generated API freshness
check when affected. Use focused tests while iterating to catch failures
before this full run.

- GitHub's `.github/workflows/test.yml` is unit-only. Keep broader checks local
  before pushing: use the relevant campaign path filters in the manual
  `.github/workflows/validation.yml` to select additional headless checks, such
  as `Scripts/check-editor-test-sensitivity.py` or
  `Scripts/check-sync-test-sensitivity.py`, with fresh evidence directories.
  Do not add Simulator campaigns, screenshots, or physical acceptance checks.
  When CI orchestration changes, validate the workflow and budget for cold builds;
  local warm timings do not prove it fits. Keep platform builds, archives, and
  mutation campaigns out of automatic unit-test CI.
- For changed scheduling/cache or asynchronous behavior, ensure the relevant
  regression coverage uses explicit clock boundaries and observable operation
  gates. Keep those regressions in CI or the relevant manual campaign.

Keep the candidate HEAD, base SHA, hook output, and unit lane logs under
`.build/release-prepush/`. A failure blocks the push until its cause is fixed.
Run the hook again after changing the candidate.
The controller reuses a successful CI Gate result when it can prove that the
workflow tested the exact merged tree. Otherwise it runs the affected suites
from the pinned source. When retiring a required check, reconcile
its GitHub branch-protection context through `gh` without weakening other rules;
the unit-only workflow retains the **CI Gate** context. Do not dispatch the retired
Documentation PR gate or manual extended validation just to satisfy old check names.

## Publish from merged main

Starting the command on `main` is insufficient if the controller then creates a
release branch and publishes its unmerged snapshot. If its implementation or
the release guide still uses publication before merge, correct that ordering
before using the controller for publication.

After source integration, the command handles change detection, version
reservation, relevant headless checks, parallel builds, signing, Store
upload/submission, Homebrew publication, and receipts.
After publication finishes, it also runs the local iPhone deployment automatically.
Do not reconstruct these phases or invoke the retired per-platform/fast/ship
entry points. Do not run a release merely because the user asks to develop or
edit the release process.

- iOS-only changes publish iOS. Mac-only changes publish Mac Store and Homebrew.
  Shared app dependencies select both. Docs/tests/controller changes alone do
  not release apps. `--plan` previews without publication.
- Every selected artifact uses the same marketing version and build. Unchanged
  apps retain their last version and skip that release number. Do not allocate
  independent Store/Homebrew versions.
- The controller reuses exact-tree CI evidence or runs relevant headless tests
  when that evidence is unavailable. Do not add broad UI journeys,
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
- Every release also includes updating the user's paired iPhone. The controller
  invokes `./Scripts/deploy-iphone.sh` with pinned source and the latest released
  iOS version/build, verifies the device-reported installed version, and saves
  local receipts and live `IPHONE_DEPLOY_*` telemetry. A Mac-only release keeps
  the latest iOS version. An already-current phone skips installation. Do not
  launch the app as a delivery gate or repeat a successful deployment.
  Preparation requires no phone. Do not request connection/unlock before CI,
  publication, build, and signing finish. Do not ask the user to keep the phone
  awake or confirm readiness. An available wired/wireless paired phone is used
  automatically. Only if the installer emits `waiting_for_device`, tell the user
  the update is ready and to connect the phone; connection is detected without a
  reply. An unlock is requested only for an actual Apple-reported requirement.
  Use `./Scripts/release.sh --resume VERSION --device NAME_OR_IDENTIFIER` if the
  user must choose among multiple available phones. An unavailable phone or
  signing/install failure blocks local completion; resolve the stated cause and
  resume without repeating Store uploads or preparing the signed package again.
  A successful install resumes verification alone. An uncertain install requires
  inspecting its receipt before recovery; never send it again blindly.
  Do not claim release completion or clean up its recovery inputs
  until both applicable local installations are verified. This installation is
  part of release delivery, not a physical acceptance test.

## Cleanup

Finish a release by reclaiming its disposable outputs, including older completed
releases. Acquire the release lock and confirm `release.json` has `complete: true`
and every selected channel is `published`, `submitted`, or `available`. Complete
the current release's applicable local Mac upgrade and iPhone installation first.
The local `release.json` must show `local_iphone.status: installed` with its
verified deployment receipt. `complete: true` records publication completion
only and is insufficient for cleanup on its own. Pending Apple review does not
require retaining build directories; pending processing, failed/abandoned
releases, and uncertain uploads must retain their recovery inputs.

- Keep receipts/checkpoints, local-upgrade and iPhone deployment verification,
  original validation and delivery logs, checksums, signing/notarization evidence, and production debug
  symbols. Preserve matching dSYMs/symbol maps before deleting archives or build
  trees; retain exact shipped executables when no matching symbols exist. A
  verified compressed symbols archive is sufficient. Leave hash-referenced logs
  unchanged so resume can still validate them.
- Remove release-owned derived data, build caches, `.xcarchive` bundles, exported
  apps/IPA/PKG files, and temporary tap clones. Remove the pinned source worktree
  through Git after verifying its revision and clean tracked/untracked state;
  force removal only when remaining ignored files are known generated outputs.
  Delete a local published DMG only after authenticated `gh` confirms the remote
  asset's SHA-256 matches the release receipt.
- Limit deletion to completed version directories and scratch outputs created by
  this release. Preserve unrelated worktrees/caches, the installed app, library
  data, saved signing material, and remote release assets. Record removed paths
  and reclaimed space in a small local cleanup receipt, verify retained evidence,
  and report the space recovered with the release result.

## Record release bottlenecks

Use the timing history to identify avoidable delays and record external waits
separately. Compare releases with the same channel set and milestones when
assessing speed. Record confirmed work avoided, such as reusing exact-tree CI
in place of local tests, and report time saved only when a comparable baseline
measures that phase. Check that downstream workflows still accept the replacement
evidence when changing validation. A completed delivery and cleanup closes the
release timing entry. Track workflow changes and their PRs separately.

Read [the release guide](../../../docs/RELEASING.md) for setup, version examples,
checkpoint behavior, and recovery. Return selected versions/source, each channel's
actual state, the local Mac and iPhone installed versions, cleanup result,
receipt paths, timing, and any material delay. Name concrete blockers without
inventing acceptance passes or requesting confirmation already granted by the
release request.
