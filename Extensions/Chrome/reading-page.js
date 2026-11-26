(() => {
  if (globalThis.neoankiReadingInstalled) return;
  globalThis.neoankiReadingInstalled = true;

  const model = globalThis.NeoAnkiReadingModel;
  const excluded = 'a,button,input,textarea,select,[contenteditable]:not([contenteditable="false"]),nav,script,style,noscript,svg,code,pre,[aria-hidden="true"],[hidden]';
  const blocks = 'p,li,td,dd,dt,blockquote,h1,h2,h3,h4,h5,h6,article,section,div,main,body';
  // Underlined states. Known and ignored words appear as ordinary text.
  const underlined = ['unassessed', 'unfamiliar', 'learning'];
  // Words segmented per pass; larger pages continue in later tasks so the page stays responsive.
  const passLimit = 20000;
  const sampleSize = 12;
  const send = async (action, data) => {
    const reply = await chrome.runtime.sendMessage({ type: `neoankiReading${action}`, ...data });
    if (reply?.error) throw Object.assign(new Error(reply.error), { status: reply.status });
    return reply?.value;
  };

  let mode, host, panel, live, summary, restButton, observer, timer, refreshTimer, statusTimer, selection;
  let wordSegmenter, sentenceSegmenter, languageName, snapshot, root, stale;
  let lastDeck = '', offline = false, dictionary = false, formsRequest = null;
  // After a dictionary-forms failure, lookups pause until `formsRetryAt`, doubling up to 5 minutes.
  let formsRetryAt = 0, formsBackoff = 0;
  // `session` changes on every stop, so replies for an earlier session are dropped.
  let refreshGeneration = 0, session = 0, shown = false, phraseLimit = 1, layout = 0, restyled = false;
  let highlights = {}, phrases = new Set(), positions = new WeakMap(), groups = new WeakMap();
  // Block element → its segmented words. `pending` blocks are collected but not yet segmented;
  // `dirty` blocks changed and must be collected again. `restyled` means an attribute changed,
  // which can hide blocks that are still connected.
  const blockData = new Map(), pending = new Map(), dirty = new Set();
  // Dictionary forms by match key, for words the snapshot doesn't list.
  const forms = new Map(), asked = new Set();
  // Words opened on this page; "Mark the rest as known" leaves them out.
  const touched = new Set();

  const keyOf = text => model.matchKey(text, mode.language);
  const stateOf = key => model.stateFor(snapshot, key, forms.get(key) || []);
  const wordCount = text => Array.from(wordSegmenter.segment(text)).filter(value => value.isWordLike).length;
  const mainRoot = () => document.querySelector('main, [role="main"]') || document.querySelector('article') || document.body;
  // Single-page apps can replace <main>; the next pass then collects the new root.
  const rootMoved = () => Boolean(root) && (!root.isConnected || mainRoot() !== root);
  // A panel's reply still belongs to this page's Reading Mode, and its snapshot.
  const current = picked => Boolean(snapshot) && picked?.session === session;
  function* occurrences() { for (const { words } of blockData.values()) yield* words; }

  function blockOf(element) {
    const nearest = element.closest(blocks);
    return nearest && root.contains(nearest) ? nearest : root;
  }

  // Visible text in the learning language, grouped by its nearest block element.
  function collect(scope) {
    const byBlock = new Map();
    const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const parent = node.parentElement;
      if (!parent || !node.data || parent.closest(excluded)) continue;
      const declared = parent.closest('[lang]');
      if (declared && declared !== document.documentElement
          && declared.lang.toLowerCase().split('-')[0] !== mode.language.split('-')[0]) continue;
      if (!parent.getClientRects().length || getComputedStyle(parent).visibility === 'hidden') continue;
      const block = blockOf(parent);
      const group = byBlock.get(block) || { text: '', parts: [] };
      group.parts.push({ node, start: group.text.length });
      group.text += node.data;
      byBlock.set(block, group);
      groups.set(node, group);
    }
    return byBlock;
  }

  function point(group, offset, end = false) {
    const { parts } = group;
    let low = 0, high = parts.length - 1;
    while (low < high) {
      const middle = (low + high) >> 1;
      const limit = parts[middle].start + parts[middle].node.length;
      if (offset < limit || (end && offset === limit)) high = middle;
      else low = middle + 1;
    }
    const part = parts[low];
    return [part.node, Math.max(0, Math.min(part.node.length, offset - part.start))];
  }

  function makeRange(group, start, end) {
    const range = document.createRange();
    range.setStart(...point(group, start));
    range.setEnd(...point(group, end, true));
    return range;
  }

  function setState(word, state) {
    if (word.state === state) return;
    highlights[word.state]?.delete(word.range);
    word.state = state;
    highlights[state]?.add(word.range);
  }

  function forget(block) {
    for (const word of blockData.get(block)?.words || []) highlights[word.state]?.delete(word.range);
    blockData.delete(block);
  }

  // Split one block into words and tracked phrases. Returns the number of segments it read.
  function segment(block, group) {
    forget(block);
    stale?.delete(block);
    const tokens = Array.from(wordSegmenter.segment(group.text)).filter(value => value.isWordLike);
    const words = [];
    for (const part of group.parts) positions.set(part.node, []);
    let first = 0;
    for (let index = 0; index < tokens.length; index++) {
      const head = tokens[index];
      let last = head;
      for (let candidate = Math.min(tokens.length - 1, index + phraseLimit - 1); candidate > index; candidate--) {
        const tail = tokens[candidate];
        if (phrases.has(keyOf(group.text.slice(head.index, tail.index + tail.segment.length)))) {
          last = tail;
          index = candidate;
          break;
        }
      }
      if (last === head && !model.isCountableWord(head)) continue;
      const start = head.index, end = last.index + last.segment.length;
      const text = group.text.slice(start, end);
      const word = { key: keyOf(text), text, phrase: last !== head, range: makeRange(group, start, end) };
      setState(word, stateOf(word.key));
      words.push(word);
      while (first < group.parts.length && group.parts[first].start + group.parts[first].node.length <= start) first++;
      for (let next = first; next < group.parts.length && group.parts[next].start < end; next++) {
        const part = group.parts[next];
        positions.get(part.node).push({ word, lower: Math.max(0, start - part.start), upper: Math.min(part.node.length, end - part.start) });
      }
    }
    blockData.set(block, { words, text: group.text, parts: group.parts, layout });
    return tokens.length;
  }

  // Whether a collected block reads exactly as when it was segmented, so its words still stand.
  // Attribute changes often collect a block again without changing what it shows.
  function unchanged(block, group) {
    const prior = blockData.get(block);
    return prior?.layout === layout && prior.text === group.text && prior.parts.length === group.parts.length
      && prior.parts.every((part, index) => part.node === group.parts[index].node && part.start === group.parts[index].start);
  }

  // Whether `block` is `scope` or inside one of `scopes`.
  function within(block, scopes) {
    for (let element = block; element && element !== root.parentElement; element = element.parentElement) {
      if (scopes.has(element)) return true;
    }
    return false;
  }

  function hasDirtyAncestor(scope) {
    for (let parent = scope.parentElement; parent && parent !== root.parentElement; parent = parent.parentElement) {
      if (dirty.has(parent)) return true;
    }
    return false;
  }

  function schedule(delay = 0) {
    if (!timer) timer = setTimeout(work, delay);
  }

  // Redraw changed blocks, at most `passLimit` words per task. Returns whether work remains.
  function work() {
    clearTimeout(timer);
    timer = undefined;
    if (!mode || !snapshot) return false;
    const nextRoot = mainRoot();
    if (!nextRoot) return false;
    if (nextRoot !== root || !root.isConnected) {
      for (const block of [...blockData.keys()]) forget(block);
      root = nextRoot;
      stale = undefined;
      pending.clear();
      dirty.clear();
      dirty.add(root);
    }
    const seen = new Set();
    for (const scope of dirty) {
      if (!scope.isConnected || hasDirtyAncestor(scope)) continue;
      const collected = collect(scope);
      if (!collected.has(scope)) forget(scope);
      for (const [block, group] of collected) { pending.set(block, group); seen.add(block); }
    }
    // A block hidden by an attribute change is still connected but no longer collected.
    if (restyled) {
      for (const block of [...blockData.keys()]) {
        if (!seen.has(block) && within(block, dirty)) { forget(block); pending.delete(block); }
      }
      restyled = false;
    }
    dirty.clear();
    for (const block of [...blockData.keys()]) if (!block.isConnected) forget(block);
    let budget = passLimit;
    for (const [block, group] of pending) {
      pending.delete(block);
      if (unchanged(block, group)) { stale?.delete(block); continue; }
      budget -= segment(block, group);
      if (budget <= 0) break;
    }
    if (!pending.size && stale) {
      for (const block of stale) forget(block);
      stale = undefined;
    }
    updateBadge();
    if (pending.size || dirty.size) { schedule(); return true; }
    void resolveForms();
    return false;
  }

  // Segment the whole page again. Old underlines stay until each block is redrawn.
  function redrawAll() {
    layout++;
    if (root) {
      stale = new Set(blockData.keys());
      dirty.add(root);
    }
    pending.clear();
    clearTimeout(timer);
    timer = undefined;
    schedule();
  }

  // Recompute states without segmenting again, after a judgment or new dictionary forms.
  function restate() {
    for (const word of occurrences()) setState(word, stateOf(word.key));
    updateBadge();
  }

  // Collect only the blocks a mutation touched. Removed blocks are dropped in the next pass.
  // Attribute changes (hidden, class, style, open, aria-hidden) can show or hide text, so they
  // collect the element's block again; blocks whose text didn't change keep their words.
  function changed(records) {
    if (!root) return;
    if (rootMoved()) { schedule(120); return; }
    let removedBlock = false;
    const mark = node => {
      const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      if (element && root.contains(element)) dirty.add(blockOf(element));
    };
    for (const record of records) {
      if (record.type === 'attributes') {
        const target = record.target;
        if (host?.contains(target) || record.oldValue === target.getAttribute(record.attributeName)) continue;
        if (root.contains(target)) { dirty.add(blockOf(target)); restyled = true; }
        else if (target.contains(root)) { dirty.add(root); restyled = true; }
        continue;
      }
      if (record.type !== 'childList') { mark(record.target); continue; }
      for (const added of record.addedNodes) mark(added.nodeType === Node.ELEMENT_NODE && added.matches(blocks) ? added : record.target);
      for (const removed of record.removedNodes) {
        if (removed.nodeType !== Node.ELEMENT_NODE || !removed.matches(blocks)) mark(record.target);
        else removedBlock ||= root.contains(record.target);
      }
    }
    if (dirty.size > 500) { dirty.clear(); dirty.add(root); }
    if (dirty.size || removedBlock) schedule(120);
  }

  // Tracked phrases from the snapshot, matched before single words. Returns whether they changed.
  function updatePhrases() {
    const next = new Set();
    let limit = 1;
    // In languages written with spaces, a run of letters is one word; skip segmenting it.
    const spaced = !['ja', 'zh', 'th', 'lo', 'km', 'my'].includes(model.primaryLanguage(mode.language));
    for (const key of Object.keys(snapshot.expressions)) {
      if (spaced && /^[\p{L}\p{M}]+$/u.test(key)) continue;
      const length = wordCount(key);
      if (length < 2) continue;
      next.add(key);
      limit = Math.max(limit, Math.min(32, length));
    }
    const same = next.size === phrases.size && [...next].every(key => phrases.has(key));
    phrases = next;
    phraseLimit = limit;
    return !same;
  }

  // Apply a change locally until the next snapshot arrives.
  function setLocal(key, state) {
    if (!snapshot) return;
    if (state) snapshot.expressions[key] = state;
    else delete snapshot.expressions[key];
    const length = wordCount(key);
    if (length > 1 && !phrases.has(key)) {
      phrases.add(key);
      phraseLimit = Math.max(phraseLimit, Math.min(32, length));
      redrawAll();
    } else restate();
  }

  // Ask the pack for the dictionary forms of words the snapshot doesn't list.
  function resolveForms() {
    if (!dictionary || formsRequest || !snapshot || Date.now() < formsRetryAt) return formsRequest;
    const words = [];
    for (const word of occurrences()) {
      if (word.phrase || Object.hasOwn(snapshot.expressions, word.key) || forms.has(word.key) || asked.has(word.key)) continue;
      asked.add(word.key);
      words.push(word.key);
      if (words.length >= 20000) break;
    }
    if (!words.length) return null;
    const requested = session;
    formsRequest = send('Forms', { words }).then(result => {
      if (requested !== session) return;
      for (const word of words) forms.set(word, model.formsIn(result, word));
      formsRequest = null;
      formsBackoff = 0;
      if (!mode) return;
      restate();
      return resolveForms();
    }, () => {
      // Until a later refresh succeeds, Reading Mode matches exact spellings only.
      if (requested !== session) return;
      for (const word of words) asked.delete(word);
      formsRequest = null;
      formsBackoff = Math.min(formsBackoff * 2 || 30000, 300000);
      formsRetryAt = Date.now() + formsBackoff;
    });
    return formsRequest;
  }

  function lemmaFor(key, options) {
    if (options?.lemma) return options.lemma;
    const resolved = forms.get(key);
    return resolved?.length === 1 ? resolved[0] : undefined;
  }

  function updateBadge() {
    if (!summary) return;
    const result = model.coverage(occurrences());
    const parts = [`Reading · ${languageName}`];
    if (result.percent !== null) parts.push(`${result.percent}% known`, `${result.newWords.toLocaleString()} new`);
    if (offline) parts.push('NeoAnki2 is not running — showing saved words');
    summary.textContent = parts.join(' · ');
    restButton.disabled = offline || !result.newWords || Boolean(selection?.pending);
  }

  function groupOffset(group, node, offset) {
    if (node.nodeType !== Node.TEXT_NODE) return undefined;
    const part = group.parts.find(value => value.node === node);
    return part ? part.start + offset : undefined;
  }

  function captureFrom(range) {
    const group = groups.get(range.startContainer);
    const expression = range.toString().trim();
    if (!expression || expression.length > 250) return null;
    const start = group && groupOffset(group, range.startContainer, range.startOffset);
    const end = group && groupOffset(group, range.endContainer, range.endOffset);
    const context = start !== undefined && end !== undefined
      ? Array.from(sentenceSegmenter.segment(group.text)).find(value => start >= value.index && end <= value.index + value.segment.length)
      : null;
    const sentence = context?.segment?.trim() || '';
    let occurrence = 0;
    if (context) {
      const prefix = context.segment.slice(0, start - context.index).toLocaleLowerCase(mode.language);
      const sought = expression.toLocaleLowerCase(mode.language);
      const starts = new Set(Array.from(wordSegmenter.segment(prefix), part => part.index));
      for (let match = prefix.indexOf(sought); match >= 0; match = prefix.indexOf(sought, match + sought.length)) {
        if (starts.has(match) && (match + sought.length === prefix.length || starts.has(match + sought.length))) occurrence++;
      }
    }
    return { expression, sentence, occurrence, rect: range.getBoundingClientRect() };
  }

  // Click an underlined word to open it. Known and ignored words open with Option/Alt-click,
  // so an ordinary click on them still selects text.
  function findSelection(event) {
    if (!event.isTrusted || !mode || !snapshot || host?.contains(event.target) || event.composedPath().includes(host)
      || event.target.closest?.(excluded)) return;
    const picked = document.getSelection();
    if (picked && !picked.isCollapsed && picked.rangeCount > 0) {
      const capture = captureFrom(picked.getRangeAt(0));
      if (capture) void open(capture);
      return;
    }
    if (event.type !== 'pointerup' || event.button !== 0) return;
    const caret = document.caretRangeFromPoint(event.clientX, event.clientY);
    const hit = caret && positions.get(caret.startContainer)?.find(value =>
      caret.startOffset >= value.lower && caret.startOffset <= value.upper
      && Array.from(value.word.range.getClientRects()).some(rect => event.clientX >= rect.left
        && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom));
    const quiet = hit && ['known', 'ignored'].includes(hit.word.state);
    if (hit && (!quiet || event.altKey)) {
      const capture = captureFrom(hit.word.range);
      if (capture) void open(capture);
    } else { close(); }
  }

  function node(tag, text, parent, attributes = {}) {
    const element = document.createElement(tag);
    if (text) element.textContent = text;
    for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
    parent.append(element);
    return element;
  }

  function button(parent, title, action) {
    const control = node('button', title, parent, { type: 'button' });
    control.addEventListener('click', action);
    return control;
  }

  function errorText(error) {
    clearTimeout(statusTimer);
    if (live) live.textContent = error.message;
  }

  function announce(message) {
    clearTimeout(statusTimer);
    if (!live) return;
    live.textContent = message;
    statusTimer = setTimeout(() => { if (live) live.textContent = ''; }, 4000);
  }

  // Cheap when nothing changed: the worker answers from its cache after a one-line check.
  async function refresh() {
    const generation = ++refreshGeneration;
    clearTimeout(refreshTimer);
    try {
      const result = await send('Snapshot', { since: snapshot?.version });
      if (!mode || generation !== refreshGeneration) return;
      lastDeck = result.lastDeck;
      offline = result.offline;
      dictionary = result.dictionary;
      if (!result.unchanged) {
        const fresh = result.snapshot;
        snapshot = { ...fresh, expressions: model.record(fresh.expressions), lemmas: model.record(fresh.lemmas) };
        if (updatePhrases() || !root) redrawAll();
        else restate();
      } else updateBadge();
      if (rootMoved()) schedule();
      void resolveForms();
    } catch (error) {
      if (!mode || generation !== refreshGeneration) return;
      errorText(error);
    }
  }

  function refreshSoon() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(refresh, 1500);
  }

  function close(restoreFocus = false) {
    if (!shown || (restoreFocus && selection?.pending)) return;
    const before = selection?.focus;
    panel.hidden = true;
    selection = undefined;
    shown = false;
    updateBadge();
    if (restoreFocus) before?.focus?.({ preventScroll: true });
  }

  function touch(text) {
    touched.add(keyOf(text));
    for (const part of wordSegmenter.segment(text)) if (part.isWordLike) touched.add(keyOf(part.segment));
  }

  async function open(capture) {
    if (selection?.pending) return;
    live.textContent = '';
    touch(capture.expression);
    const picked = { ...capture, match: keyOf(capture.expression), focus: document.activeElement, session,
      undo: undefined, options: null, rows: null, pending: false, key: crypto.randomUUID() };
    selection = picked;
    shown = true;
    panel.hidden = false;
    renderPanel();
    const [options, rows] = await Promise.allSettled([
      send('Options', { expression: picked.expression }), send('Details', { expression: picked.expression }),
    ]);
    if (selection !== picked) return;
    picked.options = options.status === 'fulfilled' ? options.value : { decks: [], meanings: [] };
    picked.rows = rows.status === 'fulfilled' ? rows.value : [];
    if (rows.status === 'fulfilled') applyRows(picked);
    if (!picked.composing) renderPanel();
    const failure = [options, rows].find(result => result.status === 'rejected');
    if (failure) errorText(failure.reason);
  }

  // The rows' combined state is the truth for this spelling; correct the page if it differs.
  function applyRows(picked) {
    if (!current(picked)) return;
    const state = picked.rows.find(row => row.expressionState)?.expressionState;
    if (state !== model.lookup(snapshot.expressions, picked.match)) setLocal(picked.match, state);
  }

  function positionPanel() {
    if (!selection) return;
    const { rect } = selection;
    const width = panel.offsetWidth;
    const height = panel.offsetHeight;
    const top = rect.bottom + height + 8 <= innerHeight ? rect.bottom + 8 : rect.top - height - 8;
    panel.style.left = Math.max(8, Math.min(rect.left, innerWidth - width - 8)) + 'px';
    panel.style.top = Math.max(8, Math.min(top, innerHeight - height - 8)) + 'px';
  }

  function renderPanel({ focus = false } = {}) {
    const picked = selection;
    if (!picked) return;
    if (picked.kind === 'rest') { renderRest(focus); return; }
    panel.replaceChildren();
    const termLine = node('div', '', panel, { class: 'top' });
    node('strong', picked.expression, termLine, { id: 'word', lang: mode.language });
    button(termLine, 'Close', () => close(true));
    const meanings = picked.options?.meanings || [];
    if (meanings.length > 1) {
      const label = node('label', 'Meaning', panel);
      const choices = node('select', '', label);
      choices.add(new Option('Choose the meaning', ''));
      for (const [index, gloss] of meanings.entries()) choices.add(new Option(gloss.meaning, String(index)));
      if (picked.choice !== undefined) choices.value = String(picked.choice);
      choices.addEventListener('change', () => {
        picked.choice = choices.value === '' ? undefined : Number(choices.value);
        renderPanel({ focus: true });
        panel.querySelector('select')?.focus();
      });
    }
    const info = model.describe(picked.rows || [], stateOf(picked.match));
    node('div', [info.label, picked.rows && info.detail].filter(Boolean).join(' — '), panel, { class: 'status' });
    if (info.clozeMature) node('div', 'Cloze recall', panel);
    const actions = node('div', '', panel, { class: 'actions' });
    const ready = Boolean(picked.options && picked.rows) && !picked.pending;
    const known = info.state === 'known';
    // Reading judgments apply to the word as a whole; a meaning is needed only for a card set.
    const mark = button(actions, known ? 'Remove from Known' : 'I know this', () => {
      void judge(known ? 'unfamiliar' : 'known', info.previous);
    });
    mark.disabled = !ready;
    if (info.state !== 'ignored') button(actions, 'Ignore', () => { void judge('ignored', info.previous); }).disabled = !ready;
    if (picked.undo) button(actions, 'Undo', () => { void judge(picked.undo); }).disabled = picked.pending;
    if (info.explicit) button(actions, 'Use review history', () => { void judge('reviewHistory', info.previous); }).disabled = !ready;
    const unresolved = meanings.length > 1 && picked.choice === undefined;
    button(actions, 'Create card set', () => { void showComposer(); }).disabled = !ready || unresolved;
    if (unresolved) node('p', 'Choose a meaning to create a card set.', panel, { class: 'hint' });
    positionPanel();
    if (focus) mark.focus();
  }

  function termOf(picked, sense) {
    const lemma = lemmaFor(picked.match, picked.options);
    return { expression: picked.expression, ...(sense ? { sense } : {}), ...(lemma ? { lemma } : {}) };
  }

  const judged = {
    known: expression => `${expression} marked as known.`,
    unfamiliar: expression => `${expression} removed from Known.`,
    ignored: expression => `${expression} will be ignored.`,
    reviewHistory: expression => `${expression} now follows your reviews.`,
  };

  async function judge(judgment, previous) {
    const picked = selection;
    if (!picked || picked.pending) return;
    const key = picked.retryJudgment?.judgment === judgment ? picked.retryJudgment.key : crypto.randomUUID();
    picked.retryJudgment = { judgment, key };
    picked.pending = true;
    try {
      await send('Judge', { term: termOf(picked), judgment, key });
      picked.retryJudgment = undefined;
      picked.undo = previous;
      announce(judged[judgment](picked.expression));
      try {
        picked.rows = await send('Details', { expression: picked.expression });
        applyRows(picked);
      } catch {
        if (current(picked)) setLocal(picked.match, judgment === 'reviewHistory' ? undefined : judgment);
      }
      refreshSoon();
    } catch (error) { errorText(error); }
    finally {
      picked.pending = false;
      if (selection === picked) renderPanel({ focus: true });
    }
  }

  // "Mark the rest as known": every unassessed word on the page that you didn't open.
  async function offerRest() {
    if (selection?.pending || !snapshot) return;
    const picked = { kind: 'rest', rect: restButton.getBoundingClientRect(), focus: document.activeElement, pending: true, session };
    selection = picked;
    shown = true;
    panel.hidden = false;
    renderPanel();
    while (work());
    // Wait for dictionary forms, which may show that a word is already known or being learned.
    while (formsRequest) await formsRequest;
    if (selection !== picked) return;
    const lower = text => text.toLocaleLowerCase(mode.language);
    const words = new Map();
    const opened = word => touched.has(word.key) || forms.get(word.key)?.some(form => touched.has(keyOf(form)));
    for (const word of occurrences()) {
      if (word.phrase || word.state !== 'unassessed' || opened(word)) continue;
      const prior = words.get(word.key);
      if (!prior || (prior !== lower(prior) && word.text === lower(word.text))) words.set(word.key, word.text);
    }
    picked.entries = Array.from(words, ([key, expression]) => {
      const lemma = lemmaFor(key);
      return { key, term: { expression, ...(lemma ? { lemma } : {}) }, judgment: 'known' };
    });
    picked.keys = model.chunks(picked.entries).map(() => crypto.randomUUID());
    picked.pending = false;
    renderPanel({ focus: true });
  }

  function renderRest(focus) {
    const picked = selection;
    panel.replaceChildren();
    const top = node('div', '', panel, { class: 'top' });
    node('strong', 'Mark the rest as known', top);
    button(top, 'Close', () => close(true));
    let primary;
    const actions = () => node('div', '', panel, { class: 'actions' });
    if (!picked.entries) {
      node('p', 'Collecting the words on this page…', panel, { class: 'status' });
    } else if (picked.receipt) {
      const count = picked.receipt.recorded;
      node('p', `Marked ${count.toLocaleString()} ${count === 1 ? 'word' : 'words'} as known.`, panel, { class: 'status' });
      primary = button(actions(), 'Undo', () => { void undoRest(); });
      primary.disabled = picked.pending;
    } else if (!picked.entries.length) {
      node('p', 'Every word on this page already has a status, or you opened it.', panel, { class: 'status' });
    } else {
      const count = picked.entries.length;
      node('p', `Mark ${count.toLocaleString()} ${count === 1 ? 'word' : 'words'} on this page as known?`, panel, { class: 'status' });
      const sample = picked.entries.slice(0, sampleSize).map(entry => entry.term.expression).join(', ');
      node('p', sample + (count > sampleSize ? ', …' : ''), panel, { class: 'sample', lang: mode.language });
      node('p', 'Words you opened here, words you’re learning, and words marked not known or ignored are left out.', panel, { class: 'hint' });
      const row = actions();
      primary = button(row, 'Mark as known', () => { void markRest(); });
      primary.disabled = picked.pending;
      button(row, 'Cancel', () => close(true)).disabled = picked.pending;
    }
    positionPanel();
    if (focus) primary?.focus();
  }

  async function markRest() {
    const picked = selection;
    if (picked?.kind !== 'rest' || picked.pending) return;
    picked.pending = true;
    renderPanel();
    // The states to restore on Undo, read before the batch can change them (a retry keeps the first).
    picked.previous ||= new Map(picked.entries.map(entry => [entry.key, model.lookup(snapshot.expressions, entry.key)]));
    try {
      const receipt = await send('Batch', { entries: picked.entries.map(({ term, judgment }) => ({ term, judgment })), keys: picked.keys });
      picked.receipt = receipt;
      picked.undoKeys = receipt.batchIds.map(() => crypto.randomUUID());
      if (!current(picked)) return;
      for (const entry of picked.entries) snapshot.expressions[entry.key] = 'known';
      restate();
      refreshSoon();
      announce(`Marked ${receipt.recorded.toLocaleString()} words as known.`);
    } catch (error) { errorText(error); }
    finally {
      picked.pending = false;
      if (selection === picked) renderPanel({ focus: true });
    }
  }

  async function undoRest() {
    const picked = selection;
    if (!picked?.receipt || picked.pending) return;
    picked.pending = true;
    renderPanel();
    try {
      await send('UndoBatches', { batchIds: picked.receipt.batchIds, keys: picked.undoKeys });
      if (!current(picked)) return;
      for (const [key, state] of picked.previous) {
        if (state) snapshot.expressions[key] = state;
        else delete snapshot.expressions[key];
      }
      restate();
      refreshSoon();
      announce('Undone. Those words are unassessed again.');
      picked.pending = false;
      close(true);
    } catch (error) { errorText(error); }
    finally {
      picked.pending = false;
      if (selection === picked) renderPanel({ focus: true });
    }
  }

  async function showComposer() {
    const picked = selection;
    if (!picked || picked.pending) return;
    picked.composing = true;
    panel.replaceChildren();
    const top = node('div', '', panel, { class: 'top' });
    node('strong', 'Create card set', top);
    const back = button(top, 'Back', () => { picked.composing = false; renderPanel(); });
    const form = node('form', '', panel);
    const gloss = picked.options?.meanings?.[picked.choice ?? 0];
    const meaning = node('input', '', node('label', 'Meaning', form), { required: '', maxlength: '1000' });
    const meaningLanguage = node('input', '', node('label', 'Meaning language', form), { required: '' });
    const sentence = node('textarea', '', node('label', 'Example sentence', form), { rows: '3', required: '', maxlength: '2000' });
    const deck = node('select', '', node('label', 'Deck', form));
    deck.add(new Option('Unassigned', ''));
    for (const value of picked.options?.decks || []) deck.add(new Option(value.name, value.id));
    deck.value = lastDeck;
    meaning.value = gloss?.meaning || '';
    meaningLanguage.value = gloss?.language || mode.meaningLanguage;
    sentence.value = picked.sentence || gloss?.example || '';
    const preview = node('p', '', form, { class: 'status', 'aria-live': 'polite' });
    node('button', 'Create card set', form, { type: 'submit', class: 'primary' });
    let useDictionaryExample;
    if (gloss?.form && gloss.example && keyOf(gloss.example) !== keyOf(picked.sentence)) {
      const alternate = node('label', '', form, { class: 'alternate' });
      useDictionaryExample = node('input', '', alternate, { type: 'checkbox' });
      useDictionaryExample.checked = true;
      alternate.append('Use dictionary example for Cloze');
    }
    const secondExample = () => useDictionaryExample?.checked ? gloss : null;
    const previewText = () => {
      const second = secondExample();
      const text = second?.example || sentence.value;
      const target = second?.form || picked.expression;
      const index = text.toLowerCase().indexOf(target.toLowerCase());
      preview.textContent = index < 0 ? 'Use an example containing the selected word or phrase.'
        : `Cloze preview: ${text.slice(0, index)}[…]${text.slice(index + target.length)}`;
    };
    previewText();
    for (const field of [meaning, meaningLanguage, sentence, deck, useDictionaryExample].filter(Boolean)) field.addEventListener('input', () => {
      picked.key = crypto.randomUUID();
      previewText();
    });
    form.addEventListener('submit', async event => {
      event.preventDefault();
      if (picked.pending) return;
      picked.pending = true;
      const second = secondExample();
      const sense = picked.choice === undefined ? undefined : picked.options.meanings[picked.choice].meaning;
      const draft = { term: termOf(picked, sense), meaning: meaning.value, meaningLanguage: meaningLanguage.value,
        sentence: sentence.value, occurrence: sentence.value === picked.sentence ? picked.occurrence : 0,
        deckID: deck.value, productionSentence: second?.example, productionForm: second?.form };
      back.disabled = true;
      for (const field of form.elements) field.disabled = true;
      try {
        await send('Create', { draft, key: picked.key });
        lastDeck = draft.deckID;
        await refresh();
        announce('Vocabulary card set added.');
        picked.pending = false;
        if (selection === picked) close(true);
      } catch (error) { errorText(error); }
      finally {
        picked.pending = false;
        back.disabled = false;
        for (const field of form.elements) field.disabled = false;
      }
    });
    positionPanel();
    meaning.focus();
  }

  function start(next) {
    if (mode) { void refresh(); return; }
    mode = next;
    wordSegmenter = new Intl.Segmenter(mode.language, { granularity: 'word' });
    sentenceSegmenter = new Intl.Segmenter(mode.language, { granularity: 'sentence' });
    host = document.createElement('div');
    const shadow = host.attachShadow({ mode: 'closed' });
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`
      :host { all: initial; color-scheme: light dark; }
      div, section, p, label, button, input, select, textarea { box-sizing: border-box; }
      #badge, section, output { position: fixed; z-index: 2147483647; font: 14px system-ui; color: CanvasText; background: Canvas; }
      #badge { right: 12px; top: 12px; max-width: min(460px, calc(100vw - 24px)); display: flex; flex-wrap: wrap; gap: 6px; align-items: center; padding: 7px 9px; border: 1px solid GrayText; border-radius: 7px; }
      section { width: min(340px, calc(100vw - 16px)); max-height: min(72vh, 460px); overflow: auto; padding: 14px; border: 1px solid GrayText; border-radius: 10px; box-shadow: 0 6px 24px #0003; }
      section[hidden], output:empty { display: none; }
      .top, .actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
      .top { justify-content: space-between; overflow-wrap: anywhere; }
      .status { margin-block: 8px; line-height: 1.4; white-space: pre-wrap; }
      .sample { line-height: 1.4; overflow-wrap: anywhere; }
      .hint { color: GrayText; font-size: 12px; line-height: 1.4; }
      button, input, select, textarea { font: inherit; color: inherit; }
      button { padding: 4px 8px; min-height: 30px; cursor: pointer; }
      button:disabled { cursor: default; }
      label { display: block; margin-block: 9px; }
      .alternate { display: flex; align-items: center; gap: 6px; }
      .alternate input { margin: 0; width: auto; }
      input, select, textarea { display: block; width: 100%; margin-top: 3px; }
      output { right: 12px; bottom: 12px; padding: 8px 12px; border: 1px solid GrayText; border-radius: 7px; max-width: min(360px, calc(100vw - 24px)); }
    `);
    shadow.adoptedStyleSheets = [sheet];
    languageName = new Intl.DisplayNames([navigator.language], { type: 'language' }).of(mode.language);
    const badge = node('div', '', shadow, { id: 'badge' });
    summary = node('span', `Reading · ${languageName}`, badge);
    restButton = button(badge, 'Mark the rest as known', () => { void offerRest(); });
    restButton.disabled = true;
    button(badge, 'Stop', async () => { try { await send('Stop'); } catch (error) { errorText(error); } });
    panel = node('section', '', shadow, { role: 'dialog', 'aria-label': 'Vocabulary', hidden: '' });
    live = node('output', '', shadow, { role: 'status' });
    document.documentElement.append(host);
    for (const state of underlined) {
      highlights[state] = new Highlight();
      CSS.highlights.set(`neoanki-${state}`, highlights[state]);
    }
    document.addEventListener('pointerup', findSelection);
    document.addEventListener('keyup', keyboard);
    window.addEventListener('focus', refresh);
    observer = new MutationObserver(changed);
    observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true,
      attributeOldValue: true, attributeFilter: ['hidden', 'class', 'style', 'open', 'aria-hidden'] });
    void refresh();
  }

  function keyboard(event) {
    if (event.key === 'Escape') close(true);
    if (event.shiftKey && (event.key.startsWith('Arrow') || event.key === 'Home' || event.key === 'End')) findSelection(event);
  }

  // Leaves nothing from this session behind: a later start, perhaps in another language, begins
  // fresh, and no Range keeps the page's nodes alive.
  function stop() {
    close();
    mode = undefined;
    snapshot = undefined;
    root = undefined;
    stale = undefined;
    refreshGeneration++;
    session++;
    clearTimeout(timer);
    clearTimeout(refreshTimer);
    clearTimeout(statusTimer);
    timer = refreshTimer = statusTimer = undefined;
    observer?.disconnect();
    observer = undefined;
    document.removeEventListener('pointerup', findSelection);
    document.removeEventListener('keyup', keyboard);
    window.removeEventListener('focus', refresh);
    for (const state of underlined) CSS.highlights?.delete(`neoanki-${state}`);
    highlights = {};
    blockData.clear();
    pending.clear();
    dirty.clear();
    forms.clear();
    asked.clear();
    touched.clear();
    positions = new WeakMap();
    groups = new WeakMap();
    phrases = new Set();
    phraseLimit = 1;
    layout = 0;
    restyled = false;
    lastDeck = '';
    offline = dictionary = false;
    formsRequest = null;
    formsRetryAt = formsBackoff = 0;
    selection = undefined;
    shown = false;
    host?.remove();
    host = panel = live = summary = restButton = undefined;
    wordSegmenter = sentenceSegmenter = languageName = undefined;
  }

  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.type === 'neoankiReadingStart') { start(message.mode); respond(true); }
    if (message.type === 'neoankiReadingStop') { stop(); respond(true); }
  });
})();
