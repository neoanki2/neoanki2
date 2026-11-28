---
title: Vocabulary
description: Generated NeoAnki local API operations for vocabulary.
audience: api
contract_digest: sha256:c114fc88950349745721ed5dde845a5cbfabaac69eb2ab4e486831899501bc97
parent: Local API reference
permalink: /api/vocabulary/
---

# Vocabulary

[API reference]({{ '/api/' | relative_url }}) · [OpenAPI JSON]({{ '/api/openapi.json' | relative_url }})

## `GET /v1/known-words`

List known words through the loopback-only NeoAnki API. Rows include state, the state of this exact term, and expressionState, the combined state of the spelling across all its meanings, which is the state to show for the word in text. Filter by expression to read one spelling; expression requires language and matches as a reader would, ignoring case, spacing, and, for Ukrainian, Russian, and Belarusian, stress marks and apostrophe variants. origin archivedReviews marks a word kept as known after the cards that proved it were deleted.

- **Operation ID:** `listKnownWords`
- **Authorization:** Bearer token with `known-words.read`
- **Success:** `200` with [KnownWordCollection]({{ '/api/schemas/#schema-knownwordcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `language` — query; optional. The language query parameter.
- `expression` — query; optional. Spelling to match as a reader would. Requires language.
- `limit` — query; optional. Maximum number of results to return.
- `cursor` — query; optional. Opaque cursor returned by the preceding page.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/known-words' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/known-words/judgment-batches`

Record vocabulary judgment batch through the loopback-only NeoAnki API. Records 1 to 20,000 judgments in one change. The Idempotency-Key identifies the batch: retrying it returns the first receipt. Judgments that already apply are counted as unchanged and not written again. Use batchId to undo the whole change.

- **Operation ID:** `recordVocabularyJudgmentBatch`
- **Authorization:** Bearer token with `known-words.write`
- **Success:** `201` with [VocabularyJudgmentBatchReceipt]({{ '/api/schemas/#schema-vocabularyjudgmentbatchreceipt' | relative_url }})
- **Request body:** [VocabularyJudgmentBatchInput]({{ '/api/schemas/#schema-vocabularyjudgmentbatchinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/known-words/judgment-batches' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/known-words/judgment-batches/{id}/undo`

Undo vocabulary judgment batch through the loopback-only NeoAnki API. Restores the judgment each word had before the batch, except for words changed again since, which are counted as unchanged. The receipt describes the undo, whose batchId is new; retrying with the same Idempotency-Key returns the same receipt.

- **Operation ID:** `undoVocabularyJudgmentBatch`
- **Authorization:** Bearer token with `known-words.write`
- **Success:** `200` with [VocabularyJudgmentBatchReceipt]({{ '/api/schemas/#schema-vocabularyjudgmentbatchreceipt' | relative_url }})
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/known-words/judgment-batches/{id}/undo' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/known-words/judgments`

Record vocabulary judgment through the loopback-only NeoAnki API. Judgments are known, unfamiliar, ignored, or reviewHistory. Ignored hides a word, such as a name or brand, from reading highlights and word counts. term.lemma optionally records the dictionary form the spelling belongs to. Other judgment values are rejected.

- **Operation ID:** `recordVocabularyJudgment`
- **Authorization:** Bearer token with `known-words.write`
- **Success:** `200` with [VocabularyJudgmentChange]({{ '/api/schemas/#schema-vocabularyjudgmentchange' | relative_url }})
- **Request body:** [VocabularyJudgmentInput]({{ '/api/schemas/#schema-vocabularyjudgmentinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/known-words/judgments' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/known-words/snapshot`

Get known words snapshot through the loopback-only NeoAnki API. Returns the combined reading state of every spelling (expressions) and dictionary form (lemmas) in one language, keyed by match key. Pass the version of a snapshot you hold as since; while it is still current the response contains only version, language, and unchanged true. To find the state of a word in text, use expressions for its match key; otherwise resolve its dictionary forms with a vocabulary pack and look each up in lemmas, then expressions. The word is known if every form is known or ignored and at least one is known, ignored if all are ignored, learning if any is learning, and unassessed otherwise.

- **Operation ID:** `getKnownWordsSnapshot`
- **Authorization:** Bearer token with `known-words.read`
- **Success:** `200` with [KnownWordsSnapshot]({{ '/api/schemas/#schema-knownwordssnapshot' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `language` — query; required. The language query parameter.
- `since` — query; optional. Version of a snapshot the caller already holds.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/known-words/snapshot' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/vocabulary-pack-imports`

Create vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `createVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `201` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** [CreateVocabularyPackImportInput]({{ '/api/schemas/#schema-createvocabularypackimportinput' | relative_url }})
- **Success headers:** `ETag`, `Location`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `DELETE /v1/vocabulary-pack-imports/{id}`

Delete vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `deleteVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request DELETE \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-pack-imports/{id}`

Get vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `getVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/vocabulary-pack-imports/{id}/commits`

Commit vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `commitVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`, `Location`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}/commits' \
  --header 'Authorization: Bearer <token>'
```
## `PUT /v1/vocabulary-pack-imports/{id}/files/{fileId}`

Upload vocabulary pack file through the loopback-only NeoAnki API.

- **Operation ID:** `uploadVocabularyPackFile`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Success headers:** `ETag`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `fileId` — path; required. Staged file identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request PUT \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}/files/{fileId}' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `POST /v1/vocabulary-pack-imports/{id}/validations`

Validate vocabulary pack import through the loopback-only NeoAnki API.

- **Operation ID:** `validateVocabularyPackImport`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `200` with [VocabularyPackImport]({{ '/api/schemas/#schema-vocabularypackimport' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`, `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-pack-imports/{id}/validations' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs`

List vocabulary packs through the loopback-only NeoAnki API.

- **Operation ID:** `listVocabularyPacks`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [VocabularyPackCollection]({{ '/api/schemas/#schema-vocabularypackcollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs' \
  --header 'Authorization: Bearer <token>'
```
## `DELETE /v1/vocabulary-packs/{id}`

Delete vocabulary pack through the loopback-only NeoAnki API.

- **Operation ID:** `deleteVocabularyPack`
- **Authorization:** Bearer token with `vocabulary.write`
- **Success:** `204` with no response body
- **Request body:** None
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.
- `If-Match` — header; required. Current quoted resource revision.

### Example request

```bash
curl --request DELETE \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}`

Get vocabulary pack through the loopback-only NeoAnki API.

- **Operation ID:** `getVocabularyPack`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [VocabularyPack]({{ '/api/schemas/#schema-vocabularypack' | relative_url }})
- **Request body:** None
- **Success headers:** `ETag`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/vocabulary-packs/{id}/dictionary-forms`

Resolve dictionary forms through the loopback-only NeoAnki API. Maps up to 2,000 words from text to the dictionary forms the pack lists for them, at most eight each. Matching ignores case and, where dictionaries mark stress, the stress marks that ordinary text omits. Words the pack does not contain are omitted from data.

- **Operation ID:** `resolveDictionaryForms`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [DictionaryForms]({{ '/api/schemas/#schema-dictionaryforms' | relative_url }})
- **Request body:** [DictionaryFormsInput]({{ '/api/schemas/#schema-dictionaryformsinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `Idempotency-Key` — header; optional. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/dictionary-forms' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```
## `GET /v1/vocabulary-packs/{id}/entries`

Search vocabulary entries through the loopback-only NeoAnki API.

- **Operation ID:** `searchVocabularyEntries`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [LexicalEntryCollection]({{ '/api/schemas/#schema-lexicalentrycollection' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `query` — query; required. Search text.
- `mode` — query; optional. The mode query parameter.
- `limit` — query; optional. Maximum number of results to return.
- `language` — query; optional. The language query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/entries' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}/entries/{entryId}`

Get vocabulary entry through the loopback-only NeoAnki API.

- **Operation ID:** `getVocabularyEntry`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [LexicalEntry]({{ '/api/schemas/#schema-lexicalentry' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `entryId` — path; required. The entryId path parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/entries/{entryId}' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}/frequency-band`

Get vocabulary frequency band through the loopback-only NeoAnki API. Lists the pack's dictionary forms for a language from most to least frequent. offset and limit (1 to 20,000, default 1,000) select a band; sample instead returns that many evenly spaced words from the band, for placement checks. total counts every ranked form in the language.

- **Operation ID:** `getVocabularyFrequencyBand`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [VocabularyFrequencyBand]({{ '/api/schemas/#schema-vocabularyfrequencyband' | relative_url }})
- **Request body:** None
- **Success headers:** None
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `language` — query; required. The language query parameter.
- `offset` — query; optional. Number of most frequent words to skip.
- `limit` — query; optional. Maximum number of results to return.
- `sample` — query; optional. Number of evenly spaced words to return from the band.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/frequency-band' \
  --header 'Authorization: Bearer <token>'
```
## `GET /v1/vocabulary-packs/{id}/media`

Download vocabulary media through the loopback-only NeoAnki API.

- **Operation ID:** `downloadVocabularyMedia`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with [Binary]({{ '/api/schemas/#schema-binary' | relative_url }})
- **Request body:** None
- **Success headers:** `Accept-Ranges`, `Content-Length`, `Digest`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `path` — query; required. The path query parameter.

### Example request

```bash
curl --request GET \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/media' \
  --header 'Authorization: Bearer <token>'
```
## `HEAD /v1/vocabulary-packs/{id}/media`

Head vocabulary media through the loopback-only NeoAnki API.

- **Operation ID:** `headVocabularyMedia`
- **Authorization:** Bearer token with `vocabulary.read`
- **Success:** `200` with no response body
- **Request body:** None
- **Success headers:** `Accept-Ranges`, `Content-Length`, `Digest`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `id` — path; required. Resource identifier.
- `path` — query; required. The path query parameter.

### Example request

```bash
curl --request HEAD \
  'http://127.0.0.1:8766/v1/vocabulary-packs/{id}/media' \
  --header 'Authorization: Bearer <token>'
```
## `POST /v1/vocabulary-sets`

Create vocabulary set through the loopback-only NeoAnki API.

- **Operation ID:** `createVocabularySet`
- **Authorization:** Bearer token with `items.write`
- **Success:** `201` with [VocabularySetReceipt]({{ '/api/schemas/#schema-vocabularysetreceipt' | relative_url }})
- **Request body:** [VocabularySetInput]({{ '/api/schemas/#schema-vocabularysetinput' | relative_url }})
- **Success headers:** `X-NeoAnki-Change-Cursor`
- **Errors:** `default` using the [shared problem format]({{ '/api/errors/' | relative_url }})

### Parameters

- `Idempotency-Key` — header; required. Caller-generated key used to replay a mutation safely.

### Example request

```bash
curl --request POST \
  'http://127.0.0.1:8766/v1/vocabulary-sets' \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: application/json' \
  --data '<request-json>'
```

Contract digest: `sha256:c114fc88950349745721ed5dde845a5cbfabaac69eb2ab4e486831899501bc97`.

_Generated from the runtime endpoint registry; do not edit by hand._
