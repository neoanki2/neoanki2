---
title: Documentation quality audit — July 2026
description: Final adversarial assessment of NeoAnki2 documentation accuracy, task coverage, accessibility, evidence, and maintenance controls.
audience: developer
archived: true
permalink: /audits/state-of-art-2026-07-27/
---

# Documentation quality audit — July 2026

> **Archived snapshot.** This score described the July 27, 2026 tree. It is not
> current project status; see the [August documentation audit]({{ '/audits/documentation-2026-08-15/' | relative_url }}).

**Result at the time: 9.2/10, publication ready with disclosed limitations.**

This audit assessed the documentation as a product, not only as a collection of
pages. Reviewers attempted first-run, migration, recovery, deck-authoring,
keyboard, accessibility, and maintenance tasks; compared high-risk statements
with production source and tests; built and crawled the rendered GitHub Pages
site; and reviewed every promoted product screenshot.

## Scorecard

| Area | Score | Evidence |
| --- | ---: | --- |
| Task completion | 9.5 | Five-minute first success, task index, migration cautions, update/removal, backup, and complete restore procedure |
| Safety and factual accuracy | 9.5 | Production-backed claims registry, prose assertions, import hardening, explicit destructive-action and scheduling semantics |
| Clarity and learning architecture | 9.0 | Task-first navigation, concepts/glossary, progressive advanced material, troubleshooting and support paths |
| Findability | 9.0 | Hierarchical navigation, breadcrumbs, previous/next links, ranked local search, aliases, sitemap, and recovery links |
| Keyboard and responsive use | 9.0 | Skip target focus, mobile focus management and Escape, 44 px targets, visible focus, reduced-motion and print handling |
| Screen-reader semantics | 8.5 | Landmarks, current-location state, live search count, descriptive links and alt text; manual Safari/VoiceOver verification still required |
| Feature and test evidence | 9.0 | 31-feature source/test map, app UI inventory, app test inventory, and fully mapped import/media/deck-format/CLI boundaries |
| Drift detection | 9.5 | Constants and prose checked, source/article/screenshot coupling on PRs and direct pushes, rendered-site crawl |
| Screenshot evidence | 9.5 | 19 focused, state-specific app-window images with scenario, visible identifiers, dimensions, source revision, and SHA-256 |
| Rendered-site quality | 9.5 | Jekyll 3.10 build, route/fragment/asset crawl, canonical and heading checks, metadata, custom 404, and HTTPS enforcement |

## Defects found and resolved

The adversarial passes found and drove fixes for:

- ambiguous **Again** and optimizer semantics, deleted-history effects, card
  reconciliation, import placement, fixed retention, and restore steps;
- absent update/removal and first-run Xcode guidance;
- stale or malformed links, Jekyll-incompatible Liquid, and pretty-URL errors;
- search ordering that hid migration and backup help;
- unreliable skip/mobile-navigation focus and unclear search popup semantics;
- media-picker/core format drift and silently discarded malformed JSON fields;
- authored-media schema paths that disagreed with the production validator;
- incomplete claims/prose, command/view, app-test, core-format, and direct-push
  freshness enforcement; and
- screenshots that lacked committed provenance, state assertions, content hashes,
  or unobscured bottom controls.

## Verification gates

Publication requires:

1. fast core, flow, and app-model tests;
2. source, test, article, claims, and screenshot ownership validation;
3. a GitHub Pages-compatible Jekyll build;
4. a rendered crawl of internal routes, fragments, assets, metadata, headings,
   image alternatives, landmarks, and canonical HTTPS URLs; and
5. separately captured and reviewed screenshot evidence before promotion.

The [feature index]({{ site.baseurl }}/features/) shows current ownership. The
[maintenance guide]({{ site.baseurl }}/user/maintaining-documentation/) explains
the update and screenshot workflows.

## Residual limitations

The score is not a WCAG conformance claim. A manual Safari/VoiceOver,
high-contrast, text-size, and complete focus-order pass remains a release
activity. The feature inventory deliberately combines broad app-layer detection
with fully mapped high-risk core/CLI boundaries; it is strong change ownership,
not a mathematical proof that arbitrary future code is user-facing.

NeoAnki2 also remains a source-built development application without signed
releases. The documentation states that constraint rather than presenting a
consumer installation path that does not exist.

## Re-audit triggers

Repeat task-based review when installation changes, a new import/export format
is added, scheduling semantics change, navigation/search behavior changes, or
the accessibility limitations can be narrowed through manual verification.
