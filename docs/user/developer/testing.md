---
title: Tests and validation
description: Run NeoAnki2's fast checks, focused suites, documentation gates, and platform builds.
audience: developer
parent: Developer Guide
permalink: /user/developer/testing/
---

# Tests and validation

## Fast contributor loop

Run the same tests as the pull-request **CI Gate** from the repository root:

```bash
./Scripts/test-unit.sh
```

App, Core, tooling, and Chrome companion tests run in parallel. The Chrome
suite uses Node's built-in test runner and needs no npm install. Pass a lane name such as
`./Scripts/test-unit.sh app` to run it on its own. A full local run prints the
log directory and shows diagnostics from any failed lane.

Local Swift builds are incremental. CI keys compiled products by each package's
sources, tests, manifests, runner script, compiler, SDK, architecture, and
workspace. Only an exact cache hit skips compilation. Every run executes tests.

The Core lane runs `NeoAnkiCoreTests` and `NeoAnkiFSRSTests`. The app lane runs
root-package unit and model suites, including the four focused visible-sync
regressions. The generated fault and three-device sync campaigns, `NeoAnkiFlowTests`,
architecture scans, mutation qualification, shared-platform builds, and unsigned
iOS archives are available through **Extended validation**
(`.github/workflows/validation.yml`) and the existing local scripts.
Use `./Scripts/test-fast.sh` for the broader local headless run, including
Core flows, the sync campaigns, generated API freshness, and documentation
validation. Performance benchmarks and native XCTest UI journeys are opt-in.

## Pre-push validation

Enable the tracked Git hook in this checkout:

```bash
git config --local core.hooksPath Scripts/githooks
```

Commit your changes, integrate current GitHub main, and push from a clean
checkout of the commit you want to send. The hook verifies the current base,
runs all four unit lanes, and checks the diff and strict documentation.
Changes to the local API, its generator, or generated reference also run the
API freshness check. A failure stops the push.

The hook uses Apple Silicon and the exact Xcode build pinned for the app CI
job in `Config/app-unit-xcode-build.txt`. Set `DEVELOPER_DIR` to that Xcode
installation's `Contents/Developer` directory if another Xcode is selected.
The hosted Intel Core and Linux Chrome jobs verify their platforms separately.
Documentation publishing runs after integration.

## Focused suites

```bash
swift test --filter NeoAnkiAPITests --parallel
swift test --filter NeoAnkiFeaturesTests --parallel
swift test --filter NeoAnkiApplicationTests --parallel
swift test --filter NeoAnki2Tests --parallel
(cd NeoAnkiCore && swift test --parallel)
```

Use the narrowest relevant suite while iterating, then run `test-unit.sh`
before proposing a change. UI and performance workflows are slower and have
dedicated scripts under `Scripts/`. The [unified release process](../../RELEASING.md)
selects relevant headless checks; UI journeys are additional targeted evidence,
not a ceremony required for every release.

### Card-editing contracts

Run the editing contracts independently of a device or production library:

```bash
swift test --filter 'ItemEditing|NativeItemEditorHydration|GeneratedDeckEditing|CardEditingRegression'
(cd NeoAnkiCore && swift test --filter ClozeEditingInvariantTests)
```

The suites cover every field kind's hydration, required-value validation,
discard detection, Unicode cloze edits, save/reopen round trips, preservation of
unmodified fields and scheduling history, invalid saves and SQLite write
failures, generated-deck snapshot conflicts and atomicity, and mid-study reloads.
Native Mac tests exercise the actual text adapter and the full bridge-card
editor in an offscreen `NSHostingView`; they never create a window or open the
user's library. The offscreen opening test verifies that the real appearance
callback ran before checking native text values.

These tests do not establish that an installed app's sheet presentation,
focus behavior, iOS bindings, or media pickers work. Do not equate a passing
hydration test with reproduction or resolution of an empty-editor report.
Regression assertions remain enabled when they expose defects; do not replace
them with assertions of the broken behavior or disable them to make CI green.

`NativeCommandCompletionTests` suspends badges, reminders, and widgets across
create, edit, move, delete, deck, and import commands. `LatestAsyncWorkTests`
checks serial execution and bounded pending work. Editor tests check shared
draft conversion, validation parity, save transitions, and actual glyph ink;
study tests check retired cards, deferred repairs, deletion, and stale reads.
Gated reload tests verify that automatic refresh retains explicit browse demand
and that a commit invalidates an older snapshot before it reaches the screen.
Tests that need derived summaries await `awaitReadModels()`. Tests of OS
publication explicitly await `awaitDevicePublication()`; that barrier does not
belong on a Save completion path.

Qualify that the editor contracts actually reject known defects:

```bash
python3 Scripts/check-editor-test-sensitivity.py --output .build/editor-sensitivity
python3 Scripts/run-editor-save-ui.py --output .build/editor-save-ui
# Also qualify the disabled-fixture defect with real Simulator verification:
python3 Scripts/check-editor-test-sensitivity.py --with-simulator --output .build/editor-sensitivity-ui
```

The sensitivity campaign builds an isolated snapshot including dirty and
untracked source. It never mutates the working checkout. A passing executed
baseline is required; only the expected behavioral assertion detects a mutant.
Compilation errors, timeouts, skipped/missing tests, and infrastructure failures
are inconclusive failures. Headless qualification covers document sizing,
binding replacement, and putting OS publication back on command completion.
Run relevant qualification locally before a release push or through manual
Extended validation. Its campaigns have independent cold-build budgets; they do
not run in the unit-only PR lane. Compilation failures and timeouts still fail
qualification; no assertion failures are retried or ignored.

The focused iOS runner uses one uniquely named disposable Simulator and always
deletes it. Its save-from-study journey checks dismissal, refreshed content,
reopening, and persistence after relaunch. Independently validated nonce-scoped
armed/held receipts must match the persisted fixture item. An inactive fixture
cannot earn a pass merely because tapping Save worked under normal conditions.
The fixture is Simulator-only and requires the explicit UI-test reset argument.

### Study sessions and performance

Session behavior is tested in `NeoAnkiFeaturesTests/StudySessionContractTests`;
Mac tests cover presentation and observation through its forwarding adapter.
Core ordering tests compare stable selection against the previous policy and
count family inspections, so ordinary-queue scaling is checked without timing
thresholds in CI.

`Scripts/run-performance-tests.sh` runs both packages serially at small scale,
propagates failures through its optional timeout, and requires measurements from
both layers. Use the slow runner for large/stress suites. For an isolated,
optimized queue benchmark, run from `NeoAnkiCore`:

```bash
NEOANKI_RUN_PERFORMANCE_TESTS=1 NEOANKI_PERF_SCALE=large \
NEOANKI_PERF_ALLOW_SLOW=1 NEOANKI_PERF_JSON=/tmp/neoanki-queue.ndjson \
swift test -c release -Xswiftc -enable-testing --no-parallel --filter perfIndependentQueueOrdering
```

The benchmark excludes fixture construction, measures the first 100 positions,
and emits one warm-up followed by five repetitions. Use `small`, `medium`, and
`large` for 100, 1,000, and 25,000 cards. Compare medians and ranges with the same
hardware/configuration and no competing builds. `peakRSSBytes` is the process's
lifetime high-water mark, not memory attributable to an individual flow.

### Chrome companion

The extension needs no build step. Its JavaScript and packaged-browser checks run
separately from the Swift fast lane:

```bash
cd Extensions/Chrome
npm ci
npm test
npx playwright install chromium --no-shell
npm run test:integration
```

The integration test loads the production extension into headless Chrome for
Testing with a disposable profile and a real, isolated NeoAnki2 API server. It
checks pairing, selection capture, dictionary suggestions, study-card creation,
and replay after a lost save response. See the extension README for fixture
cleanup and the [user guide]({{ '/user/chrome-companion/' | relative_url }}) for local installation.

### Headless sync regression and stress tests

```bash
./Scripts/test-sync.sh
./Scripts/test-sync.sh --stress
NEOANKI_SYNC_FUZZ_SEED=99 NEOANKI_SYNC_FUZZ_STEPS=200 ./Scripts/test-sync.sh
```

The default run includes eight fixed state-machine seeds and focused regression
tests. Stress mode uses 32 seeds with 200 actions per seed; set
`NEOANKI_SYNC_FUZZ_SEEDS` and `NEOANKI_SYNC_FUZZ_STEPS` to adjust it, up to 128
seeds and 1,000 actions. A failure reports its seed, operation trace, and differing
resources. Replay the seed with the same step count. Mutation choices, input IDs,
timestamps, injected failures, and delivery shuffles are seeded; persistence
still generates its own library, card, and review IDs.

Three real temporary SQLite libraries synchronize through an in-process server
with independent change tags. The model checks convergence, exact item/review
counts, expected edits, preserved scheduling data, and a quiet journal after
settling. It injects offline starts/fetches, failed sends, partial commits with
lost acknowledgments, duplicate deliveries, reordered dependencies, and process
restarts. Separate tests cover initial library collisions, persistent type
aliases, edit/delete conflict recovery, corrupt payloads/assets, durable inboxes
and upload queues, legacy metadata, stopping in-flight sync, acknowledgment races,
and merge permutation/idempotence properties.

The full state-machine campaign runs in `test-fast.sh` and `test-sync.sh`.
The PR gate includes the focused regressions. These checks do
not touch the installed apps, user library, iPhone, Apple account, or live iCloud
container. They verify the repository and transport decisions headlessly;
Apple provisioning, push delivery, and SDK/server integration remain platform
acceptance checks rather than claims made by the simulated server.

For an explicitly requested UI investigation or a change requiring visual
regression evidence, run its focused journey:

```bash
./Scripts/run-ui-tests.sh FastFunctionalJourneyTests/testRelevantJourney
```

These optional journeys are separate from the unified release critical path.
Do not add all UI journeys, screenshot capture, or physical acceptance to an
unrelated release. Failed checks retain their evidence and require a diagnosed
application, test, or workflow correction before another validation run.

### Autonomous visible-convergence contracts

The earlier state-machine fuzz tests remain useful for eventual consistency.
They manually settle all replicas after each generated action, however, so they
cannot establish that an idle receiving app updates promptly on its own.

Three independent test-design proposals were compared:

| Proposal | Main emphasis | Decision |
| --- | --- | --- |
| Replayable lifecycle state machine | Independent user-operation ledger, long offline histories, shrinking failing scenarios | Use its independent expectations and replayable operations in the selected contracts |
| Disk-owned lifecycle chaos | Server-owned image bytes, expiring download leases, process replacement and whole-container moves | Use its storage and lifecycle model in the selected contracts |
| Autonomous visible convergence | Automatic local-change sending, push/poll recovery, and displayed due counts under controlled time | Selected as the organizing approach because eventual convergence alone did not prevent the observed failures |

`SyncConvergenceContractTests` uses real temporary SQLite repositories, the
production sync adapter and metadata store, the sync service, and
`LibraryFeatureModel`. The synthetic cloud owns its own image bytes; a client
cannot read another client's file as a substitute for uploading or downloading
it. Relocation moves the synthetic app container and removes its old location,
without repairing saved URLs in the fixture.

The measured path starts the services once, then relies on ordinary user
commits, push delivery, and scheduled recovery. Calling manual sync or refreshing
the feature model to make a measured scenario pass is prohibited. Tests wait for
observable timer registration and transport events. An injected clock advances
the production 600-millisecond local-change debounce and 10-second recovery
poll; a wall-clock watchdog only detects a stuck test. These are application
scheduling contracts with an immediate simulated network, not a promise that
Apple delivers a real notification within 600 milliseconds.

Expected review records and card schedules are captured from successful local
user operations before transport runs. Checking only that two replicas agree
would also accept both replicas losing the same review. Scheduling comparisons
exclude device-local repeated-lapse warning acknowledgements.

Run the focused contracts, expand the campaign, or replay an emitted scenario:

```bash
./Scripts/test-sync.sh --contracts
./Scripts/test-sync.sh --contracts --stress
NEOANKI_SYNC_CONTRACT_SEED=99 ./Scripts/test-sync.sh --contracts
./Scripts/test-sync.sh --replay /absolute/path/to/scenario.json
```

Use `NEOANKI_SYNC_CONTRACT_SEEDS` and `NEOANKI_SYNC_CONTRACT_STEPS` to size a
campaign. `NEOANKI_SYNC_CONTRACT_SEED_BASE` selects the first seed in a rotating
campaign; a single explicit `NEOANKI_SYNC_CONTRACT_SEED` takes precedence.
`NEOANKI_SYNC_CONTRACT_ARTIFACTS` selects the directory for replay and failure
evidence; the shell runner defaults it to `.build/sync-contract-artifacts`.
The default campaign uses four fixed seeds and twelve steps, with one to three
reviews committed per step before convergence. Supported bounds are 1–64 seeds
and 1–200 steps. Keep the JSON scenario and code revision together when reporting
a failure. Replay reproduces the planned actions and fault choices; it uses
fresh persistence IDs and anchors relative card schedules to the current date.
It does not freeze arbitrary Swift executor interleavings or automatically
shrink a failing scenario.

Run these integration contracts locally or through manual Extended validation.
The **Sync stress** workflow is also manual: it runs 64 generated scenarios with
40 operations each, split across four shards. Each shard derives its initial
seed from the workflow run ID unless one is supplied. Its artifact contains the
campaign log and replayable scenario evidence. This campaign uses no Apple account, installed
app, physical phone, or production library.

#### Backlogs and forward progress

An iPhone once showed 61 due cards while the Mac showed one. The iPhone had
received the Mac's reviews, but sync was still processing an outbox of 213
conflicting card records. Processing each conflict rewrote the roughly 48 MB
sync metadata file. The existing generated contracts varied delivery and
restart behavior, with one to three reviews per step. Those tests could verify
the final state while missing work that grew with every record in the queue.

The PR suite now covers this at the production outbound-preparation and sync
service boundary. Two temporary SQLite libraries start with 61 due cards.
The receiver starts with a saved outbox of 213 card conflicts and a durable
inbox containing the sender's reviews. One sync cycle must leave exactly the
same due card eligible on both replicas, preserve every review and conflict
copy, clear both queues, and complete within eight atomic metadata writes.
The write budget counts actual persistence calls, so a faster runner cannot
hide per-record writes. The test supplies server records in memory and runs
without CloudKit access.

Use the following coverage targets when extending the sync suite.

| Layer | Cases and assertions | When to run |
| --- | --- | --- |
| Deterministic work and recovery contracts | Combine staged reviews with pending conflicts, media transfers, and other queued work. Test just below, at, and just above the 200-ID CloudKit lookup and 1,000-entry journal-page boundaries, and test large baselines independently of backlog size. Count metadata writes, bytes serialized, requests, and apply transactions. Interrupt after staging an inbox page, after committing SQLite, and before acknowledging the outbox. A restart must preserve pending work and finish with exact IDs, correct due projections, and a quiet journal. | Keep the incident replay and inexpensive boundary cases in the PR gate. Run large synthetic baselines in extended validation. |
| Stateful fuzzing | Extend the existing replayable contracts with burst sizes, conflicting edits on multiple replicas, overlapping reviews and undos, and changes to deck limits and study-day rollover. Generate overlapping offline actions before attempting recovery. Vary queue age and size independently of sequence length. Compose lost pushes, duplicate pages, partial acknowledgments, expired tokens, rate limits, failed writes, and restarts. After the last fault is removed, drive the normal push or poll path and require progress within a defined number of recovery cycles. | Use fixed seeds for regressions and rotating seeds in the existing Sync stress workflow. Add a scheduled run if regular background coverage is needed. |
| Platform acceptance | Exercise signed builds with a disposable library and test iCloud account when changing CloudKit callbacks, subscriptions, or background processing. Check that a review reaches the receiver's SQLite library and changes the visible due count automatically after foregrounding or a supported background wake. Record the delivered, applied, and visible milestones separately. | Run focused acceptance for affected platform integrations. Keep the PR gate headless. |

For generated tests, keep an independent ledger of committed review and undo
identities, expected schedules from successful local operations, and due-card
IDs at a shared observation time. Assert those on every replica. An empty
inbox or matching counts alone can miss lost reviews, duplicate reviews, or
different cards reaching the same count. Assert durability at each injected
failure and progress once delivery resumes. Use wall-clock limits only as
watchdogs in correctness tests. Measure latency, CPU, and disk use separately
on a reference device.

Keep a reproducible trace for each failure with its seed, operations, injected
faults, queue sizes, and expected and observed progress. Reduce the trace to a
small synthetic regression and qualify it by demonstrating that it rejects the
old behavior. For a backlog, useful mutations include writing each conflict
individually, dropping a staged review, and suppressing the post-commit
availability refresh. Each tests a different failure mode with a distinct
assertion.

#### Verify that the tests reject broken implementations

When the contract harness changes, qualify it locally or with manual Extended
validation against deliberate mutations in an isolated checkout:

```bash
python3 Scripts/check-sync-test-sensitivity.py --list
python3 Scripts/check-sync-test-sensitivity.py --output .build/sync-sensitivity
python3 Scripts/check-sync-test-sensitivity.py \
  --mutant persist-upload-conflicts-one-at-a-time --mutant archive-card-conflicts-one-at-a-time
```

The original implementation must pass first. Each mutation must then produce
its intended test failure; a compilation failure or infrastructure error does
not count as detecting a bug. The campaign preserves its report, source diffs,
and original logs. It never changes the working checkout or retries an unchanged
failure to get a green result. Qualifying the harness costs more than the normal
contract run, so it runs when the harness changes rather than on every unrelated
pull request.

These checks establish correctness and bounded scheduling in the modeled
conditions. They do not prove arbitrary operating-system crash safety, CloudKit
server behavior, signing, connectivity, or iOS background execution guarantees.
The visible-summary path exercises the shared receiving feature model; native
shell wiring retains its separate tests. Dictionary-pack transfers and the
learning-time zone also retain their separate suites. Those limits remain
separate from the card-library contracts.

For foreground latency acceptance, use already-synced signed Mac and iPhone
builds with a disposable library and test iCloud account. Record timestamped
`com.neoanki2.sync` logs at Info level. Match the sender's SQLite journal commit
and CloudKit acknowledgment with the receiver's zone response, SQLite apply, and
published projection. Use sequential operations and aligned device clocks to
pair the samples. Record at least 50 edits, grades, and undos in each direction,
including while media transfers are running. Check 5 seconds at p95 for ordinary
foreground changes and 8 seconds at p95 with receiving push delivery suppressed.
Capture empty foreground checks, CloudKit retry-after responses, and idle iPhone
energy on the same reference device.

## CI reliability and optional UI investigations

The app unit job uses the Apple Silicon `xcode-27` image with Xcode 27.2.
Core runs on `macos-26-intel` with Xcode 26.6. Manual platform validation and
release archives retain iOS ARM64 and universal Mac build checks.
The [official image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
lists the pinned app CI installation.

Resource contracts check each checksum read's autorelease lifetime and pairing
approval cancellation/completion directly. The former process-wide RSS growth
budget and one-second pairing-response deadline were removed: parallel tests
and runner load could violate those thresholds without either behavior failing.
The loopback lifecycle contract observes TCP readiness, complete HTTP framing,
and EOF directly. It no longer measures the shared URLSession's scheduling or
default request deadline alongside unrelated parallel tests.
Sync, vocabulary catalog, dictionary/debounce, progressive study, export, and reload tests use
observable state, buffered stream events, or explicit operation-entry/release
gates. Assertions run after the exact relevant work completes, including stale
work being rejected. Review-duration arithmetic uses explicit monotonic
instants. These contracts replace readiness sleeps, yield counts, and short
wall-clock deadlines; domain timers and opt-in performance checks remain
separate.

The signed FSRS fixture manifest preserves the original August 16, 2026
verification and its tolerances. Current analytic-gradient tests permit the
larger of `1e-10` and two Float ULPs at each nonzero oracle derivative's magnitude,
because forward caches use Float and platform math libraries can differ.
Inactive derivatives and signs remain exact; loss parity, independent finite
differences, and optimizer parity retain their separate checks. This fixture
tolerance is not an error bound for arbitrary review histories.

Automatic PR CI runs the unit/model suites, isolated tooling tests, and Chrome unit tests.
Broader integration/flow tests, platform builds, archives, mutation campaigns,
architecture scans, and external-link checks are local or manually dispatched.
This removes continuous PR coverage of those integration and packaging behaviors;
they remain part of targeted pre-push verification or release preparation.
No native XCTest UI test, screenshot capture, or screenshot-promotion workflow
runs automatically. The launch smoke test was deleted: it slept for two
seconds and accepted both normal exit and a crash, providing no readiness check.
The obsolete test of the retired release orchestrator was also deleted; the
current controller is covered by `Scripts/test-release.py`.

Hosted UI runs failed across unrelated tests in screenshot requests, orientation
confirmation, application launch, accessibility audits, keyboard focus, and
native menu actions. Examples include Actions runs `42831394331`, `42821536861`,
`42730552467`, `42716879402`, and `42995563218`. These failures persisted after
simulator isolation and removal of private-service prewarming. Removing the UI
jobs removes continuous end-to-end verification of navigation, editing, media,
lookup, study, transfers, Studio, occlusion, layouts, and accessibility on Mac,
iPhone, and iPad. Headless model and contract tests cover behavior but do not
replace real-control, pixel-contrast, layout, or assistive-technology evidence.

`Config/ci-ui-shards.json` remains the inventory for explicit investigations.
`FunctionalUICoverageManifestTests` checks that it covers the declared journeys;
it does not schedule them in CI. Use the existing CLI runners for a relevant,
explicitly requested investigation. Each mobile run owns one disposable Simulator
and cleans it up on exit. Failed assertions and infrastructure errors fail that
run without retries or skipped-test success.

Documentation CI still verifies committed screenshot files, checksums,
dimensions, provenance metadata, and display density. Screenshot freshness
against application source is opt-in through `--check-screenshot-freshness`;
UI source changes no longer require a hosted capture or an automatic bot commit.
This removes automatic visual freshness coverage. Refresh screenshots through
the capture and promotion scripts when explicitly requested.

## Mobile visual acceptance

The redesign journeys assert actual navigation destinations, default answer
concealment, scoped Library triage, both grading modes, undo/skip, local recording
persistence, all seven interactions and five layouts, builders, transfer, and
focused authoring. The inventory journeys retain named screenshots and matching
accessibility trees in the XCTest result bundle. The authoring journey also
covers rich text, cloze clearing, media removal, and native picker cancellation.
It checks that editing mixed rich-text runs preserves semantic formatting,
including color, size, code, and links. Text editor heights scale with Dynamic
Type; media status labels wrap within their rows.

Use uniquely named disposable devices for headless `xcodebuild`/XCTest runs and
always shut down and delete them in a cleanup trap. Never open Simulator.app or
use an existing user-managed device. Run the complete phone suite, then cover
compact phone and iPad with light/dark inventory, largest Dynamic Type, Increased
Contrast, Reduce Motion, rotation, keyboard, and long-content cases. Compare the
rendered screenshots; passing accessibility audits alone is insufficient.
Physical-device media capture and signed CloudKit checks remain separate
acceptance work. Reset-only recovery fixtures exercise the real SQLite conflict
restore adapter, failed restores, resolution, malformed import parsing, and the
shared startup error presentation with Retry. The startup fixture injects an
error message; it does not simulate database corruption. Contrast audits scroll
target text into view and retain diagnostic attachments for fixture text clipped
vertically by a scroll viewport. Controls, visible text, horizontal overflow, hit
regions, and descriptions remain strict.
Horizontal bounds checks measure controls, text, images, and named groups;
unlabeled native Form backgrounds may draw beyond the scrolling content bounds.

## Documentation checks

```bash
swift run neoanki-api-reference check
swift Scripts/validate-docs.swift --require-screenshots
```

Run the strict documentation check before release pushes. Run the API freshness
check locally when changing reference tooling or generated docs. The controller
runs it for released API source changes. **CI Gate** remains the required unit
test gate. See [maintaining documentation](../documentation/) for generation
and screenshot ownership.

The separate documentation publication workflow validates coverage after merges
into `main`. For changes to site inputs it builds and crawls Jekyll output and runs
`Scripts/check-docs-responsive.mjs` in headless Chromium at 375, 768, and 1024
pixels. It checks keyboard navigation, contained code blocks, and the absence
of page-level horizontal overflow.

The image attachment paste/save/replace regression owns the `phone-image-attachments` shard so no iOS batch exceeds five cases. Native Mac Store first-launch acceptance runs separately through `Scripts/review-macos-app.py` against the signed sandboxed candidate.

### iOS XCTest startup

Mobile XCTest setup verifies portrait interface geometry from a Simulator-contained
screenshot before launch. It requests an orientation change only for landscape,
square, or explicitly upside-down state, then verifies portrait dimensions again.
This avoids waiting for a redundant portrait confirmation on a cold Simulator
that already displays portrait pixels. Both occlusion cases and their assertions
remain available for focused investigations; this setup correction adds no case retry or timeout increase.

The optional UI runner, ordinary Release review, and App Store screenshot capture boot a
uniquely owned disposable Simulator with `simctl bootstatus -b`, then invoke
`xcodebuild test-without-building` with the verified `.xctestrun` and destination.
Xcode owns test-runner initialization. The supported split-build workflow is
[documented by Apple](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

Manual `launchctl kickstart` of private XCTest/AutomationMode services is an
optional diagnostic, not a prerequisite for UI validation. The former required
prewarming gate timed out before any UI case ran, including after cache
preparation; it depended on undocumented service labels and endpoint state.
Removing that gate removes no product tests. For explicit UI investigations, selected test counts, result bundles, and
disposable-device cleanup remain required. An actual XCTest initialization
failure still fails validation and must be diagnosed before another run.
