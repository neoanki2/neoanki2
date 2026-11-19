# Contributing to NeoAnki2

The canonical contributor instructions are published in the
[NeoAnki2 Developer Guide](https://neoanki2.github.io/user/developer/).

From a fresh checkout with Swift 6 and Node.js, run the PR test gate:

```bash
./Scripts/test-unit.sh
```

Run `./Scripts/test-fast.sh` for the broader headless checks.

API changes must also regenerate and verify the static contract:

```bash
swift run neoanki-api-reference generate
swift run neoanki-api-reference check
swift test --filter NeoAnkiAPITests --parallel
```

Preserve unrelated working-tree changes, keep architecture dependencies
inward-only, and update the owning guide, tests, and generated artifacts with
user-visible or contract changes.

