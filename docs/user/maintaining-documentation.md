---
title: Maintaining this documentation
parent: Contributor Guide
---

# Maintaining this documentation

NeoAnki2 keeps user documentation beside the behavior it describes. Explanatory
articles are intentionally hand-written; a manifest and tests keep their
coverage verifiable.

## When product behavior changes

1. Update the relevant article under `docs/user/`.
2. Update `docs/features.json` if ownership, implementation files, tests, or
   screenshot coverage changed.
3. Regenerate the feature index:

   ```bash
   swift Scripts/validate-docs.swift --write
   ```

4. Run the fast checks:

   ```bash
   ./Scripts/test-fast.sh
   ```

On pull requests, the validator can compare changed product files to the feature
manifest. A mapped source change must update its article or the manifest. Pure
refactors can update the manifest to record that the mapping was reviewed.

## Refresh screenshots

Documentation screenshots use isolated databases and deterministic test
scenarios. They are not captured during normal local testing.

1. Run the **Documentation screenshots** workflow manually, or wait for its
   weekly run.
2. Download the `neoanki2-documentation-screenshots` artifact.
3. Review every image for correct content, layout, and absence of private data.
4. Promote the reviewed directory:

   ```bash
   ./Scripts/promote-doc-screenshots.sh path/to/downloaded/screenshots
   ```

5. Run `swift Scripts/validate-docs.swift --require-screenshots`.

The workflow never commits images automatically. This review step prevents a UI
failure, permission dialog, or runner-specific content from silently replacing
published documentation.

## What is generated

Only `docs/features.md` is generated. User instructions, format specifications,
and troubleshooting guidance remain curated because source comments cannot
capture workflow context, limitations, or user-facing language reliably.
