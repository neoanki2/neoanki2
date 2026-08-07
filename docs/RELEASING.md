# Releasing NeoAnki2

Official releases use a slow preparation phase and a queue-free promotion
phase. Expensive tests and universal compilation happen before merge; the
merge-to-install hot path only promotes an immutable candidate.

## Fast local path: push to installed

To run and time the complete path—including validation, packaging, draft
upload, push, merge, publication, tap update, and installation—use:

```bash
./Scripts/release-local.sh \
  --title "Release change" \
  --body-file .build/release-pr.md \
  --install
```

The command reports preparation, promotion, and total release durations.

For the shortest maintainer feedback loop, prepare everything before the
branch's first push:

```bash
./Scripts/prepare-local-release.sh
```

This runs headless app, core, and documentation validation; builds and signs the
universal DMG; computes its checksum; and uploads a draft release while the
branch is still local. It refuses branches that already exist on the remote.

Then start the measured push-to-installed path:

```bash
./Scripts/push-ship-release.sh \
  --title "Release title" \
  --body-file .build/pr-body.md \
  --install
```

The timer starts immediately before `git push` and covers push, PR creation,
merge, publication, direct tap update, Homebrew refresh, installation, and
verification. Local candidates are checksummed and ad-hoc signed but are not
GitHub provenance-attested; use the CI path below when that attestation is
required. The command refreshes only `neoanki2/tap`, so an unavailable unrelated
tap cannot block or distort the release timing.

## Developer ID and CloudKit archive path

Official CloudKit-capable artifacts are produced by the headless
`Xcode/NeoAnkiMac.xcodeproj` target. It owns the stable bundle identifier
`com.neoanki2.app`, hardened runtime, production push entitlement, and container
`iCloud.com.neoanki2.app`; Swift package targets remain the source implementation.

The Apple Developer team must provision a Developer ID application certificate
and a Developer ID CloudKit provisioning profile before dispatching Release. Set
`NEOANKI_DEVELOPMENT_TEAM`, `NEOANKI_PROVISIONING_PROFILE_SPECIFIER`, and
`NEOANKI_NOTARY_PROFILE` (a `notarytool` keychain profile), then run
`Scripts/archive-macos-release.sh`. It archives and exports with `xcodebuild`,
verifies the signature and universal architectures, submits the app for
notarization, staples the ticket, and verifies Gatekeeper acceptance.

`Scripts/build-release-artifact.sh` selects this path when
`NEOANKI_RELEASE_SIGNED=1`; its default remains the unsigned/mock-sync contributor
path so signing credentials are never required for local development. CI also
needs `APPLE_DEVELOPMENT_TEAM` and `APPLE_DEVELOPER_ID_PROFILE_NAME` secrets after
the certificate, profile, and `neoanki-ci-notary` credential are installed in the
runner keychain. Those are external provisioning prerequisites and are not stored
in this repository.

## Attested CI path

The pull request must be current with `main`. Dispatch **Release candidate**
with its pull-request number. The workflow runs unit, flow, documentation, and
functional UI validation in parallel with the universal package build. Only
after every validation job passes does it publish an attested draft release.

The candidate manifest records the exact PR head, base revision, source tree,
version, artifact name, and checksum. A change to the PR or to `main`
invalidates that candidate and requires another preparation run.

## Promote and install

From a clean checkout with authenticated `gh` and Homebrew, run:

```bash
./Scripts/ship-release.sh --pr NUMBER --install
```

The command performs all validation before starting its timer. It then:

1. merge-commits the exact tested PR head into `main`;
2. publishes the prebuilt draft release;
3. commits the exact version and checksum directly to the official tap;
4. refreshes Homebrew and upgrades the cask without launching the app; and
5. verifies the installed version and code signature.

It prints the elapsed time for merge, publication, tap update, Homebrew refresh,
installation, and the complete measured path so regressions are visible.

The command refuses to proceed if NeoAnki2 is running, the candidate is stale,
the PR is not cleanly mergeable, or any revision, version, asset, or checksum
does not match. It never quits or opens a graphical application.

Promotion explicitly replaces GitHub's temporary `untagged-*` draft name with
the final version tag before the Homebrew cask becomes visible.

The legacy **Release** workflow is retained as a manually dispatched recovery
path. The tap's scheduled updater remains a repair mechanism, not part of the
normal release path.
