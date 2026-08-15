---
title: Documentation audit — August 2026
description: Audit and remediation record for NeoAnki2 user, API, developer, reference, and maintenance documentation.
audience: developer
permalink: /audits/documentation-2026-08-15/
---

# Documentation audit — August 2026

## Baseline result

**Overall health before remediation: RED.** The task-oriented user manual and
rendered-site checks were strong, but the public site had no generated HTTP API
reference, no coherent developer guide, mixed internal material into its
reference library, and did not structurally prevent API/documentation drift.

| Area | Baseline | Primary evidence |
| --- | --- | --- |
| User manual | Green | Task index, feature ownership, claims, screenshots, search, and rendered crawl |
| HTTP API reference | Red | An internal requirements document occupied the reference position; no static OpenAPI artifact or endpoint pages existed |
| API freshness | Red | Router behavior and OpenAPI inventory could be maintained independently |
| Developer onboarding | Red | Setup, tests, architecture, API, documentation, and release instructions were scattered |
| Information architecture | Yellow | User, contributor, internal, and external-contract material shared one reference list |
| Consistency controls | Yellow | The July audit claimed 31 features while the active manifest contained 44; release status and two repository links were stale |

## Remediation delivered

- The local HTTP API now has an exhaustive typed handler inventory and a typed
  endpoint registry used to admit requests and generate OpenAPI.
- The same registry generates 80-operation static reference pages, schema and
  error pages, examples, and downloadable OpenAPI JSON under `/api/`.
- The active feature inventory now owns 45 features, including the HTTP
  contract and its generated API reference.
- A developer guide now covers setup, tests, architecture, API contribution,
  documentation, and release paths inside the existing manual.
- The reference library is limited to public HTTP and file-format contracts;
  design requirements and acceptance evidence are labeled as developer material.
- Published pages declare an audience and validation checks generated API
  freshness, page classification, navigation ownership, and repository-local links.

## Remaining human checks

The automated gate does not claim full WCAG conformance or validate arbitrary
external websites. Release review still includes keyboard and screen-reader
judgment, responsive reading quality, screenshot approval, and scheduled
external-link monitoring.
