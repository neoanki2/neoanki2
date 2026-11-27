import './reading-model.js';
import { allPages, APIError, hasCapabilities, isUkrainianDefinition, makeAPI, postJudgmentBatches, READING_CAPABILITIES, requireCapabilities, safeSource,
  undoJudgmentBatches } from './core.js';
import { readState, storageReady, writeState } from './storage.js';

const model = globalThis.NeoAnkiReadingModel;
const recordable = ['known', 'unfamiliar', 'ignored', 'reviewHistory'];
const snapshots = new Map();
const resolvedForms = new Map();
const keyFor = tabId => `reading-mode:${tabId}`;
const deckKeyFor = language => `card-set-deck:${language}`;
const languageCode = value => String(value || '').trim().toLowerCase().replaceAll('_', '-');
function originOf(url) {
  try {
    const parsed = new URL(url);
    return ['http:', 'https:'].includes(parsed.protocol) ? parsed.origin : null;
  } catch { return null; }
}

async function modeFor(tabId) {
  const key = keyFor(tabId);
  return (await chrome.storage.session.get(key))[key];
}

async function inject(tabId, mode) {
  const target = { tabId };
  await chrome.scripting.insertCSS({ target, files: ['reading.css'] });
  await chrome.scripting.executeScript({ target, files: ['reading-model.js', 'reading-page.js'] });
  await chrome.tabs.sendMessage(tabId, { type: 'neoankiReadingStart', mode }, { frameId: 0 });
}

async function stop(tabId) {
  await chrome.storage.session.remove(keyFor(tabId));
  await Promise.allSettled([
    chrome.tabs.sendMessage(tabId, { type: 'neoankiReadingStop' }, { frameId: 0 }),
    chrome.scripting.removeCSS({ target: { tabId }, files: ['reading.css'] }),
  ]);
}

// One request per refresh: the app answers `unchanged` while the cached version is current.
// If NeoAnki2 is unreachable, Reading Mode keeps showing the saved snapshot, read-only.
async function snapshotFor(mode, since) {
  const state = await readState();
  const key = `known-words-snapshot:${mode.language}`;
  await storageReady;
  let snapshot = snapshots.get(key) || (await chrome.storage.local.get(key))[key];
  let offline = false;
  try {
    const query = new URLSearchParams({ language: mode.language, ...(snapshot ? { since: snapshot.version } : {}) });
    const fresh = await makeAPI(state.config)(`/v1/known-words/snapshot?${query}`);
    if (!fresh.unchanged || !snapshot) {
      snapshot = { version: fresh.version, language: mode.language, expressions: fresh.expressions || {}, lemmas: fresh.lemmas || {} };
      await writeState({ [key]: snapshot }).catch(() => {});
    }
  } catch (error) {
    if (error instanceof APIError || !snapshot) throw error;
    offline = true;
  }
  snapshots.set(key, snapshot);
  const result = { version: snapshot.version, offline, dictionary: Boolean(state.config.packId) };
  return since && since === snapshot.version ? { ...result, unchanged: true } : { ...result, snapshot };
}

async function details(message, mode) {
  const { config } = await readState();
  const query = new URLSearchParams({ language: mode.language, expression: String(message.expression || '') });
  return allPages(makeAPI(config), `/v1/known-words?${query}`);
}

// Dictionary forms of words the snapshot doesn't list, cached for this pack and language.
async function dictionaryForms(message, mode) {
  const { config } = await readState();
  if (!config.packId || !(await hasCapabilities(config, ['vocabulary.dictionary-forms']))) return {};
  const cacheKey = `${config.packId}\u001f${mode.language}`;
  const cache = resolvedForms.get(cacheKey) || new Map();
  if (cache.size > 50000) cache.clear();
  resolvedForms.set(cacheKey, cache);
  const words = [...new Set(message.words)].filter(word => typeof word === 'string' && word
    && new TextEncoder().encode(word).length <= 256).slice(0, 20000);
  const api = makeAPI(config);
  for (const chunk of model.chunks(words.filter(word => !cache.has(word)), 2000)) {
    const { data } = await api(`/v1/vocabulary-packs/${encodeURIComponent(config.packId)}/dictionary-forms`,
      { method: 'POST', body: { language: mode.language, words: chunk } });
    for (const word of chunk) cache.set(word, model.formsIn(data, word));
  }
  return Object.fromEntries(words.map(word => [word, cache.get(word)]));
}

const termFor = (term, mode) => ({ language: mode.language, expression: String(term?.expression || ''),
  ...(term?.lemma ? { lemma: String(term.lemma) } : {}) });

function definitionsFor(entries, mode) {
  const meanings = new Map();
  const meaningLanguage = model.primaryLanguage(mode.meaningLanguage);
  for (const entry of entries) {
    for (const sense of entry.senses || []) {
      const definitions = (sense.definitions || []).filter(definition => {
        const language = model.primaryLanguage(definition.text.language) || meaningLanguage;
        return language !== 'uk' || isUkrainianDefinition(definition.text.value);
      });
      const gloss = definitions.find(definition => model.primaryLanguage(definition.text.language) === meaningLanguage)
        || definitions.find(definition => !definition.text.language);
      const meaning = gloss?.text?.value?.trim();
      if (!meaning || meanings.has(meaning)) continue;
      const examples = (sense.examples || []).filter(value => value.target?.exactText &&
        (!value.text.language || model.primaryLanguage(value.text.language) === model.primaryLanguage(mode.language)))
        .map(value => ({
          sentence: value.text.value,
          form: value.target.exactText,
          source: [value.provenance?.sourceName || value.provenance?.sourceID,
            value.provenance?.attribution, value.provenance?.sourceURL].filter(Boolean).join(' · '),
        }));
      meanings.set(meaning, { meaning, language: languageCode(gloss.text.language) || mode.meaningLanguage,
        examples });
    }
  }
  return [...meanings.values()];
}

const ukrainianReference = /^(?:Те саме, що|Див\.)\s+([\p{L}\p{M}'’ʼ-]+)\.?$/iu;

async function lookUpMeanings(api, packId, expression, mode) {
  async function search(word) {
    const query = new URLSearchParams({ query: word, mode: 'exact', language: mode.language, limit: '20' });
    const { data } = await api(`/v1/vocabulary-packs/${encodeURIComponent(packId)}/entries?${query}`);
    return data;
  }

  const entries = await search(expression);
  const meanings = (await Promise.all(definitionsFor(entries, mode).map(async gloss => {
    const reference = model.primaryLanguage(gloss.language) === 'uk' && ukrainianReference.exec(gloss.meaning)?.[1];
    if (!reference) return gloss;
    // Follow one dictionary cross-reference and keep the original entry's example for the card.
    const referred = await search(model.withoutStress(reference, mode.language)).catch(() => []);
    const definition = definitionsFor(referred, mode).find(value => !ukrainianReference.test(value.meaning));
    return definition ? { ...gloss, meaning: `${reference} — ${definition.meaning.replace(/^\)\.\s+/u, '')}` } : null;
  }))).filter(Boolean);
  return { meanings, lemma: model.lemmaFromEntries(entries, mode.language) };
}

async function readingDictionary(api, selectedPack, expression, mode) {
  const empty = { meanings: [] };
  if (!selectedPack) return empty;
  const lookup = packId => lookUpMeanings(api, packId, expression, mode).catch(() => empty);
  const selected = await lookup(selectedPack);
  if (selected.meanings.length) return selected;

  const { data: packs } = await api('/v1/vocabulary-packs').catch(() => ({ data: [] }));
  const language = model.primaryLanguage(mode.language);
  for (const pack of packs) {
    if (pack.id === selectedPack || !pack.languages.some(code => model.primaryLanguage(code) === language)) continue;
    const fallback = await lookup(pack.id);
    if (fallback.meanings.length) return fallback;
  }
  return selected;
}

async function captureOptions(message, mode) {
  const { config } = await readState();
  const api = makeAPI(config);
  const expression = String(message.expression || '');
  const lookup = word => readingDictionary(api, config.packId, word, mode);
  const [decks, local] = await Promise.all([allPages(api, '/v1/decks'), lookup(expression)]);
  const deckKey = deckKeyFor(mode.language);
  const { [deckKey]: lastDeck = '' } = await chrome.storage.local.get(deckKey);
  return { decks, lastDeck, ...local };
}

async function handle(message, sender) {
  if (!message?.type?.startsWith('neoankiReading')) return null;
  const popup = sender.url === chrome.runtime.getURL('popup.html');
  const tabId = popup ? message.tabId : sender.tab?.id;
  if (!Number.isInteger(tabId) || (!popup && sender.frameId !== 0)) throw new Error('Reading Mode is available in the current tab.');
  const mode = await modeFor(tabId);
  if (popup) {
    if (message.type === 'neoankiReadingStatus') return mode ?? null;
    if (message.type === 'neoankiReadingStop') { await stop(tabId); return null; }
    if (message.type !== 'neoankiReadingStart') throw new Error('Choose Start Reading Mode.');
    const tab = await chrome.tabs.get(tabId);
    const origin = originOf(tab.url);
    if (!origin) throw new Error('Reading Mode works on ordinary web pages.');
    const next = { origin, language: languageCode(message.language), meaningLanguage: languageCode(message.meaningLanguage) };
    if (!next.language || !next.meaningLanguage) throw new Error('Choose the learning and meaning languages.');
    await requireCapabilities((await readState()).config, READING_CAPABILITIES, 'Update NeoAnki2 to use this version of Reading Mode.');
    await snapshotFor(next);
    await chrome.storage.session.set({ [keyFor(tabId)]: next });
    try {
      await inject(tabId, next);
      await writeState({ readingLanguages: { language: next.language, meaningLanguage: next.meaningLanguage } });
    } catch (error) {
      await stop(tabId);
      throw error;
    }
    return next;
  }
  if (!mode || originOf(sender.url) !== mode.origin) throw new Error('Start Reading Mode from the companion.');
  if (message.type === 'neoankiReadingStop') { await stop(tabId); return null; }
  if (message.type === 'neoankiReadingSnapshot') return snapshotFor(mode, message.since);
  if (message.type === 'neoankiReadingDetails') return details(message, mode);
  if (message.type === 'neoankiReadingForms') return dictionaryForms(message, mode);
  if (message.type === 'neoankiReadingOptions') return captureOptions(message, mode);
  if (message.type === 'neoankiReadingRememberDeck') {
    const { deckID } = message;
    if (deckID !== '' && (typeof deckID !== 'string' || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(deckID))) {
      throw new Error('Choose a deck from the list.');
    }
    await writeState({ [deckKeyFor(mode.language)]: deckID });
    return null;
  }
  const { config } = await readState();
  const api = makeAPI(config);
  if (['neoankiReadingJudge', 'neoankiReadingBatch'].includes(message.type)
      && ![message.judgment, ...(message.entries || []).map(entry => entry.judgment)].filter(Boolean).every(value => recordable.includes(value))) {
    throw new Error('Unknown vocabulary judgment.');
  }
  // Reading judgments apply to the word as a whole, never to one meaning.
  if (message.type === 'neoankiReadingJudge') {
    return api('/v1/known-words/judgments', { method: 'POST', key: message.key,
      body: { term: termFor(message.term, mode), judgment: message.judgment } });
  }
  if (message.type === 'neoankiReadingBatch') {
    const entries = message.entries.map(entry => ({ term: termFor(entry.term, mode), judgment: entry.judgment }));
    return postJudgmentBatches(api, entries, message.keys);
  }
  if (message.type === 'neoankiReadingUndoBatches') return undoJudgmentBatches(api, message.batchIds, message.keys);
  if (message.type !== 'neoankiReadingCreate') throw new Error('Unknown Reading Mode action.');
  const { draft } = message;
  const page = draft.usePageSource !== false ? safeSource({ url: sender.url, title: sender.tab?.title }) : null;
  const source = [page?.title, page?.url, ...(draft.dictionarySources || [])].filter(Boolean).join('\n');
  return api('/v1/vocabulary-sets', { method: 'POST', key: message.key, body: {
    term: { ...draft.term, language: mode.language }, meaning: draft.meaning,
    meaningLanguage: draft.meaningLanguage || mode.meaningLanguage, sentence: draft.sentence,
    occurrence: draft.occurrence ?? 0,
    ...(draft.productionSentence && draft.productionForm ? { productionSentence: draft.productionSentence, productionForm: draft.productionForm } : {}),
    ...(draft.deckID ? { deckID: draft.deckID } : {}),
    ...(source ? { source } : {}),
  } });
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (!message?.type?.startsWith('neoankiReading')) return;
  handle(message, sender).then(value => respond({ value }), error => respond({ error: error.message, status: error.status }));
  return true;
});

chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.status !== 'complete') return;
  void (async () => {
    const mode = await modeFor(tabId);
    if (!mode) return;
    if (originOf(tab.url) !== mode.origin) { await stop(tabId); return; }
    try { await inject(tabId, mode); } catch { await stop(tabId); }
  })();
});
chrome.tabs.onRemoved.addListener(tabId => { void chrome.storage.session.remove(keyFor(tabId)); });
