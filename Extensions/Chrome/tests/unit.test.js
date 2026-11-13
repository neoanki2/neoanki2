import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { allPages, apiBase, APIError, applyAutofill, BASIC_ID, basicFields, DictionaryLookup, emptyDraft, makeAPI, readSelection, renderEntry, revokeClient, safeSource, saveDraft } from '../core.js';

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
