---
name: deploy-iphone
description: Build current NeoAnki2 local changes, sign with the locally saved Apple certificate and key, install on a paired physical iPhone, and launch once. Use for deploy to iPhone, install on my phone, or update the iPhone app. Does not publish a release or upload to TestFlight.
---

# Deploy NeoAnki2 to iPhone

For an authorized iPhone installation, immediately run from the repository:

```bash
./Scripts/deploy-iphone.sh
```

The dirty working tree is deployment input. The command builds Release,
validates device registration and app/widget profiles, signs, installs as an
update, verifies the installation receipt, and launches exactly once. It does
not commit, publish, uninstall, reset the library, or enable sync.

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
device, unavailable phone, disabled Developer Mode, or a failed install/launch,
report the exact blocker. Do not recreate certificates, reset Keychains,
change Apple provisioning, uninstall, or retry launch automatically.

Use `--prepare-only` to validate/build/sign without installing or launching,
for example when verifying a change to this workflow. Artifacts, logs, and
receipts are stored under `.build/iphone-deploy/`; the command prints
`IPHONE_DEPLOY_*` status and timing fields. Report the device, installed and
launched status, and any blocked phase. This local deployment does not require
the macOS release workflow or a repeat of the full test suite.
