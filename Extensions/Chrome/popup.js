import { allPages, applyAutofill, basicFields, DictionaryLookup, emptyDraft, makeAPI, readSelection, renderEntry, safeSource, saveDraft } from './core.js';
import { readState, writeState } from './storage.js';

const $ = id => document.getElementById(id);
let config, draft, fields, api, lookup, packId;
let busy = true;
let connected = false;
let storageFailed = false;
const persist = () => writeState({ draft, lastDeck: draft.deckId });

function status(message, error = false) {
  $('status').textContent = message;
  $('status').classList.toggle('error', error);
}

function controls() {
  $('fields').disabled = busy || Boolean(draft?.pending);
  $('save').disabled = busy || storageFailed || !connected || (!fields && !draft?.pending);
  $('save').textContent = busy ? 'Please wait…' : draft?.pending ? 'Retry save' : 'Save card';
  $('discard').disabled = busy;
}

function showDraft() {
  $('front').value = draft.front;
  $('back').value = draft.back;
  $('deck').value = draft.deckId;
  $('source').textContent = draft.source ? `Source: ${draft.source.title} · ${new URL(draft.source.url).hostname}` : '';
  controls();
}

function persistEdit() {
  persist().catch(() => {
    storageFailed = true;
    status('Your draft could not be stored. Free Chrome storage and reopen the extension before saving.', true);
    controls();
  });
}

function publishLookup(result) {
  if (draft.pending || busy) return;
  $('lookup-status').textContent = result.message;
  $('suggestions').replaceChildren();
  const applied = result.automaticText && applyAutofill(draft, result.automaticText);
  if (applied) {
    $('back').value = draft.back;
    persistEdit();
  }
  if (applied) return;
  for (const entry of result.entries) {
    const text = renderEntry(entry);
    const button = document.createElement('button');
    button.type = 'button';
    const definition = entry.senses.flatMap(sense => sense.definitions.map(value => value.text.value))[0];
    button.textContent = `${entry.canonicalForm.text.value}${definition ? ` — ${definition}` : ''}`;
    button.addEventListener('click', () => {
      if (!applyAutofill(draft, text)) {
        $('lookup-status').textContent = 'Your answer has edits. Clear it first to use a suggestion.';
        return;
      }
      $('back').value = draft.back;
      persistEdit();
    });
    $('suggestions').append(button);
  }
}

async function capture() {
  let selected = null;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab?.id) {
      const results = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readSelection });
      selected = results[0]?.result;
    }
  } catch { /* Restricted pages still allow manual entry. */ }
  draft = emptyDraft(draft?.deckId);
  draft.front = (selected?.text || '').slice(0, 10000);
  draft.source = safeSource(selected || {});
  await persist();
  showDraft();
  status(selected?.text?.length > 10000 ? 'Selection shortened to 10,000 characters. Review the front before saving.'
    : draft.front ? '' : 'Select text on a page, or type a front and answer here.');
  lookup?.search(draft.front, packId);
}

$('settings').addEventListener('click', () => chrome.runtime.openOptionsPage());
$('front').addEventListener('input', () => {
  // A previous suggestion can change with the query; a manually edited answer cannot.
  if (draft.lastAuto !== null && draft.back === draft.lastAuto) draft.back = '';
  draft.lastAuto = null;
  draft.front = $('front').value;
  $('back').value = draft.back;
  persistEdit();
  lookup?.search(draft.front, packId);
});
$('back').addEventListener('input', () => {
  draft.back = $('back').value;
  persistEdit();
});
$('deck').addEventListener('change', () => {
  draft.deckId = $('deck').value;
  persistEdit();
});
$('discard').addEventListener('click', async () => {
  if ((draft.front || draft.back || draft.pending) && !confirm(draft.pending
    ? 'The previous save may already have succeeded. Check NeoAnki2 before discarding this draft. Discard it?'
    : 'Discard this draft and use the current selection?')) return;
  lookup?.cancel();
  await capture().catch(error => status(error.message, true));
});
$('card-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (busy || !connected || storageFailed) return;
  busy = true;
  lookup?.cancel();
  $('suggestions').replaceChildren();
  $('lookup-status').textContent = '';
  controls();
  try {
    const saved = await saveDraft(draft, fields, config, persist, api);
    if (!saved.cardIds?.length) throw new Error('NeoAnki2 saved the item without a study card. Check the Basic card setup in NeoAnki2.');
    draft = { ...emptyDraft(draft.deckId), source: draft.source };
    await persist();
    showDraft();
    status('Card saved to NeoAnki2.');
  } catch (error) {
    status(`${error.message}${draft.pending ? ' Your draft is kept. Retry to check the same save.' : ''}`, true);
  } finally {
    busy = false;
    controls();
  }
});

async function init() {
  const state = await readState();
  config = state.config;
  draft = state.draft || emptyDraft(state.lastDeck);
  draft.source = safeSource(draft.source || {});
  showDraft();
  if (!draft.front && !draft.back && !draft.pending) await capture();
  if (!config.token) {
    status('Open Settings to connect to NeoAnki2.');
    return;
  }
  api = makeAPI(config);
  // Read the library independently of dictionary availability.
  const [decks, types] = await Promise.all([allPages(api, '/v1/decks'), allPages(api, '/v1/item-types')]);
  connected = true;
  for (const deck of decks.sort((a, b) => a.name.localeCompare(b.name))) {
    const parents = new Map(decks.map(value => [value.id, value]));
    const names = [deck.name];
    let parent = parents.get(deck.parentId);
    const seen = new Set([deck.id]);
    while (parent && !seen.has(parent.id)) {
      seen.add(parent.id); names.unshift(parent.name); parent = parents.get(parent.parentId);
    }
    $('deck').add(new Option(names.join(' / '), deck.id));
  }
  if (draft.deckId && !decks.some(deck => deck.id === draft.deckId)) {
    if (draft.pending) $('deck').add(new Option('Previously selected deck', draft.deckId));
    else { draft.deckId = ''; await persist(); }
  }
  fields = basicFields(types);
  showDraft();
  status(draft.pending ? 'A previous save needs confirmation. Retry save to finish it safely.' : '');
  try {
    const { data: packs } = await api('/v1/vocabulary-packs');
    packs.sort((a, b) => a.title.localeCompare(b.title));
    const pack = config.packId === '' ? null : packs.find(value => value.id === config.packId) || packs[0];
    packId = pack?.id;
    if (config.packId !== (packId || '')) {
      config.packId = packId || '';
      await writeState({ config });
    }
    $('dictionary-name').textContent = pack?.title || '';
    lookup = new DictionaryLookup(api, publishLookup);
  } catch (error) {
    $('lookup-status').textContent = `Dictionary unavailable. ${error.message} You can type an answer.`;
  }
}

init().catch(error => status(error.message, true)).finally(() => {
  busy = false;
  controls();
  if (!draft?.pending) lookup?.search(draft.front, packId);
});
