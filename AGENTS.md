# Project agent instructions

## Supported headless workflow

- Build: `swift build`
- Fast verification: `./Scripts/test-fast.sh`
- API contracts: `swift test --filter NeoAnkiAPITests --parallel`
- API reference freshness: `swift run neoanki-api-reference check`
- Documentation: `swift Scripts/validate-docs.swift`
- Contributor guide: `docs/user/developer/index.md`

Preserve unrelated working-tree changes. API changes must update the typed
endpoint registry, tests, and generated `docs/api/` artifacts together.

## GitHub check failures

- Do not rerun an unchanged failed check to obtain a green result.
- Diagnose the failure and fix the application, test, or workflow before a new
  validation run. Replace timing assumptions with observable readiness and
  deterministic fixtures; do not mask assertion failures with retries.
- Harden a flaky check or remove it. Preserve meaningful coverage when possible
  and report any coverage removed.

## Release workflow

- `./Scripts/release.sh` is the only release command. It detects changed app
  inputs and publishes iOS, Mac App Store, and Homebrew together when affected.
  iOS-only changes publish only iOS; Mac-only changes publish Mac Store and
  Homebrew; shared app dependencies publish all three. Docs/tests/release tooling
  alone do not trigger app publication.
- All artifacts in a release use one shared marketing version and build number.
  Unchanged platforms retain their previous version and skip that release number.
  `.release/baseline.json` bootstraps the migration; the GitHub release asset
  `release-state.json` is the ongoing per-channel baseline and checkpoint.
- Current local changes are release input. Commit and merge them into `main`
  before invoking publication; a queued auto-merge is insufficient. The command
  requires a clean checkout matching remote `main`, records that main revision,
  and rejects old branch-built candidates on resume. It captures an immutable
  worktree, runs only relevant headless checks once, builds affected artifacts in
  parallel, uploads/submits Store builds with automatic release, and updates the
  official Homebrew cask. Apple processing/review and public availability are
  reported separately. Actual simultaneous Store availability cannot be promised.
- Preview with `./Scripts/release.sh --plan`. Resume the exact saved version with
  `./Scripts/release.sh --resume VERSION`; inspect with `--status`. Never repeat an
  uncertain upload, overwrite a reserved version, or downgrade a published channel.
- Developer ID, production CloudKit, accepted Mac notarization, App Store
  distribution signing, archive/privacy validation, and Apple processing remain
  required. Never weaken signing or strip quarantine to speed up publication.
- Do not run GUI journeys, screenshot captures, fresh browser privacy reviews,
  physical-device acceptance, or independent review ceremonies as routine release
  gates. Run focused additional checks only for a relevant change or an explicit
  request. Preserve Apple's written rejection before claiming its issues fixed.
- Use authenticated `gh` for GitHub and the official App Store Connect API through
  saved credentials. Publication does not install TestFlight or touch Store app
  containers. A release request also authorizes upgrading this Mac's Homebrew
  installation after Homebrew publication: refresh the tap, run
  `brew upgrade --cask neoanki2/tap/neoanki2`, verify the installed version and
  signature, and launch NeoAnki2 exactly once. Terminate the running app if needed
  for a safe upgrade; preserve its library and settings. Complete this step rather
  than giving the user an upgrade command. Skip it for an iOS-only release when
  there is no newer Mac version. Report local installation separately from Store
  submission and public availability.
- Every release also installs the latest released iOS version on the user's
  paired iPhone through `./Scripts/deploy-iphone.sh` and verifies the version
  reported by the device. Do not launch the app as an installation gate.
  The controller uses its pinned source and the iOS channel's version/build;
  Mac-only releases retain the latest iOS version rather than inventing a new
  one. Use `--device NAME_OR_IDENTIFIER` if multiple iPhones are available.
  Build/sign without the phone. Finish CI, publication, and phone preparation
  before asking for any phone interaction. The installer automatically
  uses an available wired/wireless paired phone, skips an already-current app,
  and waits for connection only after the signed update is ready. Do not ask for
  an early unlock, a readiness confirmation, or keeping the phone awake during
  builds. Ask for an unlock only when Apple reports it is actually required.
  Resume reuses the signed package; successful installation followed by failed
  verification resumes verification alone. Preserve successful publication and
  device receipts; never repeat an installation with an uncertain outcome.
  Release completion requires both the
  applicable Mac upgrade and the verified iPhone installation.
- Finish successful releases by cleaning their disposable build outputs and
  pinned worktrees after both local installations are verified. Keep receipts,
  original logs, and production debug symbols; preserve pending/failed release
  recovery inputs.
- Read `docs/RELEASING.md` for the workflow and recovery rules. Retired release
  entry points must not be used to allocate independent versions or bypass state.

## iPhone deployment

- A request to deploy, install, or update NeoAnki2 on a physical iPhone runs
  `./Scripts/deploy-iphone.sh` directly; see `.codex/skills/deploy-iphone/SKILL.md`.
- Current local changes are deployment input. The command builds, signs using
  saved local certificate/key material in a disposable Keychain, installs as
  an update, and verifies the device-reported version without launching the app.
  Preparation needs no connected phone. It does not publish or reset app data.
- Do not ask for Mac, Apple ID, or Keychain passwords or unlock the existing
  `NeoAnki2-signing` Keychain. The command owns temporary signing and cleanup.
- If there are multiple available iPhones and the user did not select one,
  ask for the target; report other genuine device/signing blockers directly.
- Use `--prepare-only` when validating this workflow without another install.
- Preserve and report the emitted `IPHONE_DEPLOY_*` telemetry.

## Desktop isolation

- Do not launch, control, capture, or otherwise interact with the user's desktop or graphical applications.
- Use headless command-line and test workflows only.
- If verification requires GUI automation, Accessibility, Screen Recording, or opening a window, report it as blocked instead of attempting a manual fallback.
- Exception: CLI-only `xcodebuild`/XCTest UI automation may boot, test, and delete a uniquely named, disposable Simulator device. Simulator-contained XCTest screenshots, recordings, and result bundles are allowed, but do not open or control Simulator.app, use an existing or user-managed Simulator device, request host Accessibility or Screen Recording access, or capture or interact with the host desktop. Clean up the disposable device even when verification fails.
- Exception: an installation, upgrade, or release request authorizes terminating NeoAnki2 if needed for a safe local upgrade and launching it exactly once after the upgrade completes. Do not perform any other GUI interaction or relaunch it more than once.
