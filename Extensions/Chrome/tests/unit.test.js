import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { allPages, apiBase, APIError, applyAutofill, BASIC_ID, BATCH_LIMIT, batchKeys, basicFields, capabilities, DictionaryLookup, emptyDraft, hasCapabilities, makeAPI, PLACEMENT_CAPABILITIES, postJudgmentBatches, READING_CAPABILITIES, readSelection, renderEntry, requireCapabilities, revokeClient, safeSource, saveDraft, undoJudgmentBatches } from '../core.js';

// reading-model.js is a classic script for content scripts; load it the way Chrome does.
const readingModel = () => {
  const context = vm.createContext({});
  vm.runInContext(readFileSync(new URL('../reading-model.js', import.meta.url), 'utf8'), context);
  return context.NeoAnkiReadingModel;
};
const model = readingModel();
// Values from the script's realm have other prototypes; compare their JSON.
const plain = value => JSON.parse(JSON.stringify(value));

const fields = { itemTypeId: BASIC_ID, frontId: 'front-id', backId: 'back-id' };
const config = { port: 8766, token: 'fixture-token', clientId: 'fixture-client' };
const entry = (word = 'їжак 🦔') => ({
  canonicalForm: { text: { value: word } }, forms: [{ text: { value: word } }, { text: { value: 'hedgehogs' } }],
  pronunciations: [{ representations: [{ text: { _0: { value: 'ˈhɛdʒhɒɡ' } } }, { audio: { _0: { path: 'ignored.mp3' } } }] }],
  senses: [{ definitions: [{ text: { value: 'A hedgehog.' } }, { text: { value: 'A hedgehog.' } }] }],
});
const basic = () => ({ id: BASIC_ID, fields: [
  { id: fields.frontId, name: 'Front', type: 'text', isRequired: true },
  { id: fields.backId, name: 'Back', type: 'text', isRequired: true },
], templates: [{ interaction: 'reveal', prompt: [{ source: { kind: 'field', fieldId: fields.frontId } }],
  answer: [{ source: { kind: 'field', fieldId: fields.backId } }] }] });
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

test('port configuration stays on IPv4 loopback', () => {
  assert.equal(apiBase(), 'http://127.0.0.1:8766');
  assert.equal(apiBase('12345'), 'http://127.0.0.1:12345');
  for (const port of [80, 0, 65536, '8766/path', 'localhost', '1e4', 'NaN', '']) assert.throws(() => apiBase(port));
});

test('library reads follow pagination without exceeding the API limit', async () => {
  const calls = [];
  const values = await allPages(async path => {
    calls.push(path);
    return calls.length === 1 ? { data: [1], page: { nextCursor: 'next/?' } } : { data: [2], page: {} };
  }, '/v1/decks');
  assert.deepEqual(values, [1, 2]);
  assert.deepEqual(calls, ['/v1/decks?limit=200', '/v1/decks?limit=200&cursor=next%2F%3F']);
});

test('Basic must generate an ordinary front/back reveal card', () => {
  assert.deepEqual(basicFields([basic()]), fields);
  const restored = { ...basic(), id: 'restored-basic', name: 'Basic' };
  assert.equal(basicFields([restored]).itemTypeId, 'restored-basic');
  assert.throws(() => basicFields([]), /Basic/);
  const missingCard = basic(); missingCard.templates = [];
  assert.throws(() => basicFields([missingCard]), /reveal/);
  const conditional = basic(); conditional.templates[0].generateWhen = { kind: 'fieldEmpty', fieldId: fields.frontId };
  assert.throws(() => basicFields([conditional]));
  const extraRequired = basic(); extraRequired.fields.push({ id: 'extra', name: 'Image', type: 'image', isRequired: true });
  assert.throws(() => basicFields([extraRequired]));
});

test('dictionary rendering matches Swift text enum encoding and deduplicates', () => {
  assert.equal(renderEntry(entry()), 'їжак 🦔\nhedgehogs\n\nˈhɛdʒhɒɡ\n\nA hedgehog.');
});

test('autofill preserves manual edits, but can replace its own last suggestion', () => {
  const draft = emptyDraft();
  assert.ok(applyAutofill(draft, 'suggestion'));
  assert.ok(applyAutofill(draft, 'new suggestion'));
  draft.back = 'my translation';
  assert.equal(applyAutofill(draft, 'late suggestion'), false);
  assert.equal(draft.back, 'my translation');
  draft.back = '';
  assert.ok(applyAutofill(draft, 'selected suggestion'));
});

test('one exact dictionary match autofills and encodes Unicode', async () => {
  const completed = deferred(); const paths = [];
  const lookup = new DictionaryLookup(async path => { paths.push(path); return { data: [entry()] }; }, result => {
    if (result.automaticText) completed.resolve(result);
  }, 0);
  lookup.search(' їжак 🦔 ', 'uk/pack');
  const result = await completed.promise;
  assert.equal(result.automaticText, renderEntry(entry()));
  assert.equal(paths.length, 1);
  assert.match(paths[0], /uk%2Fpack\/entries\?query=%D1%97/);
});

test('ambiguous exact matches are suggestions without autofill', async () => {
  const completed = deferred();
  const lookup = new DictionaryLookup(async () => ({ data: [entry('bank'), entry('bank')] }), result => {
    if (result.entries.length) completed.resolve(result);
  }, 0);
  lookup.search('bank', 'pack');
  assert.equal((await completed.promise).automaticText, null);
});

test('prefix fallback suggests matches without automatic selection', async () => {
  const completed = deferred(); const paths = [];
  const lookup = new DictionaryLookup(async path => {
    paths.push(path); return { data: path.endsWith('mode=exact') ? [] : [entry()] };
  }, result => { if (result.entries.length) completed.resolve(result); }, 0);
  lookup.search('їж', 'pack');
  assert.equal((await completed.promise).automaticText, null);
  assert.equal(paths.length, 2);
  assert.match(paths[1], /mode=prefix$/);
});

test('stale dictionary results never replace the new query', async () => {
  const firstStarted = deferred(), firstResponse = deferred(), completed = deferred();
  const published = [];
  const lookup = new DictionaryLookup(async path => {
    if (path.includes('query=first&')) { firstStarted.resolve(); return firstResponse.promise; }
    return { data: [entry('second')] };
  }, result => {
    published.push(result);
    if (result.automaticText?.startsWith('second')) completed.resolve();
  }, 0);
  lookup.search('first', 'pack'); await firstStarted.promise;
  lookup.search('second', 'pack'); await completed.promise;
  firstResponse.resolve({ data: [entry('first')] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(published.filter(result => result.automaticText).length, 1);
});

test('missing packs and failed lookup leave manual entry available', async () => {
  const published = [];
  const failed = deferred();
  const lookup = new DictionaryLookup(async () => { throw new Error('offline'); }, result => {
    published.push(result); if (result.message.includes('unavailable')) failed.resolve(result);
  }, 0);
  lookup.search('word', '');
  assert.match(published[0].message, /type an answer/);
  lookup.search('word', 'pack');
  assert.match((await failed.promise).message, /type an answer/);
});

test('draft is durable before POST and ambiguous retries reuse the exact identity and body', async () => {
  const draft = { ...emptyDraft('deck-id'), front: 'їжак 🦔', back: 'A hedgehog.', source: { title: 'Page', url: 'https://example.org/watch?v=1' } };
  const calls = [];
  let durable;
  const persist = async () => { durable = structuredClone(draft); };
  const api = async (path, request) => {
    assert.deepEqual(durable.pending.body, request.body);
    calls.push(structuredClone(request));
    if (calls.length === 1) throw new Error('Connection lost after commit');
    return { cardIds: ['card'] };
  };
  await assert.rejects(saveDraft(draft, fields, config, persist, api));
  draft.front = 'would otherwise create a duplicate';
  await saveDraft(draft, fields, config, persist, api);
  assert.deepEqual(calls[0], calls[1]);
  assert.equal(calls[0].body.fields[0].value.text, 'їжак 🦔');
  assert.equal(calls[0].body.deckId, 'deck-id');
  assert.equal(calls[0].body.fields[1].value.text, 'A hedgehog.\n\nSource: Page\nhttps://example.org/watch?v=1');
});

test('no POST occurs if storage fails or a pending connection changed', async () => {
  const draft = { ...emptyDraft(), front: 'word', back: 'meaning' };
  let posts = 0;
  const api = async () => { posts++; };
  await assert.rejects(saveDraft(draft, fields, config, async () => { throw new Error('full'); }, api));
  assert.equal(posts, 0);
  await assert.rejects(saveDraft(draft, fields, { ...config, clientId: 'new' }, async () => {}, api), /another connection/);
  assert.equal(posts, 0);
});

test('definite rejection unlocks the draft only after confirming its UUID is absent', async () => {
  const draft = { ...emptyDraft(), front: 'word', back: 'My authored answer' };
  const writes = [];
  const calls = [];
  await assert.rejects(saveDraft(draft, fields, config, async () => writes.push(structuredClone(draft)), async (path, options) => {
    calls.push({ path, method: options?.method });
    throw new APIError(options?.method === 'POST' ? 422 : 404);
  }));
  assert.equal(draft.pending, null);
  assert.equal(draft.back, 'My authored answer');
  assert.equal(writes.at(-1).pending, null);
  assert.match(calls[1].path, /^\/v1\/items\/[0-9a-f-]+$/);
});

test('failed rejection probe retains the immutable pending save', async () => {
  const draft = { ...emptyDraft(), front: 'word', back: 'meaning' };
  await assert.rejects(saveDraft(draft, fields, config, async () => {}, async (path, options) => {
    if (options?.method === 'POST') throw new APIError(422);
    throw new Error('connection lost');
  }));
  assert.ok(draft.pending);
});

test('source URLs accept web pages only', () => {
  assert.equal(safeSource({ url: 'chrome://settings', title: 'Private' }), null);
  assert.equal(safeSource({ url: 'javascript:alert(1)' }), null);
  assert.equal(safeSource({ url: 'file:///private/path' }), null);
  assert.deepEqual(safeSource({ url: 'https://example.org/path', title: '<b>Title</b>' }), { url: 'https://example.org/path', title: '<b>Title</b>' });
});

test('capture handles page selection, text inputs, and excludes password values', () => {
  const capture = element => vm.runInNewContext(`(${readSelection.toString()})()`, {
    document: { activeElement: element, title: 'Test page' },
    window: { getSelection: () => ({ toString: () => ' їжак 🦔 ' }) }, location: { href: 'https://example.org/' },
  });
  assert.equal(capture(null).text, 'їжак 🦔');
  assert.equal(capture({ tagName: 'TEXTAREA', value: 'the chosen word', selectionStart: 4, selectionEnd: 10 }).text, 'chosen');
  assert.equal(capture({ tagName: 'INPUT', type: 'password', value: 'never-capture', selectionStart: 0, selectionEnd: 13 }).text, 'їжак 🦔');
});

test('API client handles offline and revoked access without leaking credentials', async () => {
  await assert.rejects(makeAPI(config, async () => { throw new TypeError('fetch failed'); })('/v1/decks'), /enable Local API/);
  await assert.rejects(makeAPI(config, async () => new Response('{}', { status: 401 }))('/v1/decks'), /connect again/);
  await assert.rejects(makeAPI(config)('https://elsewhere.invalid/'), /Invalid API path/);
  await makeAPI(config, async (url, request) => {
    assert.equal(url, 'http://127.0.0.1:8766/v1/decks');
    assert.equal(request.credentials, 'omit');
    assert.equal(request.redirect, 'error');
    assert.equal(request.headers.Authorization, 'Bearer fixture-token');
    return Response.json({ data: [] });
  })('/v1/decks');
});

test('extension requests explicitly preserve Origin on authenticated GETs', async () => {
  globalThis.location = { origin: 'chrome-extension://fixture-extension' };
  try {
    await makeAPI(config, async (url, request) => {
      assert.equal(request.headers.Origin, 'chrome-extension://fixture-extension');
      return Response.json({});
    })('/v1/clients/current');
  } finally { delete globalThis.location; }
});

test('disconnect reads the current revision before conditional revocation', async () => {
  const calls = [];
  await revokeClient(async (path, options) => {
    calls.push({ path, options });
    return { revision: 4 };
  });
  assert.equal(calls[0].options, undefined);
  assert.deepEqual(calls[1], { path: '/v1/clients/current', options: { method: 'DELETE', ifMatch: '"revision-4"' } });
});

test('match keys mirror NeoAnkiCore for every shared vector', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../../NeoAnkiCore/Tests/Fixtures/vocabulary-match-keys.json', import.meta.url), 'utf8'));
  assert.ok(fixture.vectors.length > 10);
  for (const vector of fixture.vectors) {
    assert.equal(model.matchKey(vector.input, vector.language), vector.key, `${vector.language}: ${vector.input}`);
  }
  assert.equal(model.matchKey('a\u00a0b\u3000c', 'en'), 'a b c', 'Unicode spaces collapse like Swift');
  assert.equal(model.matchKey('a\ufeffb', 'en'), 'a\ufeffb', 'A zero-width no-break space is not whitespace in Swift');
});

test('snapshot states mirror VocabularySnapshot.state(of:lemmas:)', () => {
  const snapshot = { version: '1', language: 'uk',
    expressions: { 'книжки': 'known', 'київ': 'known', 'мати': 'learning', 'мама': 'unfamiliar', 'нато': 'ignored', 'знову': 'unassessed' },
    lemmas: { 'книжка': 'known', 'мати': 'learning', 'нато': 'ignored', 'бути': 'known' } };
  assert.equal(model.stateFor(snapshot, 'Ки́їв'), 'known', 'The spelling itself wins, after stress marks are removed');
  assert.equal(model.stateFor(snapshot, 'книжку', ['кни́жка']), 'known');
  assert.equal(model.stateFor(snapshot, 'книжкою'), 'unassessed', 'Without dictionary forms only spellings match');
  assert.equal(model.stateFor(snapshot, 'мамі', ['мати', 'мама']), 'learning', 'Any learning form makes the word learning');
  assert.equal(model.stateFor(snapshot, 'буде', ['бути', 'будувати']), 'unassessed', 'Every form must be known or ignored');
  assert.equal(model.stateFor(snapshot, 'нату', ['нато']), 'ignored');
  assert.equal(model.stateFor(snapshot, 'нату', ['нато', 'бути']), 'known');
  assert.equal(model.stateFor(snapshot, 'знову', ['бути']), 'unassessed', 'A listed spelling is never overridden by its forms');
  assert.equal(model.stateFor({ language: 'en', expressions: {}, lemmas: {} }, 'constructor'), 'unassessed');
  assert.equal(model.stateFor({ language: 'en', expressions: {}, lemmas: {} }, 'word', ['toString']), 'unassessed');
});

test('words named like Object properties never read inherited values', () => {
  const empty = { language: 'en', expressions: {}, lemmas: {} };
  // A pack reply that lists neither word; plain lookups would return Object.prototype members.
  const reply = JSON.parse('{"cat": ["cat"]}');
  for (const word of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
    const forms = model.formsIn(reply, word);
    assert.deepEqual(plain(forms), [], word);
    assert.equal(model.stateFor(empty, word, forms), 'unassessed', word);
    assert.equal(model.stateFor(empty, word, ({})[word]), 'unassessed', `${word} with a non-array candidate`);
  }
  const listed = JSON.parse('{"__proto__": ["__proto__"], "constructor": "nope"}');
  assert.deepEqual(plain(model.formsIn(listed, '__proto__')), ['__proto__']);
  assert.deepEqual(plain(model.formsIn(listed, 'constructor')), [], 'Only arrays are dictionary forms');
  assert.equal(model.formsIn(undefined, 'constructor').length, 0);
  // Snapshot maps from JSON may list these words; a prototype-free copy can also record them.
  const snapshot = { language: 'en', expressions: model.record(JSON.parse('{"__proto__": "known"}')), lemmas: model.record() };
  assert.equal(model.stateFor(snapshot, '__proto__'), 'known');
  snapshot.expressions.constructor = 'ignored';
  assert.equal(model.stateFor(snapshot, 'constructor'), 'ignored');
  snapshot.lemmas.__proto__ = 'learning';
  assert.equal(model.lookup(snapshot.lemmas, '__proto__'), 'learning');
  assert.equal(model.stateFor(snapshot, 'protos', ['__proto__']), 'learning');
  assert.equal(model.lookup({}, 'constructor'), undefined);
});

test('placement words drop stress marks only where match keys do', () => {
  assert.equal(model.withoutStress('кни́жка', 'uk'), 'книжка');
  assert.equal(model.withoutStress('Сло̀во', 'uk-UA'), 'Слово', 'Case stays as in the dictionary');
  assert.equal(model.withoutStress('молоко́', 'ru'), 'молоко');
  assert.equal(model.withoutStress('сло́ва', 'be'), 'слова');
  assert.equal(model.withoutStress('й', 'uk'), 'й', 'Letters built with other marks survive');
  assert.equal(model.withoutStress('ёж', 'ru'), 'ёж');
  assert.equal(model.withoutStress('Cáfé', 'fr'), 'Cáfé', 'Other languages keep their accents');
  assert.equal(model.withoutStress('à', 'it'), 'à');
  assert.equal(model.matchKey(model.withoutStress('Кни́жка', 'uk'), 'uk'), model.matchKey('Кни́жка', 'uk'));
});

test('Greek sigma matches in every position', () => {
  assert.equal(model.matchKey('ΟΔΟΣ', 'el'), model.matchKey('οδος', 'el'));
  assert.equal(model.matchKey('Σοφός', 'el'), 'σοφόσ');
  assert.equal(model.matchKey('ς', 'en'), 'σ', 'Every language maps final sigma');
});

test('numbers and symbols are not countable words', () => {
  assert.equal(model.isCountableWord('книга'), true);
  assert.equal(model.isCountableWord('3D'), true);
  assert.equal(model.isCountableWord('2024'), false);
  assert.equal(model.isCountableWord('1,000'), false);
  assert.equal(model.isCountableWord({ segment: 'word', isWordLike: false }), false);
  const segments = Array.from(new Intl.Segmenter('en', { granularity: 'word' }).segment('In 2024, 12 cats sat.'));
  assert.deepEqual(segments.filter(model.isCountableWord).map(value => value.segment), ['In', 'cats', 'sat']);
});

test('coverage counts known occurrences and leaves ignored words out', () => {
  const result = model.coverage([
    { key: 'the', state: 'known' }, { key: 'the', state: 'known' }, { key: 'cat', state: 'unassessed' },
    { key: 'cat', state: 'unassessed' }, { key: 'sat', state: 'learning' }, { key: 'zorblax', state: 'ignored' },
    { key: 'mat', state: 'unfamiliar' }, { key: 'on', state: 'known' },
  ]);
  assert.deepEqual(plain(result), { counted: 7, known: 3, newWords: 1, percent: 42 });
  assert.equal(model.coverage([]).percent, null);
  assert.equal(model.coverage([{ key: 'x', state: 'ignored' }]).percent, null);
});

test('panel status explains why a word is known', () => {
  const row = (fields, sense) => ({ term: { language: 'en', expression: 'bank', ...(sense ? { sense } : {}) }, readingMature: false, clozeMature: false, hasCards: false, ...fields });
  let info = model.describe([row({ judgment: 'known', expressionState: 'known' })]);
  assert.deepEqual([info.label, info.detail, info.explicit, info.previous], ['Known', 'Marked by you', true, 'known']);
  info = model.describe([row({ judgment: 'known', origin: 'archivedReviews', expressionState: 'known' })]);
  assert.equal(info.detail, 'Kept from deleted cards');
  info = model.describe([row({ readingMature: true, clozeMature: true, hasCards: true, expressionState: 'known' }, 'river')]);
  assert.deepEqual([info.detail, info.clozeMature, info.explicit, info.previous], ['From reviews', true, false, 'reviewHistory']);
  info = model.describe([row({ judgment: 'known', expressionState: 'known' }, 'river'), row({ hasCards: true, expressionState: 'known' }, 'money')]);
  assert.equal(info.detail, 'Marked by you', 'A known meaning makes the spelling known');
  assert.equal(model.describe([], 'known').detail, 'Through its dictionary form');
  assert.equal(model.describe([row({ judgment: 'unfamiliar', expressionState: 'unfamiliar' })]).label, 'Not known');
  assert.equal(model.describe([row({ judgment: 'ignored', expressionState: 'ignored' })]).explicit, true);
  assert.equal(model.describe([row({ judgment: 'reviewHistory', expressionState: 'unassessed' })]).explicit, false);
  assert.equal(model.describe([], 'learning').label, 'Learning');
  assert.equal(model.describe([]).label, 'Unassessed');
});

test('a lemma is sent only when every exact dictionary entry agrees on one form', () => {
  const form = value => ({ canonicalForm: { text: { value } } });
  assert.equal(model.lemmaFromEntries([form('кни́жка'), form('книжка')], 'uk'), 'кни́жка');
  assert.equal(model.lemmaFromEntries([form('bank'), form('bank')], 'en'), 'bank');
  assert.equal(model.lemmaFromEntries([form('мати'), form('мама')], 'uk'), undefined);
  assert.equal(model.lemmaFromEntries([], 'uk'), undefined);
});

test('placement marks every band up to the first one known below 80%', () => {
  const bands = [{ end: 1000, sample: 20, known: 19 }, { end: 3000, sample: 20, known: 16 }, { end: 5000, sample: 20, known: 15 }, { end: 10000, sample: 20, known: 20 }];
  assert.equal(model.placementTarget(bands), 3000);
  assert.equal(model.placementTarget(bands, 2500), 2500);
  assert.equal(model.placementTarget([{ end: 1000, sample: 20, known: 15 }]), 0);
  assert.equal(model.placementTarget([]), 0);
  assert.deepEqual(plain(model.chunks([1, 2, 3, 4, 5], 2)), [[1, 2], [3, 4], [5]]);
});

test('capability checks ask the app once and explain an outdated app', async () => {
  let calls = 0;
  let advertised = ['vocabulary.known-words'];
  const fetcher = async url => { calls++; assert.match(url, /\/v1\/meta$/); return Response.json({ capabilities: advertised }); };
  const outdated = { port: 9101 };
  await assert.rejects(requireCapabilities(outdated, READING_CAPABILITIES, 'Update NeoAnki2 to use this version of Reading Mode.', fetcher),
    /Update NeoAnki2/);
  advertised = [...PLACEMENT_CAPABILITIES, 'vocabulary.dictionary-forms'];
  await requireCapabilities(outdated, READING_CAPABILITIES, 'unused', fetcher);
  assert.equal(calls, 2, 'An insufficient answer is checked again, so updating the app takes effect');
  assert.equal(await hasCapabilities(outdated, PLACEMENT_CAPABILITIES, fetcher), true);
  assert.equal((await capabilities(outdated, fetcher)).has('vocabulary.dictionary-forms'), true);
  assert.equal(calls, 2, 'A sufficient answer is cached');
  const offline = { port: 9102 };
  await assert.rejects(capabilities(offline, async () => { throw new TypeError('fetch failed'); }), /enable Local API/);
  assert.equal(await hasCapabilities(offline, READING_CAPABILITIES, fetcher), true, 'A failed check is not cached');
});

test('bulk judgments chunk at 20,000, keep their keys, and undo in reverse', async () => {
  const entries = Array.from({ length: BATCH_LIMIT * 2 + 1 }, (_, index) => ({ term: { language: 'en', expression: `w${index}` }, judgment: 'known' }));
  let counter = 0;
  const keys = batchKeys(entries.length, () => `key-${counter++}`);
  assert.deepEqual(keys, ['key-0', 'key-1', 'key-2']);
  const calls = [];
  const api = async (path, options) => {
    calls.push({ path, key: options.key, size: options.body?.entries.length });
    return { batchId: `batch-${calls.length}`, recorded: options.body?.entries.length ?? 1, unchanged: 0, changes: [] };
  };
  const receipt = await postJudgmentBatches(api, entries, keys);
  assert.deepEqual(receipt, { batchIds: ['batch-1', 'batch-2', 'batch-3'], recorded: entries.length, unchanged: 0 });
  assert.deepEqual(calls.map(call => [call.key, call.size]), [['key-0', BATCH_LIMIT], ['key-1', BATCH_LIMIT], ['key-2', 1]]);
  assert.ok(calls.every(call => call.path === '/v1/known-words/judgment-batches'));
  await assert.rejects(postJudgmentBatches(api, entries, keys.slice(0, 1)), /Missing batch key/);
  calls.length = 0;
  await undoJudgmentBatches(api, ['a/b', 'c'], ['undo-a', 'undo-c']);
  assert.deepEqual(calls.map(call => [call.path, call.key]), [
    ['/v1/known-words/judgment-batches/c/undo', 'undo-c'], ['/v1/known-words/judgment-batches/a%2Fb/undo', 'undo-a'],
  ]);
});
