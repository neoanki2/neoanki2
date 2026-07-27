---
title: Deck builder addons
description: Extend NeoAnki with bundled or external deck builders without adding subject-specific behavior to Core.
parent: Architecture
---

# Deck builder addons

NeoAnki deck builders are app-level features that produce an authored `.neoanki`
bundle. They do not extend `NeoAnkiCore`, receive an `ItemStore`, or write directly
to a library database.

## Boundaries

`NeoAnkiDeckBuilderKit` defines the host contract, temporary workspace ownership,
builder metadata, and SwiftUI entry point. A bundled builder depends on that kit
and may use the public authored-deck validation API. `NeoAnki2` explicitly
registers the builders included in a release.

The data flow is:

```text
builder input -> generated .neoanki -> AuthoredDeck validation -> normal import
```

The host creates a private temporary workspace for each build. The builder writes
only inside that workspace, uses generated filesystem names, and returns the
bundle URL. The host validates and imports the bundle through the existing
authored-deck path, then removes the complete workspace.

This direction keeps Core domain-neutral:

```text
NeoAnki2 -> bundled builder -> NeoAnkiDeckBuilderKit
         -> NeoAnkiCore authored-deck import
```

`NeoAnkiCore` never depends on a builder.

## Distribution models

### Bundled builders

Bundled builders are Swift packages compiled into NeoAnki2 and registered by the
app. They provide an integrated experience on Apple platforms, but users cannot
install new native code after the app ships.

`PoemDeckBuilder` is the first bundled builder. It creates an author root deck,
a poem child deck, and one Basic card for each line after the first. Each prompt
contains the preceding one or two nonblank lines.

### External builders

A CLI, website, agent, or companion app can generate the same `.neoanki` format.
Users import that document with NeoAnki2. This is the preferred third-party
extension model because it works on macOS and iOS without loading third-party
code into NeoAnki2.

### Native extensions

macOS can support separately installed providers with ExtensionKit and a
versioned IPC contract. iOS does not currently allow a third-party app to host
native extensions supplied by another third-party app; custom extensions are
limited to code shipped with the containing app. NeoAnki therefore does not use
native extension loading as its cross-platform addon contract.

### Declarative or scripted addons

A future declarative recipe format could add downloadable behavior while keeping
the host in control of supported operations. General JavaScript or Wasm plugins
would require a separate capability model, resource limits, package integrity,
and App Review analysis. They are not part of the current builder contract.

## Adding a bundled builder

1. Add a package target outside `NeoAnkiCore`.
2. Implement generation into a host-provided workspace.
3. Emit a versioned `.neoanki` bundle and validate it before returning.
4. Expose an `AnyDeckBuilderFeature` with stable metadata and a SwiftUI form.
5. Register the feature in the app composition root.
6. Test generated JSONL, validation, import, schema reuse, and workspace cleanup.

Builders must not embed credentials, load executable code, derive paths from raw
user input, follow symlinks, or bypass authored-deck limits and media validation.
