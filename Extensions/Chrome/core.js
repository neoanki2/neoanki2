export const BASIC_ID = 'a2000001-0000-4000-8000-000000000001';
export const SCOPES = ['library.read', 'items.write', 'vocabulary.read'];

export function apiBase(port = 8766) {
  if (!/^\d+$/.test(String(port)) || Number(port) < 1024 || Number(port) > 65535) {
    throw new Error('Enter a port from 1024 through 65535.');
  }
  return `http://127.0.0.1:${Number(port)}`;
}

export class APIError extends Error {
  constructor(status, problem = {}) {
    const message = status === 401 ? 'Access was revoked or expired. Open Settings and connect again.'
      : status === 403 ? 'Access was denied. Check the approved client permissions in NeoAnki2.'
      : problem.detail || problem.title || `NeoAnki2 returned an error (${status}).`;
    super(message);
    this.status = status;
    this.code = problem.code;
  }
}

export function makeAPI(config, fetcher = fetch) {
  const base = apiBase(config.port);
  return async (path, { method = 'GET', body, key, ifMatch, timeout = 15000, signal } = {}) => {
    if (!path.startsWith('/v1/')) throw new Error('Invalid API path.');
    const headers = {};
    // Privileged Chrome extension GETs omit Origin unless explicitly supplied.
    // Send it on every method so reads match the origin-bound pairing grant too.
    const origin = globalThis.location?.origin;
    if (origin?.startsWith('chrome-extension://')) headers.Origin = origin;
    if (config.token) headers.Authorization = `Bearer ${config.token}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (key) headers['Idempotency-Key'] = key;
    if (ifMatch) headers['If-Match'] = ifMatch;
    let response;
    try {
      response = await fetcher(base + path, {
        method, headers, mode: 'cors', credentials: 'omit', redirect: 'error',
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeout)]) : AbortSignal.timeout(timeout),
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new Error('Could not reach NeoAnki2. Keep the app running, enable Local API, and check the port in Settings.');
    }
    if (!response.ok) {
      const problem = await response.json().catch(() => ({}));
      throw new APIError(response.status, problem);
    }
    if (response.status === 204) return null;
    return response.json();
  };
}

export async function revokeClient(api) {
  const client = await api('/v1/clients/current');
  await api('/v1/clients/current', { method: 'DELETE', ifMatch: `"revision-${client.revision}"` });
}

export async function allPages(api, path) {
  const values = [];
  let cursor;
  const visited = new Set();
  do {
    const page = await api(`${path}?limit=200${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
    values.push(...page.data);
    cursor = page.page?.nextCursor;
    if (cursor && visited.has(cursor)) throw new Error('NeoAnki2 returned a repeated page. Reopen the extension to try again.');
    visited.add(cursor);
  } while (cursor);
  return values;
}

export function basicFields(types) {
  const basic = types.find(type => type.id === BASIC_ID) || types.find(type => type.name === 'Basic');
  const front = basic?.fields.find(field => field.name === 'Front' && field.type === 'text');
  const back = basic?.fields.find(field => field.name === 'Back' && field.type === 'text');
  const slotUses = (slots, id) => slots?.some(slot => slot.source.kind === 'field' && slot.source.fieldId === id);
  const hasCard = basic?.templates.some(template => template.interaction === 'reveal'
    && !template.generateWhen && slotUses(template.prompt, front?.id) && slotUses(template.answer, back?.id));
  if (!front || !back || !hasCard || basic.fields.some(field => field.isRequired && ![front.id, back.id].includes(field.id))) {
    throw new Error('The Basic item type needs text fields named Front and Back and an unconditional reveal card. Restore this setup in NeoAnki2 before saving.');
  }
  return { itemTypeId: basic.id, frontId: front.id, backId: back.id };
}

export function safeSource(source) {
  try {
    const url = new URL(source.url);
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    return { title: source.title || url.hostname, url: url.href };
  } catch { return null; }
}

export function emptyDraft(deckId = '') {
  return { front: '', back: '', lastAuto: null, source: null, deckId, pending: null };
}

export function createPending(draft, fields, config, uuid = () => crypto.randomUUID()) {
  if (!draft.front.trim() || !draft.back.trim()) throw new Error('Add both a front and an answer before saving.');
  const source = safeSource(draft.source || {});
  const back = draft.back.trim() + (source ? `\n\nSource: ${source.title}\n${source.url}` : '');
  return {
    port: Number(config.port || 8766), clientId: config.clientId, key: uuid(),
    body: {
      id: uuid(), itemTypeId: fields.itemTypeId, deckId: draft.deckId || null, tags: [],
      fields: [
        { fieldId: fields.frontId, value: { type: 'text', text: draft.front.trim() } },
        { fieldId: fields.backId, value: { type: 'text', text: back } },
      ],
    },
  };
}

// Persist before POST. An uncertain response keeps this exact body/key across popup lifetimes.
export async function saveDraft(draft, fields, config, persist, api) {
  draft.pending ||= createPending(draft, fields, config);
  if (draft.pending.port !== Number(config.port || 8766) || draft.pending.clientId !== config.clientId) {
    throw new Error('This draft has an unresolved save from another connection. Check NeoAnki2 for the card before discarding the draft.');
  }
  await persist();
  const pending = draft.pending;
  try {
    return await api('/v1/items', { method: 'POST', body: pending.body, key: pending.key });
  } catch (error) {
    // Definite validation/resource rejections can be edited once a read confirms
    // that the known item UUID does not exist. Network/5xx failures stay immutable.
    if (error instanceof APIError && [400, 404, 413, 422].includes(error.status)) {
      let existing;
      try { existing = await api(`/v1/items/${pending.body.id}`); }
      catch (probeError) {
        if (probeError instanceof APIError && probeError.status === 404) {
          draft.pending = null;
          await persist();
        }
      }
      if (existing && existing.itemTypeId === pending.body.itemTypeId && existing.deckId === pending.body.deckId
        && pending.body.fields.every(field => existing.fields.some(value => value.fieldId === field.fieldId
          && value.value.type === field.value.type && value.value.text === field.value.text))) return existing;
    }
    throw error;
  }
}

export function renderEntry(entry) {
  const seen = new Set();
  const unique = values => values.filter(value => {
    if (!value?.trim() || seen.has(value)) return false;
    seen.add(value);
    return true;
  });
  const spellings = unique([entry.canonicalForm.text.value, ...entry.forms.map(form => form.text.value)]);
  const annotations = unique(entry.pronunciations.flatMap(pronunciation => pronunciation.representations
    .map(representation => representation.text?._0?.value).filter(Boolean)));
  const definitions = unique(entry.senses.flatMap(sense => sense.definitions.map(definition => definition.text.value)));
  return [spellings.join('\n'), annotations.join('\n'), ...definitions].filter(Boolean).join('\n\n');
}

export function applyAutofill(draft, value) {
  if (draft.back.trim() && draft.back !== draft.lastAuto) return false;
  draft.back = value;
  draft.lastAuto = value;
  return true;
}

export class DictionaryLookup {
  constructor(api, publish, delay = 300) {
    this.api = api;
    this.publish = publish;
    this.delay = delay;
    this.generation = 0;
  }

  cancel() {
    clearTimeout(this.timer);
    this.controller?.abort();
    this.generation++;
  }

  search(query, packId) {
    this.cancel();
    const generation = this.generation;
    query = query.trim();
    if (!query || !packId) {
      this.publish({ entries: [], message: packId ? '' : 'No dictionary selected. You can type an answer.' });
      return;
    }
    this.controller = new AbortController();
    const signal = this.controller.signal;
    this.publish({ entries: [], message: 'Looking up…' });
    this.timer = setTimeout(async () => {
      const path = `/v1/vocabulary-packs/${encodeURIComponent(packId)}/entries?query=${encodeURIComponent(query)}&limit=20`;
      try {
        const exact = await this.api(path + '&mode=exact', { signal });
        if (generation !== this.generation) return;
        const entries = exact.data.length ? exact.data : (await this.api(path + '&mode=prefix', { signal })).data;
        if (generation !== this.generation) return;
        this.publish({ entries, automaticText: exact.data.length === 1 ? renderEntry(exact.data[0]) : null,
          message: entries.length ? '' : 'No match. You can type an answer.' });
      } catch (error) {
        if (generation === this.generation) this.publish({ entries: [], message: `Dictionary unavailable. ${error.message} You can type an answer.` });
      }
    }, this.delay);
  }
}

// Runs in an isolated world on the active page; no credential or API access.
export function readSelection() {
  const element = document.activeElement;
  let text = window.getSelection()?.toString() || '';
  if (element && (element.tagName === 'TEXTAREA' || (element.tagName === 'INPUT'
    && ['text', 'search', 'url', 'tel'].includes(element.type))) && element.selectionStart != null) {
    text = element.value.slice(element.selectionStart, element.selectionEnd);
  }
  return { text: text.trim(), title: document.title, url: location.href };
}
