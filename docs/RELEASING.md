# Releasing NeoAnki2

Official releases use a slow preparation phase and a queue-free promotion
phase. Expensive tests and universal compilation happen before merge; the
merge-to-install hot path only promotes an immutable candidate.

## Prepare the candidate

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

The command refuses to proceed if NeoAnki2 is running, the candidate is stale,
the PR is not cleanly mergeable, or any revision, version, asset, or checksum
does not match. It never quits or opens a graphical application.

The legacy **Release** workflow is retained as a manually dispatched recovery
path. The tap's scheduled updater remains a repair mechanism, not part of the
normal release path.
