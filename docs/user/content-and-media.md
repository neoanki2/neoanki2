---
title: Content and media
description: Author text, numbers, cloze blanks, images, GIFs, audio, and video in formats NeoAnki2 validates.
nav_order: 4
parent: User Guide
---

# Content and media

An item type can define Text, Rich Text, Number, Cloze, Image, GIF, Audio, and
Video fields. The field type controls authoring, validation, storage, and
native rendering.

## Text

Enter one or more lines in the field editor. Empty or whitespace-only content
does not satisfy a required field. Text is stored as native content rather
than HTML, and may carry language metadata when it came from an import.

The Text editor exposes the same semantic formatting controls as Rich Text.
Unformatted input remains plain text; applying a style preserves it as rich
spans.

## Rich text

Select text and use the formatting toolbar:

- **Bold**
- **Italic**
- **Underline**
- **Strikethrough**
- **Highlight**
- **Code**

Clicking an active style removes it. Highlight and Code are mutually exclusive
when applied through the toolbar. Styles are stored semantically and rendered
with native macOS typography; arbitrary fonts, colors, HTML, CSS, and embedded
web content are not supported.

## Numbers

Enter a value Swift can parse as a `Double`, such as `42`, `-3.5`, or `1e6`.
NeoAnki2 stores the numeric value, not its original spelling, and formats it
for the current locale when displaying it. Non-numeric text cannot satisfy a
required Number field.

Use a Text field instead when leading zeroes or exact source formatting are
meaningful.

## Cloze blanks

A Cloze field stores text plus explicit blank ranges; do not type Anki
{% raw %}`{{c1::...}}`{% endraw %} markup.

1. Enter the complete sentence or passage.
2. Select the text to hide.
3. In **Add to**, keep **New group** or choose an existing group.
4. Choose **Mark Blank**.
5. Optionally add a Hint or change the blank's group.

If no text is selected, **Mark Blank** uses the last word. Blanks in the same
group are concealed and tested together; each distinct group can generate its
own cloze card. Use the minus button to remove one blank or **Clear Blanks** to
remove all of them.

NeoAnki2 adjusts blank positions as text is edited. If an edit crosses a
blank's boundary, that blank is removed and the editor asks you to mark it
again. Overlapping or otherwise invalid ranges are rejected. A required Cloze
field must have both non-empty text and at least one blank.

## Attach media

Media fields accept one file each.

1. Drag a file from Finder onto the dashed drop area, or choose **Choose
   File…**.
2. Wait for the preview or filename to appear.
3. Enter a description when required.
4. Save the item.

[![Media attached to an item]({{ site.baseurl }}/assets/screenshots/item-media.png)]({{ site.baseurl }}/assets/screenshots/item-media.png)

**Remove** clears the attachment and its description from the field. Choosing
another file replaces the current attachment.

The system file chooser offers these formats:

- **Audio:** M4A, MP3, WAV, AAC, and CAF
- **Image:** PNG, JPEG, HEIC, TIFF, and WebP
- **GIF:** GIF
- **Video:** MP4, M4V, and QuickTime MOV

Dropped, chosen, and imported media are checked against supported extensions
and file signatures; renaming an unsupported file does not make it valid.

Size limits are:

- Audio: 20 MB
- Image: 10 MB
- GIF: 15 MB
- Video: 100 MB

Only regular local files are accepted. A format mismatch, unreadable file, or
oversized file leaves the field unsaved and shows an error.

## Write useful descriptions

An attached Image or GIF requires a short, non-whitespace **Image description
(required)**. Save stays disabled without it. The description supplies the
VoiceOver label and may also represent the media in item-list text.

Audio and Video descriptions are optional, but adding one gives the player a
meaningful accessibility label and displays context alongside playback. A
description belongs to the item field's media reference; editing it does not
rename the source file.

## Understand media storage

When a file is accepted, NeoAnki2 copies its bytes into:

```text
~/Library/Application Support/neoanki2/media/
```

Files are stored under content-derived names and referenced by the library
database. The original Finder file can be moved or removed after attachment.
Do not rename or edit files inside the app-managed media directory. Back up
that directory together with `neoanki2.sqlite`.

Identical bytes can share one stored asset. When an item is deleted or an
attachment is replaced, an asset is removed only after nothing in the library
references it.

## Preview and study media

The authoring form previews images and GIFs. Its compact preview represents
audio and video with their media label. Item detail resolves the saved content
in the native reading preview.

During study, templates decide whether media is always shown, hidden until the
answer, blurred, played on tap, autoplayed, or looped:

- Images scale to the reading column and can be hidden or blurred.
- GIFs can remain still, play on tap, autoplay, or loop.
- Audio uses native playback controls or a Play Audio button.
- Video uses the native video player.

Autoplay and GIF animation are suppressed when macOS Reduce Motion is enabled.
These behaviors come from the item type's template; they are not selected in
the item editor.

## Current compatibility limits

Media and rich text are native structured values. NeoAnki2 does not execute
HTML/CSS, import Anki `.apkg` packages, or translate Anki cloze markup. Use the
supported NeoAnki2 fields and import formats instead.
