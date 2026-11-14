---
name: deploy-iphone
description: Prepare a signed NeoAnki2 update without a connected phone, install on a paired physical iPhone when available, and verify the installed version without launching. Use for deploy to iPhone, install on my phone, or update the iPhone app. Does not publish a release or upload to TestFlight.
---

# Deploy NeoAnki2 to iPhone

For an authorized iPhone installation, immediately run from the repository:

```bash
./Scripts/deploy-iphone.sh
```

The dirty working tree is deployment input. The command builds Release and
signs the app/widget before contacting the phone. It then detects a paired
wired/wireless phone, checks device registration, skips an already-current app,
installs as an update, and verifies the device-reported version/build. It does
not commit, publish, uninstall, reset the library, or enable sync.

Do not ask the user to connect/unlock at the start or keep the phone awake during
CI/build/signing. Do not require an "I'm ready" reply. If no phone is reachable
after preparation, the command emits `IPHONE_DEPLOY_STATUS=waiting_for_device`
and waits up to ten minutes for connection, detecting it automatically. Only
then tell the user the update is ready to install and the phone can be connected.
Never require app launch for delivery; the user opens it normally when needed.
Ask for an unlock only if Apple actually rejects an operation for that reason.

`--resume OUTPUT_DIRECTORY` reuses the signed update without rebuilding or
re-signing. A saved successful install resumes version verification alone.
Unknown install outcomes stop for receipt inspection rather than another install.
`--wait-seconds 0` performs one connection check instead of waiting. Keep prepared
artifacts when a phone is absent so the next attempt does not repeat preparation.

During a release, the unified controller invokes this command automatically
with `--source-dir`, `--version`, `--build`, and `--output` to install pinned
release source with the iOS channel's exact version/build. Both version flags
are required together and are verified in the app and widget before installation.
Do not repeat a successful controller-managed deployment. Resume a blocked
release through `./Scripts/release.sh --resume VERSION` so publication and local
delivery receipts remain coordinated.

Signing material lives in `~/Library/Application Support/NeoAnki2 Signing/`.
The existing `NeoAnki2-signing` Keychain has a separate password and its saved
password failed during the October 3, 2026 deployment. **Do not try to unlock
that Keychain or ask for a Mac, Apple ID, or Keychain password.** The command
uses the saved distribution certificate/private key in a temporary Keychain
with a generated password and codesign access, then deletes it and removes
its search-list entry even on failure. Never display or transmit signing keys
or passwords. Leave the user's existing Keychains unchanged.

The command selects the single available paired iPhone. If several are
available, use the user's specified name/identifier with `--device`; otherwise
ask which device. For missing or expired signing material, an unregistered
device, unavailable phone, disabled Developer Mode, or a failed installation,
report the exact blocker. Do not recreate certificates, reset Keychains,
change Apple provisioning, uninstall, or blindly repeat an installation.

Use `--prepare-only` to validate/build/sign without contacting a phone,
for example when verifying a change to this workflow. Artifacts, logs, and
receipts are stored under `.build/iphone-deploy/`; the command prints
`IPHONE_DEPLOY_*` status and timing fields. Report the target device, installed
version, verification result, and any blocked phase. This local deployment does not require
the macOS release workflow or a repeat of the full test suite.
