# Functional UI coverage manifest

`NeoAnki2UITests/FastFunctionalJourneyTests.swift` is the executable
one-to-one coverage map. Every `runLegacyCheck` activity names the original
test identifier and invokes its preserved assertion body.

| Journey | Legacy suites | Checks |
| --- | --- | ---: |
| Library and Browse | `ScopeHomeAndBrowseUITests`, `LibraryUITests` | 27 |
| Decks and Authoring | `DeckUITests`, `AuthoringUITests`, shared checks from `LibraryUITests` | 21 |
| Templates and Item Types | `TemplatesUITests`, `TemplatesAdvancedUITests` | 23 |
| Study and Scheduling | `StudyUITests`, `StudyExtendedUITests`, scheduling completion checks | 31 |
| Import and Portable Transfer | `ImportExportUITests`, `PortableDeckUITests`, import checks from `LibraryUITests` | 15 |
| Launch, Gating, and Accessibility | `NavigationGatingUITests`, import gating, bootstrap check from `LibraryUITests` | 9 |
| Offline Vocabulary | Separate pack import, repeated additions to an existing deck | — |
| **Total** |  | **126** |

`FunctionalUICoverageManifestTests` derives the legacy identifiers from the
check declarations and compares them with the activity identifiers. It fails
for an omitted, duplicated, or renamed mapping, enforces exactly seven
functional journeys, and checks that every macOS and iOS test method appears
in the required CI shard manifest.

Focused reruns accept one or more journey or legacy activity identifiers:

```sh
./Scripts/run-ui-tests.sh FastFunctionalJourneyTests/testStudyAndSchedulingJourney
./Scripts/run-ui-tests.sh \
  StudyUITests.testStudyBasicItemFlow \
  StudyUITests.testTypedAnswerReportsIncorrectResponse
```
