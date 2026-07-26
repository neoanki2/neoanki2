# NeoAnki Portable Deck Format (`.neodeck`)

## 1. Status and scope

This document is the normative specification for **NeoAnki Portable Deck
Format version 1**. The key words **MUST**, **MUST NOT**, **REQUIRED**,
**SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as described by
RFC 2119 and RFC 8174.

A `.neodeck` file is one SQLite database containing deck structure, item-type
definitions, item content, tags, and media bytes. Version 1 is a
**content-only** interchange format. It never contains cards, scheduling
state, review history, statistics, scheduler parameters, suspension state, or
other learner progress.

This is not the NeoAnki library database schema and MUST NOT be opened as one.
It is not compatible with Anki `.apkg` or `.colpkg` files.

## 2. SQLite container identity

Writers MUST produce a SQLite 3 database with:

- filename extension `.neodeck`;
- page-header `application_id` equal to `0x4E44454B` (ASCII `NDEK`,
  decimal `1313097035`);
- `user_version` equal to `1`;
- UTF-8 text encoding;
- foreign-key enforcement enabled while writing; and
- no attached databases, virtual tables, triggers, views, or executable SQL.

The required initialization pragmas are:

```sql
PRAGMA application_id = 1313097035;
PRAGMA user_version = 1;
PRAGMA encoding = 'UTF-8';
PRAGMA foreign_keys = ON;
```

Readers MUST inspect `application_id` and `user_version` before reading
application data. A reader MUST reject a file with a different
`application_id`. A version-1 reader MUST reject `user_version > 1`; it MUST
NOT guess at a newer schema. A reader MAY support older versions through an
explicit migration, but version 1 defines no older version.

The schema uses only portable SQLite storage classes and features available in
SQLite 3.24 or later. UUIDs and timestamps are text, JSON is UTF-8 text, and
digests and media are blobs. The JSON1 extension is not required.

## 3. Common representations

### 3.1 UUIDs

Every `*_id` value is a lowercase RFC 4122 UUID string in the form
`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (36 ASCII characters). Braces, URNs,
uppercase letters, and nil UUIDs are invalid.

IDs identify rows only within the portable file unless explicitly described as
an origin ID. Writers MUST NOT encode meaning into a UUID.

### 3.2 Timestamps

Timestamps are UTC RFC 3339 strings with exactly three fractional digits:
`YYYY-MM-DDTHH:MM:SS.sssZ`. Calendar values MUST be real dates. Numeric Unix
timestamps and local-time offsets are invalid.

### 3.3 Boolean values

SQLite booleans are `INTEGER NOT NULL` constrained to `0` or `1`. JSON
booleans are JSON `true` or `false`, never `0` or `1`.

### 3.4 Digests

All digests are raw 32-byte SHA-256 values stored as SQLite `BLOB`s. JSON media
references encode the same digest as exactly 64 lowercase hexadecimal
characters.

### 3.5 Canonical JSON

Columns ending in `_json` MUST contain one complete UTF-8 JSON value:

- encoded according to the JSON Canonicalization Scheme (JCS), RFC 8785;
- with no byte-order mark, comments, trailing data, duplicate object keys,
  `NaN`, or infinities;
- using only the members defined by this specification;
- with absent optional members omitted, not set to `null`; and
- with arrays retained in their specified semantic order.

Readers MUST accept semantically valid non-canonical JSON in version-1 files,
but MUST canonicalize it before digest comparison. Writers MUST emit canonical
JSON. Unknown object members are an error unless a future version of this
document explicitly makes that object extensible.

## 4. Required schema

The following DDL is exact. A version-1 file MUST contain these tables,
columns, constraints, foreign keys, and indexes. It MUST NOT contain
application rows outside these tables. Additional indexes are allowed;
additional tables, columns, views, triggers, and virtual tables are not.

```sql
CREATE TABLE manifest (
    singleton          INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
    format_name        TEXT NOT NULL CHECK (format_name = 'neoanki-portable-deck'),
    format_version     INTEGER NOT NULL CHECK (format_version = 1),
    created_at         TEXT NOT NULL,
    exporter           TEXT NOT NULL,
    source_library_id  TEXT NOT NULL,
    root_deck_id       TEXT REFERENCES decks(id) ON DELETE RESTRICT,
    content_only       INTEGER NOT NULL CHECK (content_only = 1),
    CHECK (length(source_library_id) = 36),
    CHECK (root_deck_id IS NULL OR length(root_deck_id) = 36)
);

CREATE TABLE decks (
    id          TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    parent_id   TEXT REFERENCES decks(id) ON DELETE RESTRICT,
    ordinal     INTEGER NOT NULL CHECK (ordinal >= 0),
    name        TEXT NOT NULL
);

CREATE TABLE item_types (
    id                 TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    name               TEXT NOT NULL,
    origin_library_id  TEXT NOT NULL CHECK (length(origin_library_id) = 36),
    origin_type_id     TEXT NOT NULL CHECK (length(origin_type_id) = 36),
    schema_digest      BLOB NOT NULL CHECK (length(schema_digest) = 32),
    UNIQUE (origin_library_id, origin_type_id)
);

CREATE TABLE fields (
    id            TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    item_type_id  TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
    ordinal       INTEGER NOT NULL CHECK (ordinal >= 0),
    name          TEXT NOT NULL,
    kind          TEXT NOT NULL CHECK (
        kind IN ('text', 'richText', 'audio', 'image', 'gif', 'video',
                 'number', 'cloze')
    ),
    is_required   INTEGER NOT NULL CHECK (is_required IN (0, 1)),
    UNIQUE (item_type_id, ordinal),
    UNIQUE (item_type_id, id)
);

CREATE TABLE templates (
    id                  TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    item_type_id        TEXT NOT NULL REFERENCES item_types(id) ON DELETE CASCADE,
    ordinal             INTEGER NOT NULL CHECK (ordinal >= 0),
    name                TEXT NOT NULL,
    prompt_json         TEXT NOT NULL,
    answer_json         TEXT NOT NULL,
    interaction         TEXT NOT NULL CHECK (
        interaction IN ('reveal', 'type', 'choose', 'record', 'cloze', 'arrange')
    ),
    skill_json          TEXT NOT NULL,
    generate_when_json  TEXT,
    UNIQUE (item_type_id, ordinal),
    UNIQUE (item_type_id, id)
);

CREATE TABLE items (
    id            TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    item_type_id  TEXT NOT NULL REFERENCES item_types(id) ON DELETE RESTRICT,
    deck_id       TEXT REFERENCES decks(id) ON DELETE RESTRICT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    UNIQUE (id, item_type_id)
);

CREATE TABLE item_fields (
    item_id        TEXT NOT NULL,
    item_type_id   TEXT NOT NULL,
    field_ordinal  INTEGER NOT NULL CHECK (field_ordinal >= 0),
    value_json     TEXT NOT NULL,
    PRIMARY KEY (item_id, field_ordinal),
    FOREIGN KEY (item_id, item_type_id)
        REFERENCES items(id, item_type_id) ON DELETE CASCADE,
    FOREIGN KEY (item_type_id, field_ordinal)
        REFERENCES fields(item_type_id, ordinal) ON DELETE RESTRICT
);

CREATE TABLE item_tags (
    item_id  TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    ordinal  INTEGER NOT NULL CHECK (ordinal >= 0),
    tag      TEXT NOT NULL,
    PRIMARY KEY (item_id, ordinal)
);

CREATE TABLE media_assets (
    digest          BLOB PRIMARY KEY NOT NULL CHECK (length(digest) = 32),
    kind            TEXT NOT NULL CHECK (kind IN ('audio', 'image', 'gif', 'video')),
    mime_type       TEXT NOT NULL,
    file_extension  TEXT NOT NULL,
    byte_size       INTEGER NOT NULL CHECK (byte_size >= 0),
    data            BLOB NOT NULL,
    CHECK (length(data) = byte_size)
);

CREATE UNIQUE INDEX idx_decks_parent_ordinal
    ON decks(COALESCE(parent_id, ''), ordinal);
CREATE INDEX idx_item_types_schema_digest
    ON item_types(schema_digest);
CREATE INDEX idx_fields_item_type_ordinal
    ON fields(item_type_id, ordinal);
CREATE INDEX idx_templates_item_type_ordinal
    ON templates(item_type_id, ordinal);
CREATE INDEX idx_items_item_type
    ON items(item_type_id);
CREATE INDEX idx_items_deck
    ON items(deck_id);
CREATE INDEX idx_item_fields_item_type
    ON item_fields(item_type_id, field_ordinal);
CREATE INDEX idx_item_tags_tag
    ON item_tags(tag);
```

There MUST be exactly one `manifest` row and its `singleton` MUST be `1`.
`manifest.format_version` and `PRAGMA user_version` MUST agree.
`manifest.root_deck_id`, when non-null, MUST identify a row in `decks`.

Ordinals are zero-based, contiguous, and unique within their owner. Deck
ordinals are contiguous among siblings, field and template ordinals are
contiguous within an item type, and tag ordinals are contiguous within an
item. A reader MUST NOT infer order from SQLite row order or UUID values.

Names and tags MUST be non-empty after Unicode whitespace trimming. Field names
MUST be unique after Unicode NFC normalization and locale-independent case
folding within an item type, matching NeoAnki's item-type validation. Sibling
deck names, template names, and tags MAY repeat and are distinguished by their
owner and ordinal. Stored text is not otherwise case-folded or rewritten.

`origin_library_id` and `origin_type_id` form the stable provenance identity of
an item type. A type first exported from a library uses that library's ID and
its local item-type ID. Import and subsequent re-export MUST preserve an
existing origin pair. The transport `item_types.id` is the source library's
current local type ID and is not itself provenance.

## 5. Structured JSON payloads

The schemas below are exhaustive. Literal strings are shown in quotes;
`<...>` denotes a value described in prose, not literal JSON.

### 5.1 Template sides, slots, and conditions

`prompt_json` and `answer_json` are arrays of slots in display order:

```json
[{"source":{"field":0},"presentation":{"media":"default","reveal":"always"}}]
```

A slot is:

```json
{
  "source": <source>,
  "presentation": {
    "reveal": "always" | "hiddenUntilAnswer" | "blurred",
    "media": "default" | "autoplay" | "playOnTap" | "loop"
  }
}
```

A source is exactly one of:

```json
{"field": <zero-based field ordinal>}
{"literal": "<Unicode text>"}
```

The field ordinal MUST exist in the slot's item type. Media behavior other than
`default` is valid only for `audio`, `gif`, or `video` field sources. A literal
source and a non-media field source MUST use `default`.

`generate_when_json` is absent (`NULL`) when no generation condition exists.
Otherwise it is one of:

```json
{"fieldNotEmpty": <field ordinal>}
{"fieldEmpty": <field ordinal>}
{"all": [<condition>, ...]}
{"any": [<condition>, ...]}
```

Condition arrays MUST contain at least one member. Conditions MUST be acyclic,
must not exceed the limits in section 9, and all field ordinals MUST exist.

### 5.2 Skills

`skill_json` is:

```json
{"input":"text","operation":"recall","output":"freeResponse"}
```

`input` and `output` MUST each be one of `text`, `audio`, `image`, `video`,
`diagram`, `none`, `freeResponse`, `selection`, `spatial`, or `sequence`.
`operation` MUST be one of `recognize`, `recall`, `discriminate`, `classify`,
`locate`, `order`, `apply`, `explain`, or `reproduce`.

### 5.3 Item field values

`item_fields.value_json` is exactly one of the following tagged objects:

```json
{"type":"empty"}
{"type":"text","text":"<Unicode text>"}
{"type":"text","text":"<Unicode text>","lang":"<BCP-47 language tag>"}
{"type":"rich","spans":[{"text":"<Unicode text>","styles":["bold","italic"]}]}
{"type":"number","value":12.5}
{"type":"cloze","text":"Paris is in France","blanks":[{"group":1,"start":0,"length":5}]}
{"type":"media","digest":"<64 lowercase hex>","kind":"image","extension":"png"}
```

Text language tags MUST be structurally valid BCP 47 tags. A rich span's
`styles` is a set encoded without duplicates in this fixed order when present:
`bold`, `italic`, `underline`, `strikethrough`, `highlight`, `code`. Empty
style arrays are allowed.

Numbers MUST be finite IEEE-754 binary64 values. Importers MUST reject values
that cannot round-trip through binary64.

A cloze blank has required integer members `group`, `start`, and `length`, and
an optional string `hint`. `group` MUST be positive; `start` and `length` MUST
be non-negative, and `length` MUST be positive. Offsets count Unicode extended
grapheme clusters, not UTF-8 or UTF-16 code units. Each range MUST be inside
`text`; ranges within one group MUST NOT overlap.

A media value may additionally contain optional `durationMs` (a non-negative
integer) and `altText` (a string). Its digest MUST identify a `media_assets`
row. Its `kind` and `extension` MUST exactly match that row. Direct paths,
URLs, bookmarks, and base64 media are forbidden.

The value type MUST agree with its field kind:

- `text` accepts `text` or `empty`;
- `richText` accepts `rich` or `empty`;
- `number` accepts `number` or `empty`;
- `cloze` accepts `cloze` or `empty`; and
- `audio`, `image`, `gif`, and `video` accept matching `media` or `empty`.

Every item MUST have exactly one `item_fields` row for every field ordinal of
its type. Optional missing values are represented by `{"type":"empty"}`.
Required fields MUST contain a non-empty, kind-matching value. Text, rich text,
and cloze values containing only Unicode whitespace are empty for this rule.

## 6. Canonical item-type schema digest

`item_types.schema_digest` is:

```text
SHA-256(UTF8(JCS(canonical-schema-object)))
```

The canonical schema object contains no UUID and has this exact shape:

```json
{
  "fields": [
    {"kind":"text","name":"Front","required":true}
  ],
  "name": "Basic",
  "templates": [
    {
      "answer": [
        {"presentation":{"media":"default","reveal":"always"},"source":{"field":1}}
      ],
      "generateWhen": null,
      "interaction": "reveal",
      "name": "Forward",
      "prompt": [
        {"presentation":{"media":"default","reveal":"always"},"source":{"field":0}}
      ],
      "skill": {"input":"text","operation":"recall","output":"text"}
    }
  ]
}
```

The object is constructed as follows:

1. Normalize the item-type name, field names, template names, literal strings,
   and condition literal strings to Unicode NFC. Do not trim or case-fold them.
2. Emit fields in ascending `fields.ordinal`. Emit only `name`, `kind`, and
   boolean `required`; omit field IDs and ordinals.
3. Emit templates in ascending `templates.ordinal`. Emit `name`, `prompt`,
   `answer`, `interaction`, `skill`, and `generateWhen`; omit template IDs,
   item-type IDs, and ordinals.
4. Emit side slots in stored array order.
5. Replace every field UUID/reference with that field's zero-based ordinal.
6. Encode a missing generation condition as JSON `null` in this digest object,
   even though the table column is SQL `NULL`.
7. Serialize the resulting object using JCS and hash its UTF-8 bytes with
   SHA-256.

The digest therefore depends on semantic names, order, field kinds and
requiredness, template behavior, literals, conditions, and skills. It is
independent of the item type, field, and template UUIDs, SQLite row order,
JSON object member order, and source platform's native `Codable` encoding.

An importer MUST recompute every digest and compare all 32 bytes in constant
time before deduplication. A mismatch makes the file invalid; the stored digest
is never trusted as a lookup key without this check.

## 7. Media

`media_assets.digest` MUST equal SHA-256 over exactly the bytes in `data`.
`byte_size` MUST equal the blob length. Media metadata MUST agree with
validated file signatures; a filename or declared MIME type is not evidence of
content type.

Allowed version-1 combinations are:

- image: `image/jpeg`/`jpg`, `image/png`/`png`, `image/webp`/`webp`;
- gif: `image/gif`/`gif`;
- audio: `audio/mpeg`/`mp3`, `audio/mp4`/`m4a`, `audio/wav`/`wav`,
  `audio/ogg`/`ogg`;
- video: `video/mp4`/`mp4`, `video/quicktime`/`mov`,
  `video/webm`/`webm`.

Extensions are lowercase ASCII without a leading period. Executable or active
content, including HTML, SVG, scripts, and playlist files, is forbidden.
Importers MUST decode or inspect media using hardened platform libraries and
MUST NOT execute it.

Writers MUST include only media referenced by an exported item. Every media
row MUST be referenced at least once; every media reference MUST resolve.
Identical bytes occur once, keyed by digest. Exporters and importers SHOULD use
incremental SQLite blob I/O or equivalently bounded chunks and MUST NOT require
all media bytes to be resident in memory.

## 8. Export and import semantics

### 8.1 Export

An export consists of the selected deck subtree, its items, all item types
needed by those items, and all media reachable from those item values. If no
root deck is selected, `manifest.root_deck_id` is `NULL` and the file may
contain multiple top-level decks and deckless items.

When exporting a subtree, the selected deck becomes a root in the portable
file: its `parent_id` is `NULL`; ancestors and unrelated siblings are omitted.
Descendant relationships and sibling order are preserved. Item, deck,
item-type, field, and template transport IDs are preserved from the source
library. Origin pairs are preserved as specified in section 4.

The exporter MUST take a transactionally consistent snapshot. It MUST generate
canonical JSON, recompute schema and media digests, run
`PRAGMA foreign_key_check`, and run `PRAGMA integrity_check` before publishing
the file.

No table or JSON value may contain card IDs, review logs, due dates, memory
state, scheduler parameters, suspension flags, study statistics, or deletion
tombstones. `content_only` is always `1`; version 1 has no progress-export
option.

### 8.2 Import validation and type resolution

Import is all-or-nothing. Before mutating the destination library, an importer
MUST validate container identity, schema, limits, canonical payload semantics,
foreign keys, UUIDs, timestamps, ordinals, names, media, and all digests.

For each incoming item type, resolve against the destination in this exact
order:

1. **Origin and digest:** if `(origin_library_id, origin_type_id)` exists with
   the same digest, reuse that destination type.
2. **UUID and digest:** otherwise, if a destination type whose local UUID equals
   incoming `item_types.id` exists with the same digest, reuse it.
3. **Canonical digest:** otherwise, if exactly one or more destination types
   have the same recomputed digest, reuse the one with the lexicographically
   smallest lowercase UUID.
4. **Create:** otherwise create a new destination type.

If the destination contains the same origin pair with a different digest, this
is a **schema conflict**. The default import MUST fail without mutation; the
importer MUST NOT silently merge, fork, overwrite, or partially import that
type. After presenting the conflict, an importer MAY retry only with an
explicit user choice to reuse a local type having the exact imported canonical
digest or to create a distinct local revision. Reusing a merely similar type
is forbidden. A same local UUID with a different digest is not an origin
conflict: continue to digest matching and, if needed, create the type under a
fresh UUID.

When creating a type, the importer MUST allocate fresh random UUIDs for the
type, every field, and every template, preserve field/template order, and
rewrite all ordinal references to those new IDs in the destination model. It
MUST preserve the incoming origin pair.

### 8.3 Imported content

The importer MUST allocate fresh random UUIDs for every imported deck and item,
rewrite deck parent and item deck references, and never overwrite destination
content based on transport UUIDs. Names may be disambiguated according to
destination UI policy, but content and relative ordering MUST be preserved.

For each imported item, the importer maps `field_ordinal` to the resolved
destination type's field at that ordinal. It creates cards from the resolved
templates using the normal card generator. Every generated card receives a
fresh random UUID and the destination application's initial, never-reviewed
scheduling state. No scheduling or review data is inferred from timestamps or
transport IDs.

Tags retain their spelling and order. Media is deduplicated by verified SHA-256
digest. Existing destination media with that digest MUST be byte-identical;
otherwise import fails as destination corruption.

Implementations SHOULD parse rows with prepared statements, bind all values
rather than constructing SQL, and insert items in bounded batches inside the
single import transaction. Media MUST be copied in bounded chunks.

## 9. Validation and security limits

An implementation MAY impose lower limits before the user selects a file, but
a conforming version-1 importer MUST reject a file exceeding any of these hard
limits before committing:

- file size: 2 GiB;
- SQLite page size: 512 through 65,536 bytes;
- decks: 10,000;
- item types: 10,000;
- fields per item type: 256;
- templates per item type: 256;
- slots per template side: 512;
- generation-condition nodes per template: 1,024;
- generation-condition nesting depth: 64;
- items: 1,000,000;
- tags per item: 256;
- UTF-8 bytes in a name or tag: 1,024;
- UTF-8 bytes in a literal, text value, rich span, cloze text, hint, or alt text:
  256 KiB;
- rich spans per value: 4,096;
- cloze blanks per value: 4,096;
- bytes in any `_json` value: 1 MiB;
- media rows: 100,000;
- image or GIF asset: 25 MiB;
- audio asset: 20 MiB;
- video asset: 100 MiB; and
- total uncompressed media bytes: 1 GiB.

Counts and sizes MUST be checked with overflow-safe arithmetic. The importer
MUST configure conservative SQLite length, column, expression-depth, and
allocation limits before reading untrusted content. It MUST open the source
read-only, disallow extension loading, ignore source journaling pragmas, never
execute SQL read from the file, and use fixed application-owned queries only.
It SHOULD set a progress handler or equivalent work budget so malformed files
cannot cause unbounded CPU use.

Importers MUST run `PRAGMA quick_check` (or the stronger `integrity_check`) and
`PRAGMA foreign_key_check`; any non-`ok` result is fatal. They MUST reject
symlinks or non-regular files where the platform exposes that distinction.

Validation errors MUST identify the table and stable row identifier or ordinal
when safe to do so, but MUST NOT echo media bytes or arbitrarily large/untrusted
strings into logs or UI.

## 10. Atomicity, cleanup, and errors

### 10.1 Export atomicity

Writers MUST build a new database at a temporary path on the same filesystem as
the final destination. They MUST use a SQLite transaction, finish all
validation, close the database, durably flush it where supported, and then
atomically replace or rename it to the requested `.neodeck` path. On failure,
the old destination file MUST remain unchanged and the temporary file MUST be
removed. A partially written file MUST never be presented as a successful
export.

### 10.2 Import atomicity

All destination database changes MUST occur in one transaction. Media bytes
MUST first be staged in destination-controlled temporary storage and verified
there. The importer MUST then use the destination media store's reservation or
equivalent crash-safe adoption protocol so media publication and reference
updates cannot leave committed dangling references.

On any validation, schema-resolution, media, card-generation, cancellation,
SQLite, or I/O error, the importer MUST roll back the destination transaction,
release reservations, remove newly staged files, and report failure. Existing
deduplicated media MUST never be deleted during rollback. No deck, item, item
type, card, tag, progress record, or media reference from the failed operation
may remain committed.

If a process crash leaves unreferenced staged media, normal orphan collection
MAY remove it after verifying that it is inside the managed media directory and
has no committed references.

### 10.3 Error classes

Implementations SHOULD distinguish at least:

- unsupported format or version;
- corrupt SQLite container;
- schema mismatch;
- limit exceeded;
- invalid canonical payload;
- schema digest mismatch;
- schema conflict;
- invalid or mismatched media;
- destination corruption;
- insufficient space or I/O failure; and
- user cancellation.

Errors are terminal for the current file. Version 1 has no best-effort,
skip-invalid-row, or partial-import mode.

## 11. Compatibility rules

A version-1 reader MUST validate exact table and column names and MUST tolerate
additional indexes only. It MUST reject missing or additional application
schema objects because those can change semantics or expand the attack surface.

Format evolution uses `PRAGMA user_version` and `manifest.format_version`
together. A future incompatible schema increments both. Version-1 writers MUST
not emit extensions under version 1, and readers MUST not infer support from
the `.neodeck` filename alone.

Cross-platform implementations MUST derive behavior from this specification,
not Swift `Codable` case encoding, Foundation dictionary order, host endianness,
filesystem paths, locale-sensitive sorting, or SQLite's incidental row order.
