---
title: Import and export
description: Choose JSON, CSV, portable decks, or authored decks and recover safely from validation and conflict errors.
nav_order: 7
parent: User Guide
---

# Import and export

NeoAnki2 has four native ways to bring in content:

- A bundled deck builder turns guided input into an authored deck.
- JSON and CSV add rows to an item type already in your library.
- `.neoanki` is an editable, import-only authored deck bundle.
- `.neodeck` is a portable, content-only deck file that NeoAnki2 can import and export.

Anki `.apkg` and `.colpkg` packages, shared-deck imports, HTML/CSS cards, and
Anki template markup are not supported.

<nav class="local-toc" aria-label="On this page" markdown="1">
**On this page**

- [Build a poem deck](#build-a-poem-deck)
- [Import and use a vocabulary pack](#import-and-use-a-vocabulary-pack)
- [Import JSON or CSV](#import-json-or-csv)
- [Export a portable deck](#export-a-portable-deck)
- [Import `.neodeck` or `.neoanki`](#import-neodeck-or-neoanki)
- [Choose the right format](#choosing-the-right-format)
</nav>

## Build a poem deck

Choose **File → Build Deck…** to open the deck-builder catalog, then select
**Poem Deck**. Enter the author, title, and poem text, then choose **Add to
Library**. Other bundled builders can appear alongside it in future releases.

Choose an existing root deck for the poem. NeoAnki2 creates the poem as its
child and stores the entered author as an `author:<name>` tag on each generated
item. Every nonblank line after the first becomes one Basic card answer. Its
prompt contains the preceding one or two lines, matching a moving recitation
window. For example, a 12-line poem creates 11 cards. Generated cards retain the
poem's line order in both Browse and their initial Study queue.

The builder first writes a temporary `.neoanki` bundle, validates the complete
bundle with the same rules as an imported authored deck, imports it atomically,
and removes the temporary files. It does not write directly to the library.

## Import and use a vocabulary pack

Choose **File → Import Vocabulary Pack…** and select a local `.neovocab`
directory. NeoAnki validates it and copies it into the library's managed
Vocabulary Packs directory. The source can then be moved or deleted. Use
**Library → Vocabulary Packs…** to see the packs installed in this library.

Select the deck that should receive the cards, then choose **File → Add from
Vocabulary…** or use **Add from Vocabulary** in the deck toolbar. Choose an
installed pack, search its local index, review the forms, pronunciations,
meanings, examples, and card paradigms, then choose **Add Cards**. The generated
items are validated and appended atomically to the selected deck; no new deck is
created. The window stays open so another word can be added immediately.

Both operations are offline-only. Import reads and copies the selected local
package; lookup reads only the installed SQLite index and local media.

## Import JSON or CSV

Choose **File → Import…**, select one `.json` or `.csv` file, review the import
sheet, and choose **Import**. Import is unavailable while studying, adding an
item, managing item types, showing another import sheet, or while a deck
transfer is active. It is also disabled while the library is loading or no item
types exist. An item edit sheet does not disable the menu. Deck import/export
waits for item and deck loading but can supply its own item types.

[![JSON import sheet showing the selected file and duplicate warning]({{ site.baseurl }}/assets/screenshots/import-sheet.png)]({{ site.baseurl }}/assets/screenshots/import-sheet.png)

### JSON

JSON names its item type in the file, so that item type must already exist.
Field keys must exactly match fields in that type. A minimal file is:

```json
{
  "itemType": "Basic",
  "rows": [
    {
      "Front": "What is active recall?",
      "Back": "Trying to retrieve an answer before seeing it.",
      "tags": ["learning", "memory"]
    }
  ]
}
```

JSON supports plain strings and structured values, including cloze data and
media. A relative media value uses a `path`:

```json
{
  "itemType": "Image Notes",
  "rows": [
    {
      "Image": { "path": "cover.png" },
      "Caption": "Cell structure"
    }
  ]
}
```

When NeoAnki2 detects a relative media path, the sheet requires **Choose Media
Folder…**. Choose the folder relative to which every path in the JSON resolves.
For the example above, choose the folder containing `cover.png`. The **Import**
button stays disabled until a valid folder is selected. NeoAnki2 copies
validated media into its managed media store; it does not keep a live link to
the source file.

JSON may also contain base64 media with optional `fileExtension` and `altText`,
but a media folder is simpler for authored files. Media kind, signature, size,
and path confinement are validated before any row is saved.

Structured values use these complete shapes:

```json
{
  "Cloze": {
    "text": "Paris is in France.",
    "blanks": [{ "group": 1, "start": 12, "length": 6, "hint": "country" }]
  },
  "Image": {
    "base64": "<base64 bytes>",
    "fileExtension": "png",
    "altText": "Map highlighting France"
  }
}
```

The importer currently accepts Image/GIF media without `altText`, unlike the
item editor. Treat that as an accessibility limitation: include a meaningful
description in authored/imported content whenever the image carries
information.

### CSV

CSV requires a header row and at least one data row. Choose the destination
**Item Type** in the import sheet. Header names must be unique and must match
fields in that item type:

```csv
Front,Back,tags
What is retrieval practice?,Practice recalling information,"learning,memory"
```

The special lowercase `tags` column is split on commas. Quote a field to include
commas or line breaks, and represent a quote inside a quoted field as `""`.
Every row must have the same number of columns as the header.

CSV imports text values only. It does not represent structured cloze spans or
media objects; use JSON or `.neoanki` for those.

### Limits, validation, and duplicates

JSON and CSV files are limited to 5 MB, 10,000 rows, 256 fields per row, and
32,768 UTF-8 bytes per field value. Files must be regular files; CSV must be
UTF-8. Unknown fields, missing required values, missing item types, malformed
rows, invalid media, and empty payloads stop the import.

The operation is all-or-nothing: a failed import leaves the existing library
unchanged. Every successful row is always added as a new item. NeoAnki2 does
not search for matching content, so importing the same file twice creates
duplicates and new due cards. JSON and CSV rows are placed in **Unassigned**.
There is currently no bulk move, search, or duplicate-cleanup action; organize
or remove imported items one at a time, and test large imports with a small
sample first.

## Export a portable deck

Select a real deck in the sidebar, then choose **File → Export Deck…**. Choose
a destination; NeoAnki2 adds the `.neodeck` extension when needed. Export is
disabled for **All Decks** and **Unassigned**, and while another modal workflow
or transfer is active.

The file contains the selected deck and its subdecks, items, tags, required item
types and templates, and referenced media. The selected deck becomes the root
of the exported tree. Unrelated library items are not loaded into the export snapshot.

`.neodeck` version 4 is deliberately **content-only**. It does not contain:

- review history, due dates, or scheduler parameters;
- card or memory state, suspension state, or study statistics; or
- deletion history.

On import, NeoAnki2 generates fresh cards in never-reviewed state. A
`.neodeck` is therefore suitable for sharing or moving content, but not for
backing up learner progress. Back up the complete library folder for that.

Because imported cards carry no history, importing a deck contributes nothing to
scheduler fitting until you have actually reviewed those cards. See
[Scheduling](../scheduling/#when-a-fit-is-attempted).

## Import `.neodeck` or `.neoanki`

Choose **File → Import Deck…**, then select either format.

### Portable `.neodeck`

NeoAnki2 validates the entire portable database—including its format version,
schema, limits, item-type digests, and media—before changing the library.
Imported decks, items, and cards receive fresh local identifiers. Media and
exactly matching item-type schemas are reused when safe. Re-importing a
portable deck creates another copy of its content.

Version-3 packages preserve the ordered item types offered by each deck.
Newly introduced schemas stay under **From Decks** beneath their owning deck;
an exact match
that is already a normal Item Type remains normal. Older version-1 and
version-2 packages keep their previous behavior and add their types to the
normal Item Types list.

If an incoming item type has the same origin as a local type but a different
schema, no content is imported until you choose:

- **Use Matching Local Type** — reuse a local type only if its complete
  canonical schema exactly matches the incoming schema.
- **Import as New Type** — keep both revisions by creating a distinct local
  item type.
- **Cancel** — make no changes.

[![Item type conflict choices during portable deck import]({{ site.baseurl }}/assets/screenshots/portable-conflict.png)]({{ site.baseurl }}/assets/screenshots/portable-conflict.png)

Portable imports are atomic. An unsupported version, malformed package,
conflict left unresolved, media error, size limit, disk error, or cancellation
does not leave a partial deck behind.

### Authored `.neoanki`

A `.neoanki` source is a directory bundle whose name ends in `.neoanki`. It has
this shape:

```text
Biology.neoanki/
  deck.jsonl
  items/
    cells.jsonl
  media/
    cell.webp
```

It is editable, text-based, and import-only. It can declare its own deck tree,
item types, templates, items, tags, and local media. Import allocates fresh
local identifiers and never-reviewed cards. An unchanged item-type schema may
reuse an exact local match; changing the schema creates a distinct type.
Re-importing creates duplicate content.

Authored format version 3 and later require the root to declare its ordered
`itemTypes`, supports inherited descendant policies and optional
`defaultType`, and keeps every declared type included with the imported root.
Version-1 and version-2 bundles remain compatible and import their types as
normal Item Types without contextual policy metadata.

Paths must remain inside the bundle. Remote URLs, absolute paths, `..`,
symlinks, executable includes, HTML/SVG, and embedded base64 media are not
accepted by this format. Validate a bundle before import with the
[`neoanki-deck` command](../cli/).

## Choosing the right format

- Use **CSV** for simple text rows targeting one existing item type.
- Use **JSON** for rows targeting one existing item type, especially structured
  cloze or media fields.
- Use **`.neoanki`** for editable, reviewable source that defines a whole deck.
- Use **`.neodeck`** to exchange a complete native deck with its schemas and
  media, understanding that learner progress is excluded.
