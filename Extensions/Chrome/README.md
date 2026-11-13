# NeoAnki2 Companion

A small, local Chrome extension: highlight text, review an editable dictionary
suggestion, and save a Basic card to NeoAnki2. No build step or runtime packages.

## Install locally

1. Keep this checkout at a stable location; Chrome loads these files directly.
2. In Chrome, enter `chrome://extensions`, enable **Developer mode**, and choose
   **Load unpacked**. Select this `Extensions/Chrome` directory.
3. Pin **NeoAnki2 Companion** from Chrome's Extensions menu.
4. Keep NeoAnki2 running. In **Settings → Local API**, enable the local automation
   API. Its default port is `8766`.
5. Open the extension's **Settings**, choose **Connect**, and approve
   **NeoAnki2 Chrome Companion** in NeoAnki2. Leave the settings tab open until
   it reports that it is connected.
6. Choose an installed vocabulary pack for suggestions, or choose **None** to
   enter answers yourself.

This is an unpacked local extension, not a Chrome Web Store installation. After
updating these files, reload the extension on `chrome://extensions`. Moving the
directory may change its extension identity and require pairing again.

## Add a card

Select a word or phrase on a page and click the toolbar icon. Front contains the
selection; Back receives a suggestion only when your dictionary has one exact
match. Otherwise, choose a suggestion or type an answer. Choose an existing deck
(or Unassigned), then **Save card**. The page title and link are appended to Back.

Your last deck and unfinished draft are remembered. **Use selection** discards
the current draft and captures the current selection again. An interrupted or uncertain
save preserves the exact request: **Retry save** checks the same save rather than
creating another card. A definite rejection keeps your text editable once the
extension confirms that no item was created. After reconnecting or switching ports, inspect NeoAnki2
before discarding any unresolved save.

Text in YouTube's selectable transcript works like other page text. This version
does not fetch subtitles, capture video overlays, generate answers with AI, or
download media. Restricted Chrome pages allow manual card entry instead.

Cards use the existing Basic item type. It must have text fields named Front and
Back and an unconditional reveal card using those fields. Repair this setup in
NeoAnki2 if the extension reports that Basic is incompatible; create a type named
Basic with that setup if it was deleted. No item types,
decks, or dictionaries are created by the extension.

## Privacy and access

Permissions are `activeTab`, `scripting`, `storage`, and HTTP access to
`127.0.0.1` only. The extension reads the active page's selection after you invoke
it; it does not scan browsing history or run continuously on every page. Pairing
requests only `library.read`, `items.write`, and `vocabulary.read`.

Drafts and the API token are saved locally in Chrome, outside Chrome sync, with
storage restricted to trusted extension contexts. Dictionary queries and card
saves use NeoAnki2's loopback API. Saved cards follow NeoAnki2's sync settings.
Disconnect in extension Settings or revoke the client in NeoAnki2's Local API
settings. Disconnect needs NeoAnki2 to be reachable so access can be revoked.

## Headless development checks

From this directory, with Node.js 22 or newer and the repository's Swift toolchain:

```sh
npm ci
npm test
npx playwright install chromium --no-shell
npm run test:integration
```

Only tests need npm packages. Integration tests build `neoanki-chrome-fixture`,
load the unmodified extension in headless Chrome for Testing, and exercise the
toolbar action through the browser's Extensions DevTools protocol. Capture is
observed in the actual action popup's persisted draft. Since Playwright does not
expose that popup as a controllable page, form interactions use the same production
popup document in a constrained 380 × 600 headless tab. The tests use a
temporary profile, SQLite library, vocabulary pack, and loopback ports. They
never open the installed NeoAnki2 app or the user's Chrome profile.

The fixture's automatic approval is test-only and requires `--test-fixture` and
an empty `neoanki-chrome-*` directory. It exits when its parent's stdin closes.
Tests clean up the fixture and profile even on failure; popup screenshots remain
in the ignored `test-results/` directory. Actual Chrome loading, pinning, and
human approval in the installed NeoAnki2 app remain manual acceptance steps.
