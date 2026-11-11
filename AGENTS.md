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
- Current local changes are release input. The command captures an immutable
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
  saved credentials. Publication does not install TestFlight, touch Store app
  containers, replace the local Homebrew app, or launch GUI applications. Local
  Homebrew upgrades remain an explicit `brew upgrade --cask neoanki2/tap/neoanki2`.
- Read `docs/RELEASING.md` for the workflow and recovery rules. Retired release
  entry points must not be used to allocate independent versions or bypass state.

## iPhone deployment

- A request to deploy, install, or update NeoAnki2 on a physical iPhone runs
  `./Scripts/deploy-iphone.sh` directly; see `.codex/skills/deploy-iphone/SKILL.md`.
- Current local changes are deployment input. The command builds, signs using
  saved local certificate/key material in a disposable Keychain, installs as
  an update, and launches once. It does not publish or reset app data.
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
- Exception: when the user explicitly requests installation or an upgrade, NeoAnki2 may be terminated if needed for a safe upgrade and launched exactly once after the upgrade completes. Do not perform any other GUI interaction or relaunch it more than once.
