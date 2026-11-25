import { allPages, makeAPI, safeSource } from './core.js';
import { readState, writeState } from './storage.js';

const keyFor = tabId => `reading-mode:${tabId}`;
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
  await chrome.scripting.executeScript({ target, files: ['reading-page.js'] });
  await chrome.tabs.sendMessage(tabId, { type: 'neoankiReadingStart', mode }, { frameId: 0 });
}

async function stop(tabId) {
  await chrome.storage.session.remove(keyFor(tabId));
  await Promise.allSettled([
    chrome.tabs.sendMessage(tabId, { type: 'neoankiReadingStop' }, { frameId: 0 }),
    chrome.scripting.removeCSS({ target: { tabId }, files: ['reading.css'] }),
  ]);
}

async function readFor(tabId, mode) {
  const state = await readState();
  const api = makeAPI(state.config);
  const request = `/v1/known-words?language=${encodeURIComponent(mode.language)}`;
  const rows = await allPages(api, request);
  return { rows, lastDeck: state.lastDeck || '' };
}

async function captureOptions(message, mode) {
  const state = await readState();
  const api = makeAPI(state.config);
  const decks = await allPages(api, '/v1/decks');
  if (!state.config.packId) return { decks, meanings: [] };
  const query = new URLSearchParams({ query: message.expression, mode: 'exact', language: mode.language, limit: '20' });
  try {
    const pack = encodeURIComponent(state.config.packId);
    const { data } = await api(`/v1/vocabulary-packs/${pack}/entries?${query}`);
    const meanings = [];
    const seen = new Set();
    for (const entry of data) {
      for (const sense of entry.senses || []) {
        const gloss = sense.definitions?.find(definition => languageCode(definition.text.language) === mode.meaningLanguage)
          || sense.definitions?.[0];
        const meaning = gloss?.text?.value?.trim();
        if (!meaning || seen.has(meaning)) continue;
        seen.add(meaning);
        const example = sense.examples?.find(value => !value.text.language || languageCode(value.text.language) === mode.language);
        meanings.push({ meaning, language: languageCode(gloss.text.language) || mode.meaningLanguage,
          example: example?.text?.value || '', form: example?.target?.exactText || '' });
      }
    }
    return { decks, meanings };
  } catch { return { decks, meanings: [] }; }
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
    await readFor(tabId, next);
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
  if (message.type === 'neoankiReadingSnapshot') return readFor(tabId, mode);
  if (message.type === 'neoankiReadingOptions') return captureOptions(message, mode);
  const { config } = await readState();
  const api = makeAPI(config);
  if (message.type === 'neoankiReadingJudge') {
    return api('/v1/known-words/judgments', { method: 'POST', key: message.key,
      body: { term: { ...message.term, language: mode.language }, judgment: message.judgment } });
  }
  if (message.type !== 'neoankiReadingCreate') throw new Error('Unknown Reading Mode action.');
  const { draft } = message;
  const source = safeSource({ url: sender.url, title: sender.tab?.title });
  const result = await api('/v1/vocabulary-sets', { method: 'POST', key: message.key, body: {
    term: { ...draft.term, language: mode.language }, meaning: draft.meaning,
    meaningLanguage: draft.meaningLanguage || mode.meaningLanguage, sentence: draft.sentence,
    occurrence: draft.occurrence ?? 0,
    ...(draft.productionSentence && draft.productionForm ? { productionSentence: draft.productionSentence, productionForm: draft.productionForm } : {}),
    ...(draft.deckID ? { deckID: draft.deckID } : {}),
    ...(source.url ? { source: [source.title, source.url].filter(Boolean).join('\n') } : {}),
  } });
  await writeState({ lastDeck: draft.deckID || '' }).catch(() => {});
  return result;
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
