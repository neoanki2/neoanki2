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

## Release workflow

- A user request to `release` runs `./Scripts/release.sh` directly. The command
  treats current local changes as release input and owns committing, local
  verification, packaging, PR creation and non-blocking merge, publication,
  official-tap update, Homebrew installation, and exact-path launch.
- The default release has a 300-second SLO. Do not run the full UI suite or wait
  for GitHub checks on its critical path; the merge starts exhaustive Test and
  Documentation workflows automatically.
- Use `./Scripts/release.sh --verified ...` only when the user explicitly waives
  the five-minute requirement in favor of pre-publication hosted checks and an
  attested GitHub candidate.
- Preserve and report the emitted `FAST_RELEASE_*` telemetry.

## iOS App Store review

- App Store releases use `Scripts/release-ios.sh`, separately from the Mac and
  Homebrew release workflow.
- Before submission or resubmission, complete the mandatory internal review
  described in `docs/IOS_RELEASE.md`. Review the exact candidate's ordinary
  Release first launch, iPhone/iPad journeys, listing, screenshots, privacy,
  support, and reviewer instructions. Preserve independent findings and evidence.
- Retrieve Apple's written rejection and attachments before claiming a rejected
  issue is fixed. Map each issue to a verified correction and regression evidence;
  do not substitute an API status or speculative checklist for the message.
- A passed internal review reduces known rejection risks; it never guarantees
  Apple approval. Report uploaded, submitted, approved, and publicly available
  states separately, and never bypass a failed review gate.

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
