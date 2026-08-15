---
title: Developer guide
description: Set up NeoAnki2, understand its boundaries, run the supported checks, and change public contracts safely.
audience: developer
parent: User Guide
permalink: /user/developer/
---

# Developer guide

This is the canonical contributor path for NeoAnki2. End-user installation and
study instructions remain in the [user guide]({{ '/user/' | relative_url }});
the pages here cover source builds, tests, architecture, API work,
documentation, and releases.

## Start contributing

1. [Prepare a development checkout](setup/).
2. [Run the supported test and validation commands](testing/).
3. Read the [architecture and dependency rules]({{ '/ARCHITECTURE/' | relative_url }}).

## Change a contract

- [Add or change a local API endpoint](api-development/).
- [Maintain generated and hand-written documentation](documentation/).
- [Work on authored and portable formats]({{ '/reference/' | relative_url }}).
- [Build deck-builder add-ons]({{ '/ADDONS/' | relative_url }}).
- [Build offline vocabulary packs]({{ '/OFFLINE_VOCABULARY/' | relative_url }}).
- [Review the vocabulary API requirements]({{ '/VOCABULARY_API/' | relative_url }}).

## Prepare a release

- [macOS release procedure]({{ '/RELEASING/' | relative_url }})
- [iOS and iPadOS release checklist]({{ '/IOS_RELEASE/' | relative_url }})
- [Local API acceptance evidence]({{ '/reference/local-api-acceptance/' | relative_url }})

## Understand decisions and history

- [Product model]({{ '/PRODUCT/' | relative_url }})
- [Design system]({{ '/DESIGN/' | relative_url }})
- [Shared application and UI layers ADR]({{ '/adr/0001-shared-application-and-ui-layers/' | relative_url }})
- [CloudKit offline-first sync ADR]({{ '/adr/0002-cloudkit-offline-first-sync/' | relative_url }})
- [Application library boundary ADR]({{ '/adr/0003-application-library-boundary/' | relative_url }})
- [Current documentation audit]({{ '/audits/documentation-2026-08-15/' | relative_url }})
- [Persistent spoken-response proposal]({{ '/proposals/persistent-spoken-responses/' | relative_url }})
- [Legacy documentation-maintenance guide]({{ '/user/maintaining-documentation/' | relative_url }})

The repository-level `CONTRIBUTING.md`, `README.md`, and `AGENTS.md` are short
entry points. This guide is the maintained source of contributor instructions.
