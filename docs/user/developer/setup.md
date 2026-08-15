---
title: Development setup
description: Prepare a Swift 6 checkout and build NeoAnki2 for macOS or iOS.
audience: developer
parent: Developer Guide
permalink: /user/developer/setup/
---

# Development setup

## Requirements

- macOS 14 or newer;
- Git; and
- Xcode or Xcode Command Line Tools with Swift tools 6.0 or newer; and
- the iOS 17 SDK or newer for iPhone, iPad, and widget builds.

Verify the command-line environment:

```bash
sw_vers -productVersion
xcode-select -p
swift --version
git --version
```

Clone the repository and enter its root:

```bash
git clone https://github.com/neoanki2/neoanki2.git
cd neoanki2
```

## Build without opening an app window

The supported headless package build is:

```bash
swift build
```

Run the executable attached to Terminal only when interactive app verification
is required:

```bash
./Scripts/run-app.sh cli
```

The bundled app path, `./Scripts/run-app.sh`, opens a macOS window and is not
required for model, contract, or documentation changes.

Build the iPhone/iPad app and widget without signing:

```bash
./Scripts/build-ios.sh
```

Device, CloudKit, widget, and TestFlight work additionally requires the Apple
identifiers and provisioning described in the
[iOS release checklist]({{ '/IOS_RELEASE/' | relative_url }}).

## Local data

Development and installed macOS builds normally share
`~/Library/Application Support/neoanki2/`. Never run two instances against the
same library, and back it up before testing migrations or unreleased builds.

**Next:** [Run tests and validation](../testing/)
