---
title: API schemas
description: Generated request and response schemas for the NeoAnki local API.
audience: api
contract_digest: sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098
parent: Local API reference
permalink: /api/schemas/
---

# API schemas

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## Binary {#schema-binary}

Type: **string**.

## BulkItemImpact {#schema-bulkitemimpact}

Type: **object**.

### Properties

- `createdItemCount` — integer; required
- `deletedItemCount` — integer; required
- `replacedItemCount` — integer; required
- `resultingCardCount` — integer; required

## BulkItemOperation {#schema-bulkitemoperation}

Type: **object**.

### Properties

- `action` — string; required
- `item` — CreateItemInput; optional
- `itemId` — string; optional
- `operationId` — string; required

## BulkItemResult {#schema-bulkitemresult}

Type: **object**.

### Properties

- `action` — string; required
- `cardIds` — array of string; required
- `itemId` — string; required
- `operationId` — string; required

## BulkItemsInput {#schema-bulkitemsinput}

Type: **object**.

### Properties

- `atomic` — boolean; required
- `dryRun` — boolean; required
- `operations` — array of BulkItemOperation; required

## BulkItemsResult {#schema-bulkitemsresult}

Type: **object**.

### Properties

- `dryRun` — boolean; required
- `impact` — BulkItemImpact; required
- `results` — array of BulkItemResult; required

## Card {#schema-card}

Type: **object**.

### Properties

- `clozeGroup` — integer or null; optional
- `deckId` — string or null; optional
- `id` — string; required
- `isSuspended` — boolean; required
- `itemId` — string; required
- `memory` — Memory; required
- `revision` — integer; required
- `skill` — Skill; required
- `templateId` — string; required

## CardCollection {#schema-cardcollection}

Type: **object**.

### Properties

- `data` — array of Card; required
- `page` — PageInfo; required

## Change {#schema-change}

Type: **object**.

### Properties

- `cursor` — integer; required
- `occurredAt` — string; required
- `resourceId` — string; required
- `resourceType` — string; required
- `revision` — integer; required
- `sequence` — integer; required
- `tombstone` — boolean; required
- `transactionId` — string; required
- `type` — string; required

## ChangeCollection {#schema-changecollection}

Type: **object**.

### Properties

- `data` — array of Change; required
- `page` — PageInfo; required

## Client {#schema-client}

Type: **object**.

### Properties

- `createdAt` — string; required
- `displayName` — string; required
- `id` — string; required
- `origin` — string or null; optional
- `revision` — integer; required
- `scopes` — array of string; required

## ClozeSpan {#schema-clozespan}

Type: **object**.

### Properties

- `group` — integer; required
- `hint` — string; optional
- `length` — integer; required
- `start` — integer; required

## CommitImportInput {#schema-commitimportinput}

Type: **object**.

### Properties

- `planToken` — string; required

## Condition {#schema-condition}

Type: **object**.

### Properties

- `conditions` — array of Condition; optional
- `fieldId` — string; optional
- `kind` — string; required

## ConfirmInput {#schema-confirminput}

Type: **object**.

### Properties

- `confirm` — boolean; optional

## ContentValue {#schema-contentvalue}

Type: **object or object or object or object or object or object**.

## CreateDeckDeletionPlanInput {#schema-createdeckdeletionplaninput}

Type: **object**.

### Properties

- `deckId` — string; required
- `policy` — string; required

## CreateDeckInput {#schema-createdeckinput}

Type: **object**.

### Properties

- `id` — string; optional
- `name` — string; required
- `newCardsPerDay` — integer or null; optional
- `parentId` — string or null; optional

## CreateExportInput {#schema-createexportinput}

Type: **object**.

### Properties

- `deckId` — string; required
- `format` — string; required

## CreateImportInput {#schema-createimportinput}

Type: **object**.

### Properties

- `csvItemTypeName` — string; optional
- `destinationDeckId` — string; optional
- `files` — array of ImportFileDeclaration; required
- `format` — string; required
- `itemTypeId` — string; optional

## CreateItemInput {#schema-createiteminput}

Type: **object**.

### Properties

- `deckId` — string or null; optional
- `fields` — array of FieldValue; required
- `id` — string; optional
- `itemTypeId` — string; required
- `tags` — array of string; required

## CreateStudySessionInput {#schema-createstudysessioninput}

Type: **object**.

### Properties

- `scope` — StudyScope; required

## CreateVocabularyPackImportInput {#schema-createvocabularypackimportinput}

Type: **object**.

### Properties

- `files` — array of VocabularyPackImportFileInput; required

## Deck {#schema-deck}

Type: **object**.

### Properties

- `childIds` — array of string; required
- `directItemCount` — integer; required
- `dueCount` — integer; required
- `id` — string; required
- `name` — string; required
- `newCardsPerDay` — integer or null; optional
- `parentId` — string or null; optional
- `recursiveItemCount` — integer; required
- `revision` — integer; required

## DeckCollection {#schema-deckcollection}

Type: **object**.

### Properties

- `data` — array of Deck; required
- `page` — PageInfo; required

## DeckDeletionCommitResult {#schema-deckdeletioncommitresult}

Type: **object**.

### Properties

- `committed` — boolean; required
- `impact` — DeckDeletionImpact; required
- `planId` — string; required

## DeckDeletionImpact {#schema-deckdeletionimpact}

Type: **object**.

### Properties

- `cardCount` — integer; required
- `deckCount` — integer; required
- `itemCount` — integer; required
- `mediaReferenceCount` — integer; required
- `reviewLogCount` — integer; required
- `studyResponseCount` — integer; required

## DeckDeletionPlan {#schema-deckdeletionplan}

Type: **object**.

### Properties

- `deckId` — string; required
- `deckRevision` — integer; required
- `dependencyChangeCursor` — integer; required
- `expiresAt` — string; required
- `id` — string; required
- `impact` — DeckDeletionImpact; required
- `policy` — string; required
- `revision` — integer; required

## DeckIdentifierInput {#schema-deckidentifierinput}

Type: **object**.

### Properties

- `deckId` — string; required

## DeckResetCommitResult {#schema-deckresetcommitresult}

Type: **object**.

### Properties

- `committed` — boolean; required
- `impact` — DeckResetImpact; required
- `planId` — string; required

## DeckResetImpact {#schema-deckresetimpact}

Type: **object**.

### Properties

- `cardCount` — integer; required
- `deckCount` — integer; required
- `reviewLogCount` — integer; required

## DeckResetPlan {#schema-deckresetplan}

Type: **object**.

### Properties

- `deckId` — string; required
- `deckRevision` — integer; required
- `dependencyChangeCursor` — integer; required
- `expiresAt` — string; required
- `id` — string; required
- `impact` — DeckResetImpact; required
- `revision` — integer; required

## DuplicateCandidate {#schema-duplicatecandidate}

Type: **object**.

### Properties

- `itemId` — string; required
- `reasonCodes` — array of string; required

## DuplicateCheckResult {#schema-duplicatecheckresult}

Type: **object**.

### Properties

- `candidates` — array of DuplicateCandidate; required

## DuplicateItemTypeInput {#schema-duplicateitemtypeinput}

Type: **object**.

### Properties

- `name` — string; required

## EmptyObject {#schema-emptyobject}

Type: **object**.

## EventStream {#schema-eventstream}

Type: **string**.

## ExportJob {#schema-exportjob}

Type: **object**.

### Properties

- `byteSize` — integer or null; optional
- `createdAt` — string; required
- `deckId` — string; required
- `format` — string; required
- `id` — string; required
- `revision` — integer; required
- `sha256` — string or null; optional
- `state` — string; required
- `updatedAt` — string; required

## FSRSOptimizationRun {#schema-fsrsoptimizationrun}

Type: **object**.

### Properties

- `candidateParameterSetId` — string or null; optional
- `completedAt` — string; required
- `decision` — string; required
- `distinctCardCount` — integer; required
- `eligibleTargetCount` — integer; required
- `excludedCounts` — object; required
- `failureCount` — integer; required
- `foldCount` — integer; required
- `id` — string; required
- `inputFingerprint` — string; required
- `metrics` — object; required
- `presetId` — string; required
- `reason` — string or null; optional
- `startedAt` — string; required
- `studyDayCount` — integer; required
- `trainingCutoff` — string; required

## FSRSOptimizationRunArray {#schema-fsrsoptimizationrunarray}

Type: **array of FSRSOptimizationRun**.

## FSRSParameterSet {#schema-fsrsparameterset}

Type: **object**.

### Properties

- `createdAt` — string; required
- `fixtureChecksum` — string or null; optional
- `id` — string; required
- `inputFingerprint` — string or null; optional
- `isActive` — boolean; required
- `metrics` — object; required
- `modelVersion` — string; required
- `previousParameterSetId` — string or null; optional
- `scope` — string; required
- `source` — string; required
- `sourceChecksum` — string; required
- `trainingCutoff` — string or null; optional
- `upstreamCommit` — string; required
- `weights` — array of number; required

## FSRSParameterSetArray {#schema-fsrsparametersetarray}

Type: **array of FSRSParameterSet**.

## FieldDefinition {#schema-fielddefinition}

Type: **object**.

### Properties

- `id` — string; required
- `isRequired` — boolean; required
- `name` — string; required
- `type` — string; required

## FieldValue {#schema-fieldvalue}

Type: **object**.

### Properties

- `fieldId` — string; required
- `value` — ContentValue; required

## Health {#schema-health}

Type: **object**.

### Properties

- `status` — string; required

## ImpactSummary {#schema-impactsummary}

Type: **object**.

### Properties

- `affectedCardCount` — integer; required
- `affectedItemCount` — integer; required
- `affectedStudyResponseCount` — integer; required

## ImportFile {#schema-importfile}

Type: **object**.

### Properties

- `byteSize` — integer; required
- `id` — string; required
- `relativePath` — string; required
- `sha256` — string; required
- `uploaded` — boolean; required

## ImportFileDeclaration {#schema-importfiledeclaration}

Type: **object**.

### Properties

- `byteSize` — integer; required
- `relativePath` — string; required
- `sha256` — string; required

## ImportJob {#schema-importjob}

Type: **object**.

### Properties

- `createdAt` — string; required
- `files` — array of ImportFile; required
- `format` — string; required
- `id` — string; required
- `planToken` — string or null; optional
- `report` — TransferReport or null; optional
- `revision` — integer; required
- `state` — string; required
- `updatedAt` — string; required

## Item {#schema-item}

Type: **object**.

### Properties

- `cardIds` — array of string; required
- `createdAt` — string; required
- `deckId` — string or null; optional
- `fields` — array of FieldValue; required
- `id` — string; required
- `itemTypeId` — string; required
- `revision` — integer; required
- `tags` — array of string; required
- `updatedAt` — string; required

## ItemCollection {#schema-itemcollection}

Type: **object**.

### Properties

- `data` — array of Item; required
- `page` — PageInfo; required

## ItemType {#schema-itemtype}

Type: **object**.

### Properties

- `fields` — array of FieldDefinition; required
- `id` — string; required
- `itemCount` — integer; required
- `name` — string; required
- `provenance` — string; required
- `revision` — integer; required
- `templates` — array of TemplateDefinition; required

## ItemTypeCollection {#schema-itemtypecollection}

Type: **object**.

### Properties

- `data` — array of ItemType; required
- `page` — PageInfo; required

## ItemTypeInput {#schema-itemtypeinput}

Type: **object**.

### Properties

- `fields` — array of FieldDefinition; required
- `id` — string; optional
- `name` — string; required
- `templates` — array of TemplateDefinition; required

## ItemTypePolicy {#schema-itemtypepolicy}

Type: **object**.

### Properties

- `defaultItemTypeId` — string or null; required
- `itemTypeIds` — array of string; required
- `sourceDeckId` — string or null; required

## LexicalEntry {#schema-lexicalentry}

Type: **object**.

### Properties

- `canonicalForm` — object; required
- `forms` — array of object; required
- `frequency` — number or null; optional
- `id` — string; required
- `language` — string; required
- `pronunciations` — array of object; required
- `provenance` — VocabularyProvenance or null; optional
- `senses` — array of object; required

## LexicalEntryCollection {#schema-lexicalentrycollection}

Type: **object**.

### Properties

- `data` — array of LexicalEntry; required

## LocalizedVocabularyText {#schema-localizedvocabularytext}

Type: **object**.

### Properties

- `language` — string or null; optional
- `value` — string; required

## MediaMetadata {#schema-mediametadata}

Type: **object**.

### Properties

- `assetHash` — string; required
- `byteSize` — integer; required
- `fileExtension` — string; required
- `kind` — string; required
- `referenceCount` — integer; required

## MediaReservation {#schema-mediareservation}

Type: **object**.

### Properties

- `assetHash` — string; required
- `byteSize` — integer; required
- `fileExtension` — string; required
- `kind` — string; required
- `reservationExpiresAt` — string; required
- `reservationId` — string; required

## Memory {#schema-memory}

Type: **object**.

### Properties

- `difficulty` — number; required
- `dueAt` — string; required
- `lapses` — integer; required
- `lastReviewedAt` — string or null; optional
- `phase` — string; required
- `repetitions` — integer; required
- `stabilityDays` — number; required
- `stepIndex` — integer or null; optional

## Meta {#schema-meta}

Type: **object**.

### Properties

- `apiVersion` — integer; required
- `applicationVersion` — string; required
- `capabilities` — array of string; required
- `pairingAvailable` — boolean; required
- `serverInstanceId` — string; required

## MutationCount {#schema-mutationcount}

Type: **object**.

### Properties

- `updatedItemCount` — integer; required

## OpenAPIDocument {#schema-openapidocument}

Type: **object**.

## PageInfo {#schema-pageinfo}

Type: **object**.

### Properties

- `limit` — integer; required
- `nextCursor` — string or null; optional

## PairingInput {#schema-pairinginput}

Type: **object**.

### Properties

- `displayName` — string; required
- `origin` — string or null; optional
- `requestedScopes` — array of string; required

## PairingResult {#schema-pairingresult}

Type: **object**.

### Properties

- `client` — Client; required
- `token` — string; required

## PatchCardInput {#schema-patchcardinput}

Type: **object**.

### Properties

- `isSuspended` — boolean; required

## Presentation {#schema-presentation}

Type: **object**.

### Properties

- `media` — string; required
- `reveal` — string; required

## Problem {#schema-problem}

Type: **object**.

### Properties

- `code` — string; required
- `detail` — string; required
- `errors` — array of ValidationError; optional
- `impact` — ImpactSummary; optional
- `impactToken` — string; optional
- `requestId` — string; required
- `requiredScope` — string; optional
- `status` — integer; required
- `title` — string; required
- `type` — string; required

## RatingPreview {#schema-ratingpreview}

Type: **object**.

### Properties

- `constraintReason` — string or null; optional
- `finalDueAt` — string; required
- `intervalPolicyVersion` — string; required
- `intervalSeconds` — number; required
- `memory` — Memory; required
- `memoryAfter` — Memory; required
- `memoryBefore` — Memory; required
- `modelVersion` — string; required
- `operationalIntervalSeconds` — integer; required
- `parameterSetId` — string or null; optional
- `predictedRetrievability` — number; required
- `presetId` — string or null; optional
- `rating` — string; required
- `rawIntervalDays` — number; required
- `reviewedAt` — string; required
- `timingPolicyVersion` — string; required

## RatingPreviewArray {#schema-ratingpreviewarray}

Type: **array of RatingPreview**.

## RenameTagInput {#schema-renametaginput}

Type: **object**.

### Properties

- `from` — string; required
- `to` — string; required

## ReplaceItemInput {#schema-replaceiteminput}

Type: **object**.

### Properties

- `deckId` — string or null; required
- `fields` — array of FieldValue; required
- `id` — string; optional
- `itemTypeId` — string; required
- `tags` — array of string; required

## RequiredConfirmInput {#schema-requiredconfirminput}

Type: **object**.

### Properties

- `confirm` — boolean; required

## ResolvedSlot {#schema-resolvedslot}

Type: **object**.

### Properties

- `presentation` — Presentation; required
- `value` — ContentValue; required

## ReviewResult {#schema-reviewresult}

Type: **object**.

### Properties

- `changeCursor` — integer; required
- `memory` — Memory; required
- `previousPhase` — string; required
- `resultingPhase` — string; required
- `reviewLogId` — string; required
- `revision` — integer; required

## RichSpan {#schema-richspan}

Type: **object**.

### Properties

- `link` — string; optional
- `styles` — array of string; required
- `text` — string; required
- `textColor` — string; optional
- `textSize` — string; optional

## SchedulingExplanation {#schema-schedulingexplanation}

Type: **object**.

### Properties

- `cardId` — string; required
- `desiredRetention` — number; required
- `elapsedModelDays` — integer; required
- `elapsedSeconds` — number; required
- `elapsedTimePolicy` — string; required
- `intervalPolicy` — string; required
- `modelIdentifier` — string; required
- `parameterSetId` — string or null; optional
- `presetId` — string or null; optional
- `previousMemory` — Memory; required
- `ratings` — RatingPreviewArray; required
- `reviewedAt` — string; required

## SchedulingHealth {#schema-schedulinghealth}

Type: **object**.

### Properties

- `activeParameterSetId` — string or null; optional
- `activeParameterSource` — string or null; optional
- `automaticOptimizationEnabled` — boolean; required
- `canRestoreDefaults` — boolean; required
- `canRollback` — boolean; required
- `desiredRetention` — number; required
- `lastOptimizationCompletedAt` — string or null; optional
- `lastOptimizationDecision` — string or null; optional
- `lastOptimizationReason` — string or null; optional
- `legacyParametersQuarantined` — boolean; required
- `maximumIntervalDays` — integer; required
- `migrationStatus` — string or null; optional
- `modelIdentifier` — string; required
- `optimizerParityVerified` — boolean; required
- `optimizerStatus` — string; required
- `parameterCount` — integer; required
- `parameterSource` — string; required
- `personalizationStatus` — string; required

## SchedulingRollbackInput {#schema-schedulingrollbackinput}

Type: **object**.

### Properties

- `confirm` — boolean; required
- `parameterSetId` — string or null; optional

## Skill {#schema-skill}

Type: **object**.

### Properties

- `input` — string; required
- `operation` — string; required
- `output` — string; required

## SkipStudyCardInput {#schema-skipstudycardinput}

Type: **object**.

### Properties

- `cardId` — string; required

## Slot {#schema-slot}

Type: **object**.

### Properties

- `presentation` — Presentation; required
- `source` — SlotSource; required

## SlotSource {#schema-slotsource}

Type: **object**.

### Properties

- `fieldId` — string; optional
- `kind` — string; required
- `text` — string; optional

## StudyCard {#schema-studycard}

Type: **object**.

### Properties

- `answer` — array of ResolvedSlot; required
- `clozeGroup` — integer or null; optional
- `deckId` — string or null; optional
- `id` — string; required
- `interaction` — string; required
- `itemId` — string; required
- `memory` — Memory; required
- `prompt` — array of ResolvedSlot; required
- `revision` — integer; required
- `templateId` — string; required

## StudyResponse {#schema-studyresponse}

Type: **object**.

### Properties

- `assetHash` — string; required
- `byteSize` — integer; required
- `capturedAt` — string; required
- `cardId` — string; required
- `contentType` — string; required
- `durationMs` — integer; required
- `fileExtension` — string; required
- `id` — string; required
- `itemId` — string; required
- `revision` — integer; required
- `sourceTitle` — string; required
- `submittedAt` — string; required

## StudyResponseCollection {#schema-studyresponsecollection}

Type: **object**.

### Properties

- `data` — array of StudyResponse; required
- `page` — PageInfo; required

## StudyScope {#schema-studyscope}

Type: **object**.

### Properties

- `deckId` — string; optional
- `includeDescendants` — boolean; optional
- `kind` — string; required

## StudySession {#schema-studysession}

Type: **object**.

### Properties

- `createdAt` — string; required
- `currentCardId` — string or null; optional
- `id` — string; required
- `lastActivityAt` — string; required
- `revision` — integer; required
- `scope` — StudyScope; required
- `state` — string; required

## SubmitReviewInput {#schema-submitreviewinput}

Type: **object**.

### Properties

- `cardId` — string; required
- `durationMs` — integer; required
- `rating` — string; required
- `sessionId` — string; required

## Tag {#schema-tag}

Type: **object**.

### Properties

- `itemCount` — integer; required
- `name` — string; required
- `revision` — integer; required

## TagCollection {#schema-tagcollection}

Type: **object**.

### Properties

- `data` — array of Tag; required
- `page` — PageInfo; required

## TemplateDefinition {#schema-templatedefinition}

Type: **object**.

### Properties

- `answer` — array of Slot; required
- `generateWhen` — Condition; optional
- `id` — string; required
- `interaction` — string; required
- `name` — string; required
- `prompt` — array of Slot; required
- `skill` — Skill; required

## TransferReport {#schema-transferreport}

Type: **object**.

### Properties

- `createdItemTypeCount` — integer; required
- `deckCount` — integer; required
- `itemCount` — integer; required
- `reusedItemTypeCount` — integer; required
- `warnings` — array of string; required

## UpdateDeckInput {#schema-updatedeckinput}

Type: **object**.

### Properties

- `name` — string; optional
- `newCardsPerDay` — integer or null; optional
- `parentId` — string or null; optional

## ValidationError {#schema-validationerror}

Type: **object**.

### Properties

- `code` — string; required
- `pointer` — string; required

## VocabularyPack {#schema-vocabularypack}

Type: **object**.

### Properties

- `capabilities` — array of string; required
- `databaseSha256` — string; required
- `entryCount` — integer; required
- `id` — string; required
- `languages` — array of string; required
- `mediaByteCount` — integer; required
- `mediaFileCount` — integer; required
- `provenance` — VocabularyProvenance or null; optional
- `revision` — integer; required
- `summary` — string or null; optional
- `title` — string; required

## VocabularyPackCollection {#schema-vocabularypackcollection}

Type: **object**.

### Properties

- `data` — array of VocabularyPack; required

## VocabularyPackImport {#schema-vocabularypackimport}

Type: **object**.

### Properties

- `createdAt` — string; required
- `files` — array of VocabularyPackImportFile; required
- `id` — string; required
- `pack` — VocabularyPack or null; optional
- `revision` — integer; required
- `state` — string; required
- `updatedAt` — string; required

## VocabularyPackImportFile {#schema-vocabularypackimportfile}

Type: **object**.

### Properties

- `byteSize` — integer; required
- `id` — string; required
- `path` — string; required
- `sha256` — string; required
- `uploaded` — boolean; required

## VocabularyPackImportFileInput {#schema-vocabularypackimportfileinput}

Type: **object**.

### Properties

- `byteSize` — integer; required
- `id` — string; required
- `path` — string; required
- `sha256` — string; required

## VocabularyProvenance {#schema-vocabularyprovenance}

Type: **object**.

### Properties

- `attribution` — string or null; optional
- `license` — string or null; optional
- `recordId` — string or null; optional
- `sourceId` — string; required
- `sourceName` — string or null; optional
- `sourceUrl` — string or null; optional

Contract digest: `sha256:e3d1f9032b959e51db40c7fd95fbcc86363e640d4198057f58f0d19293017098`.

_Generated from the runtime schema catalog; do not edit by hand._
