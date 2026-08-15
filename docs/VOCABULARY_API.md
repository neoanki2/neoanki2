---
title: Vocabulary API requirements
description: Normative version-1 contract for discovering, querying, installing, and removing managed offline vocabulary packs.
audience: developer
parent: Developer Guide
---

# Vocabulary API requirements

This document is normative for the version-1 local vocabulary API. The words
MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED,
MAY, and OPTIONAL have the meanings defined by RFC 2119 and RFC 8174.

The vocabulary API exposes NeoAnki's managed, offline `.neovocab` library. It
does not download dictionaries, resolve remote URLs, expose arbitrary local
paths, or allow a client to modify entries inside an installed pack. General
transport, authentication, problem responses, idempotency, and precondition
rules remain those of [Local API requirements]({{ '/LOCAL_API/' | relative_url }}).

## 1. Authorization model

Two independent scopes govern vocabulary operations:

- `vocabulary.read` permits listing installed packs, reading pack metadata,
  searching and retrieving lexical entries, and downloading declared pack
  media.
- `vocabulary.write` permits creating and managing staged pack imports and
  deleting installed packs.

Neither scope permits item creation. A client that converts lexical entries
into NeoAnki items MUST separately hold `items.write` and use the item API.
`library.read`, `library.import`, and filesystem access MUST NOT be treated as
substitutes for either vocabulary scope.

**Acceptance criteria**

- **VOC-SEC-001:** A token with only `vocabulary.read` succeeds on every read
  route and receives `403 insufficient_scope` on every lifecycle mutation.
- **VOC-SEC-002:** A token with only `vocabulary.write` can manage import jobs
  and remove a pack but receives `403 insufficient_scope` on pack, entry, and
  media reads.
- **VOC-SEC-003:** Pairing approval and current-client representations preserve
  the exact requested vocabulary scopes without implicitly granting
  `library.read`, `library.import`, or `items.write`.

## 2. Installed pack resources

Installed packs are immutable resources with revision `1`. Their identifier is
the manifest `id`, not the managed directory name. Clients MUST percent-encode
pack and entry identifiers as individual path segments. NeoAnki MUST reject an
empty identifier, invalid percent encoding, an identifier larger than 65,536
UTF-8 bytes, duplicate installed manifest IDs, and a managed directory that no
longer validates as a complete vocabulary pack.

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/vocabulary-packs` | `vocabulary.read` | List installed packs |
| `GET` | `/v1/vocabulary-packs/{id}` | `vocabulary.read` | Read immutable pack metadata |
| `DELETE` | `/v1/vocabulary-packs/{id}` | `vocabulary.write` | Remove an installed pack |

Pack representations contain `id`, `revision`, `title`, optional `summary`,
sorted languages and capabilities, optional provenance, `entryCount`,
`databaseSha256`, `mediaFileCount`, and `mediaByteCount`. List order is stable:
Unicode-normalized title, then pack ID. At most 1,000 installed packs are
accepted. `DELETE` requires `If-Match: "revision-1"`; a stale or missing
precondition performs no filesystem mutation.

Deleting a pack does not modify items previously generated from it. Removing a
pack recursively removes only the exact managed `.neovocab` directory resolved
by its validated manifest ID. Hidden staging directories and arbitrary paths
are never candidates for deletion.

**Acceptance criteria**

- **VOC-PACK-001:** Listing two valid packs returns both exactly once in stable
  title/ID order, exposes no managed filesystem path, and reports manifest
  counts and digests exactly.
- **VOC-PACK-002:** Reading an existing ID returns the same representation and
  `ETag: "revision-1"`; an unknown ID returns `404 resource_not_found`.
- **VOC-PACK-003:** A correct delete precondition removes only the selected
  managed directory and makes subsequent reads return 404; missing and stale
  preconditions leave every byte unchanged.
- **VOC-PACK-004:** Duplicate manifest IDs, symlinks, checksum changes,
  unexpected files, or an installed-pack count above 1,000 fail closed without
  returning partial results or reading outside the managed root.

## 3. Lexical lookup and media

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `GET` | `/v1/vocabulary-packs/{id}/entries` | `vocabulary.read` | Search entries |
| `GET` | `/v1/vocabulary-packs/{id}/entries/{entryId}` | `vocabulary.read` | Read one complete entry |
| `GET`, `HEAD` | `/v1/vocabulary-packs/{id}/media?path=…` | `vocabulary.read` | Download declared local media |

Entry search requires exactly one non-empty `query`. `mode` is `prefix` by
default and MAY be `prefix` or `exact`. `limit` defaults to 50 and MUST be from
1 through 500. `language` is OPTIONAL and matches the pack's indexed language
field. Query, language, pack ID, entry ID, and media path are each limited to
65,536 UTF-8 bytes. Unknown query members and repeated scalar members are
rejected.

Search returns complete language-neutral `LexicalEntry` values in the exact
deterministic order produced by the pack index. No network lookup or fallback
is permitted, including fallback to authored-deck sources. Exact entry lookup
returns `404 resource_not_found` when the pack or entry is absent.

The first access to an installed pack during an API service lifetime MUST
perform complete package, schema, database-digest, and media validation. The
server MAY reuse that open, read-only pack for later operations only while a
fresh filesystem fingerprint is identical. The fingerprint MUST cover the
complete relative package tree and each entry's file type, device, inode, size,
modification time, metadata-change time, and permissions. A missing, added,
renamed, replaced, resized, rewritten, linked, or permission-changed entry MUST
invalidate the cache and require complete validation before any lookup result
is returned. Cache reuse MUST NOT weaken per-request media verification.

Media lookup accepts the safe relative path already present in an entry's audio
reference. The path MUST name a file declared by the manifest and still match
its declared byte size and SHA-256. `GET` returns the bytes with
`Content-Length`, `Digest`, `Accept-Ranges: none`, and a non-executable content
type derived from the file extension. `HEAD` returns identical headers and no
body. Range requests return `416 range_not_supported`.

**Acceptance criteria**

- **VOC-LOOKUP-001:** Prefix, exact, language-filtered, and bounded searches
  return the same entry sequence as `VocabularyPack.search` for the same pack.
- **VOC-LOOKUP-002:** Empty, repeated, over-limit, or unknown search parameters,
  an unknown mode, and limits outside 1...500 return pointer-specific 422
  responses without opening an unrelated file.
- **VOC-LOOKUP-003:** Entry retrieval round-trips every lexical field,
  pronunciation, sense, example, scalar range, frequency, and provenance value
  from the pack database.
- **VOC-LOOKUP-004:** Repeated list, search, and entry operations against one
  unchanged installed pack perform exactly one complete pack open per API
  service lifetime; changing any package-tree signature forces another complete
  validation, and tampered bytes fail closed without an authored fallback.
- **VOC-MEDIA-001:** Declared media round-trips byte-for-byte through GET; HEAD
  returns the same length and digest with an empty body.
- **VOC-MEDIA-002:** Traversal paths, undeclared files, symlinks, changed bytes,
  and range requests fail without disclosing a path or any unrelated bytes.
- **VOC-OFFLINE-001:** A lookup suite with networking unavailable produces the
  same results as an ordinary run and no API code attempts a network request.

## 4. Staged pack installation

Pack installation is a durable staged job. A client declares the complete file
set before uploading bytes; the server never accepts a local path or URL.

| Method | Path | Scope | Operation |
| --- | --- | --- | --- |
| `POST` | `/v1/vocabulary-pack-imports` | `vocabulary.write` | Create a staged import |
| `GET` | `/v1/vocabulary-pack-imports/{id}` | `vocabulary.write` | Inspect status and revision |
| `PUT` | `/v1/vocabulary-pack-imports/{id}/files/{fileId}` | `vocabulary.write` | Upload one declared file |
| `POST` | `/v1/vocabulary-pack-imports/{id}/validations` | `vocabulary.write` | Validate the complete pack |
| `POST` | `/v1/vocabulary-pack-imports/{id}/commits` | `vocabulary.write` | Atomically install it |
| `DELETE` | `/v1/vocabulary-pack-imports/{id}` | `vocabulary.write` | Cancel and remove staging |

Creation accepts 2 through 100,002 unique file declarations. Each declaration
contains a lowercase UUID `id`, safe relative `path`, nonnegative `byteSize`,
and lowercase SHA-256. Exactly one `manifest.json` is required. The total
declared size MUST NOT exceed 4,000,000,000 bytes, a file MUST NOT exceed
4,000,000,000 bytes, and paths MUST be unique, Unicode NFC, non-hidden, and
limited to `manifest.json`, one top-level database file, or descendants of
`media/`. Absolute paths, empty components, `.`, `..`, backslashes, control
characters, and symbolic links are forbidden.

Jobs progress through `awaitingFiles`, `ready`, `validated`, and `completed`.
Every uploaded file must exactly match its declaration before it is persisted.
Upload, commit, and deletion require the current `If-Match`. Validation opens
the staged package through `VocabularyPack.open`, including schema, digest,
media, containment, and configured-limit checks. Commit additionally requires
`Idempotency-Key`; it atomically moves the validated directory into the managed
library under an opaque directory name. An already-installed manifest ID
returns `409 resource_conflict`.

Incomplete jobs and their private staging bytes expire after 24 hours. Job
metadata, uploaded bytes, validation state, and a completed pack representation
survive an API service restart. Staging directories use owner-only permissions
and are ignored by installed-pack enumeration.

**Acceptance criteria**

- **VOC-IMPORT-001:** Declaring, uploading, validating, and committing every
  file of a valid pack installs one byte-equivalent pack that is immediately
  listable and searchable.
- **VOC-IMPORT-002:** Unsafe/duplicate paths, bad UUIDs, uppercase or malformed
  hashes, illegal counts, and per-file or total size overflow are rejected at
  job creation without creating a staging directory.
- **VOC-IMPORT-003:** An undeclared file, wrong byte count, or wrong digest is
  rejected without changing job revision or retaining the rejected bytes.
- **VOC-IMPORT-004:** Validation before all uploads and validation of any
  malformed, tampered, symlinked, unsupported, or over-limit pack fail without
  changing the installed library.
- **VOC-IMPORT-005:** Commit requires the exact validated revision and an
  idempotency key. Replaying the same commit returns the same logical pack;
  stale, conflicting, or duplicate-ID commits install no second directory.
- **VOC-IMPORT-006:** Restarting the API after each job state preserves the
  exact job, uploaded files, ETag, and ability to continue; expiry or explicit
  cancellation removes only that job's private staging tree.
- **VOC-IMPORT-007:** Two concurrent commits for the same manifest ID result in
  one installed pack and one conflict, never two packs or a partial directory.

## 5. Release gate

- **VOC-REL-001:** Every route, request/response schema, query member, header,
  success status, scope, and documented error is present in the shipped OpenAPI
  document and exercised through `NeoAnkiAPIService`.
- **VOC-REL-002:** The full API, vocabulary-kit, application, and documentation
  suites pass with the same pinned Swift toolchain used by CI.
- **VOC-REL-003:** No response, problem detail, event, log, OpenAPI example, or
  test artifact contains a managed vocabulary root or staging path.
- **VOC-REL-004:** The app and local API receive the same managed vocabulary
  root during bootstrap, so a pack imported by either surface is visible to the
  other without restart.
