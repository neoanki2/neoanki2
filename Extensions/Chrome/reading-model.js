// Pure Known Words rules shared by Reading Mode, the worker, and Settings.
// A classic script: content scripts cannot import modules, so it publishes one global.
// Keep matchKey and stateFor in sync with VocabularyTerm.matchKey and
// VocabularySnapshot.state(of:lemmas:) in NeoAnkiCore.
globalThis.NeoAnkiReadingModel = (() => {
  // Unicode White_Space, which Swift's Character.isWhitespace uses (JavaScript's \s differs).
  const whitespace = /[\t-\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+/u;
  const stressMarked = new Set(['uk', 'ru', 'be']);
  const apostrophes = new Set(['uk', 'be']);
  const labels = { known: 'Known', learning: 'Learning', unfamiliar: 'Not known', unassessed: 'Unassessed', ignored: 'Ignored' };
  const explicit = new Set(['known', 'unfamiliar', 'ignored']);
  const batchLimit = 20000;

  const primaryLanguage = language => String(language || '').trim().replaceAll('_', '-').toLowerCase().split('-')[0];

  // Dictionaries mark stress in uk/ru/be (\u043a\u043d\u0438\u0301\u0436\u043a\u0430); text and match keys leave it out. Case is kept.
  function withoutStress(text, language) {
    const value = String(text);
    return stressMarked.has(primaryLanguage(language)) ? value.normalize('NFD').replace(/[\u0300\u0301]/gu, '').normalize('NFC') : value;
  }

  function matchKey(text, language) {
    // JavaScript lowercases a final \u03a3 to \u03c2; Swift always to \u03c3. Keys use \u03c3 in every language.
    let value = String(text).normalize('NFC').toLowerCase().split(whitespace).filter(Boolean).join(' ').replaceAll('\u03c2', '\u03c3');
    value = withoutStress(value, language);
    if (apostrophes.has(primaryLanguage(language))) value = value.replace(/[\u2019\u02bc]/gu, "'");
    return value;
  }

  // Words such as "constructor" must not read inherited properties.
  const lookup = (map, key) => map && Object.hasOwn(map, key) ? map[key] : undefined;

  // A copy of a snapshot map without a prototype, so `map[key] = state` is safe for "__proto__".
  const record = (map = {}) => Object.assign(Object.create(null), map);

  // The dictionary forms a pack resolved for `word`, from a `{ word: [forms] }` reply.
  const formsIn = (data, word) => {
    const value = lookup(data, word);
    return Array.isArray(value) ? value.filter(form => typeof form === 'string') : [];
  };

  // The state of a word in text, given the dictionary forms a pack resolves it to.
  function stateFor(snapshot, text, lemmaCandidates = []) {
    const language = snapshot.language;
    const own = lookup(snapshot.expressions, matchKey(text, language));
    if (typeof own === 'string') return own;
    const states = new Set((Array.isArray(lemmaCandidates) ? lemmaCandidates : []).map(form => matchKey(form, language))
      .map(key => lookup(snapshot.lemmas, key) ?? lookup(snapshot.expressions, key) ?? 'unassessed'));
    if (states.size && [...states].every(state => state === 'known' || state === 'ignored')) {
      return states.has('known') ? 'known' : 'ignored';
    }
    return states.has('learning') ? 'learning' : 'unassessed';
  }

  // Word-like segments with at least one letter. Numbers and symbols are not vocabulary.
  function isCountableWord(segment) {
    if (typeof segment === 'object' && segment?.isWordLike === false) return false;
    const text = typeof segment === 'string' ? segment : segment?.segment;
    return /\p{L}/u.test(text || '');
  }

  // Share of word occurrences that are known. Ignored words are left out; `newWords`
  // counts distinct unassessed words. Takes `{ key, state }` occurrences.
  function coverage(words) {
    let counted = 0, known = 0;
    const fresh = new Set();
    for (const { key, state } of words) {
      if (state === 'ignored') continue;
      counted++;
      if (state === 'known') known++;
      if (state === 'unassessed') fresh.add(key);
    }
    return { counted, known, newWords: fresh.size, percent: counted ? Math.floor(known * 100 / counted) : null };
  }

  // What the panel says about one spelling, from its `GET /v1/known-words?expression=` rows.
  // `fallback` is the snapshot state, used when the spelling has no rows (for example, known
  // through its dictionary form).
  function describe(rows, fallback = 'unassessed') {
    const general = rows.find(row => !row.term?.sense);
    const state = rows.find(row => row.expressionState)?.expressionState || fallback;
    let detail = '';
    if (state === 'known') {
      const marked = general?.judgment === 'known' ? general : rows.find(row => row.judgment === 'known');
      detail = marked ? (marked.origin === 'archivedReviews' ? 'Kept from deleted cards' : 'Marked by you')
        : rows.some(row => row.readingMature) ? 'From reviews' : rows.length ? '' : 'Through its dictionary form';
    }
    return {
      state, label: labels[state] || labels.unassessed, detail,
      clozeMature: rows.some(row => row.clozeMature), explicit: explicit.has(general?.judgment),
      previous: general?.judgment || 'reviewHistory',
    };
  }

  // The dictionary form of an exact pack search, when every entry agrees on one.
  function lemmaFromEntries(entries, language) {
    const forms = (entries || []).map(entry => entry.canonicalForm?.text?.value?.trim()).filter(Boolean);
    return new Set(forms.map(form => matchKey(form, language))).size === 1 ? forms[0] : undefined;
  }

  function chunks(values, size = batchLimit) {
    const result = [];
    for (let index = 0; index < values.length; index += size) result.push(values.slice(index, index + size));
    return result;
  }

  // Bands are `{ end, sample, known }` from most frequent. Returns how many top words to mark:
  // every band up to the first one where the learner knows less than 80% of the sample.
  function placementTarget(bands, total = Infinity) {
    let end = 0;
    for (const band of bands) {
      if (!band.sample || band.known / band.sample < 0.8) break;
      end = band.end;
    }
    return Math.min(end, total);
  }

  return { batchLimit, chunks, coverage, describe, formsIn, isCountableWord, lemmaFromEntries, lookup, matchKey, placementTarget,
    primaryLanguage, record, stateFor, withoutStress };
})();
