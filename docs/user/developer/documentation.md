---
title: Documentation development
description: Maintain the user manual, generated API reference, feature ownership, claims, and screenshots.
audience: developer
parent: Developer Guide
permalink: /user/developer/documentation/
---

# Documentation development

NeoAnki2 keeps documentation beside the behavior it describes. Hand-written
guides explain tasks and decisions; generated artifacts cover inventories and
wire contracts.

## Generated content

- `docs/features.md` comes from `docs/features.json`.
- `docs/api/` comes from the typed HTTP endpoint registry and schema catalog.
- `docs/search.json` is produced by Jekyll from published pages.

Regenerate and validate with:

```bash
swift Scripts/validate-docs.swift --write
swift run neoanki-api-reference generate
./Scripts/test-fast.sh
```

## User-visible behavior

Update the owning user article and feature record in the same change. When a
format, limit, compatibility rule, storage location, scheduling default, or
destructive consequence changes, update the claims registry and its
production-backed test.

Screenshot capture and promotion are explicit investigations using
`Scripts/capture-doc-screenshots.sh` and `Scripts/promote-doc-screenshots.sh`.
They do not run in CI or commit automatically to pull-request branches. Pre-push
and documentation-publication checks verify committed screenshot integrity;
source freshness is checked only with
`swift Scripts/validate-docs.swift --require-screenshots --check-screenshot-freshness`.
Follow the full
[screenshot and claims procedure]({{ '/user/maintaining-documentation/' | relative_url }})
and never replace provenance metadata by hand. Screenshot filenames remain
stable documentation contracts even when the interface changes.

## Page ownership

Every published Markdown page declares one audience: `user`, `api`,
`developer`, or `reference`. Each page must be linked from its audience hub or
navigation unless it is explicitly marked as an archived audit.

## Publication

Every merge into `main` triggers documentation publication, including merges
that only change application code. The workflow validates, builds, and crawls
the site, then dispatches the canonical `neoanki2.github.io` workflow with that
merged revision. This keeps the published source revision current without adding
documentation work to pull-request acceptance.
Its post-deployment smoke test waits for that exact SHA in the footer and checks
`/api/`, `/api/decks/`, and byte-identical `/api/openapi.json`. The root-site
repository retains its hourly recovery deployment. Configure the
`ROOT_DOCS_DISPATCH_TOKEN` repository secret with workflow access to the root
site; a missing token fails publication instead of silently leaving stale docs.

Generic external-link checks are manually dispatched so transient network
failures do not consume the unit-test CI lane. Validate repository-local GitHub
targets during pre-push documentation checks. Publication runs after changes
reach `main`, separately from the required unit-test gate.
