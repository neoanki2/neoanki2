(() => {
  if (globalThis.neoankiReadingInstalled) return;
  globalThis.neoankiReadingInstalled = true;

  const excluded = 'a,button,input,textarea,select,[contenteditable]:not([contenteditable="false"]),nav,script,style,noscript,svg,code,pre,[aria-hidden="true"],[hidden]';
  const blocks = 'p,li,td,dd,dt,blockquote,h1,h2,h3,h4,h5,h6,article,section,div,main,body';
  const normalize = value => value.normalize('NFC').toLowerCase().trim().replace(/\s+/gu, ' ');
  const send = async (action, data) => {
    const reply = await chrome.runtime.sendMessage({ type: `neoankiReading${action}`, ...data });
    if (reply?.error) throw Object.assign(new Error(reply.error), { status: reply.status });
    return reply?.value;
  };

  let mode, host, panel, live, observer, timer, statusTimer, wordSegmenter, sentenceSegmenter, selection;
  let rows = [], lastDeck = '', positions = new WeakMap(), groups = new WeakMap();
  let availability = false, refreshGeneration = 0, shown = false;

  function rangesFor(root) {
    const byBlock = new Map();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const parent = node.parentElement;
      if (!parent || !node.data || parent.closest(excluded)) continue;
      const declared = parent.closest('[lang]');
      if (declared && declared !== document.documentElement
          && declared.lang.toLowerCase().split('-')[0] !== mode.language.split('-')[0]) continue;
      if (!parent.getClientRects().length || getComputedStyle(parent).visibility === 'hidden') continue;
      const block = parent.closest(blocks) || root;
      const group = byBlock.get(block) || { text: '', parts: [] };
      group.parts.push({ node, start: group.text.length });
      group.text += node.data;
      byBlock.set(block, group);
      groups.set(node, group);
    }
    return byBlock.values();
  }

  function point(group, offset, end = false) {
    const part = group.parts.find(value => offset < value.start + value.node.length
      || (end && offset === value.start + value.node.length)) || group.parts.at(-1);
    return [part.node, Math.max(0, Math.min(part.node.length, offset - part.start))];
  }

  function makeRange(group, start, end) {
    const range = document.createRange();
    range.setStart(...point(group, start));
    range.setEnd(...point(group, end, true));
    return range;
  }

  function wordState(candidates) {
    const unqualified = candidates.find(row => !row.term.sense);
    if (!unqualified || candidates.length > 1) return 'unassessed';
    if (unqualified.judgment === 'known' || (unqualified.judgment !== 'unfamiliar' && unqualified.readingMature)) return 'known';
    return unqualified.hasCards ? 'learning' : 'unassessed';
  }

  function redraw() {
    clearTimeout(timer);
    timer = undefined;
    if (!mode || !availability) return;
    groups = new WeakMap();
    positions = new WeakMap();
    const body = document.querySelector('main, [role="main"]') || document.querySelector('article') || document.body;
    if (!body) return;
    const unassessed = new Highlight();
    const learning = new Highlight();
    const classifications = new Map();
    for (const row of rows) {
      const key = normalize(row.term.expression);
      const candidates = classifications.get(key) || [];
      candidates.push(row);
      classifications.set(key, candidates);
    }
    const tracked = new Map();
    let phraseLimit = 1;
    for (const [term, candidates] of classifications) {
      tracked.set(term, wordState(candidates));
      const length = Array.from(wordSegmenter.segment(term)).filter(segment => segment.isWordLike).length;
      phraseLimit = Math.max(phraseLimit, Math.min(32, length));
    }
    for (const group of rangesFor(body)) {
      const words = Array.from(wordSegmenter.segment(group.text)).filter(segment => segment.isWordLike);
      for (let index = 0; index < words.length; index++) {
        const first = words[index];
        let last = first;
        for (let candidate = Math.min(words.length - 1, index + phraseLimit - 1); candidate > index; candidate--) {
          const tail = words[candidate];
          if (tracked.has(normalize(group.text.slice(first.index, tail.index + tail.segment.length)))) {
            last = tail;
            index = candidate;
            break;
          }
        }
        const end = last.index + last.segment.length;
        const value = group.text.slice(first.index, end);
        const state = tracked.get(normalize(value)) || 'unassessed';
        const range = makeRange(group, first.index, end);
        if (state === 'learning') learning.add(range);
        if (state === 'unassessed') unassessed.add(range);
        if (state !== 'known') {
          for (const part of group.parts) {
            if (part.start >= end || part.start + part.node.length <= first.index) continue;
            const hits = positions.get(part.node) || [];
            hits.push({ group, start: first.index, end, range, lower: Math.max(0, first.index - part.start),
              upper: Math.min(part.node.length, end - part.start) });
            positions.set(part.node, hits);
          }
        }
      }
    }
    CSS.highlights.set('neoanki-unassessed', unassessed);
    CSS.highlights.set('neoanki-learning', learning);
  }

  function redrawSoon() {
    if (!timer) timer = setTimeout(redraw, 120);
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

  function findSelection(event) {
    if (!event.isTrusted || !mode || host?.contains(event.target) || event.composedPath().includes(host)
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
      && Array.from(value.range.getClientRects()).some(rect => event.clientX >= rect.left
        && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom));
    if (hit) {
      const capture = captureFrom(hit.range);
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
    live.textContent = message;
    statusTimer = setTimeout(() => { if (live) live.textContent = ''; }, 4000);
  }

  async function refresh() {
    const generation = ++refreshGeneration;
    try {
      const result = await send('Snapshot');
      if (!mode || generation !== refreshGeneration) return;
      rows = result.rows;
      lastDeck = result.lastDeck;
      availability = true;
      redrawSoon();
    } catch (error) {
      if (!mode || generation !== refreshGeneration) return;
      errorText(error);
      if (!availability) live.textContent = error.message;
    }
  }

  function close(restoreFocus = false) {
    if (!shown || (restoreFocus && selection?.pending)) return;
    const before = selection?.focus;
    panel.hidden = true;
    selection = undefined;
    shown = false;
    if (restoreFocus) before?.focus?.({ preventScroll: true });
  }

  function currentRow(term) {
    return rows.find(row => normalize(row.term.expression) === normalize(term.expression)
      && normalize(row.term.sense || '') === normalize(term.sense || ''));
  }

  function effectiveKnown(row) {
    return row?.judgment === 'known' || (row?.judgment !== 'unfamiliar' && row?.readingMature === true);
  }

  async function open(capture) {
    if (selection?.pending) return;
    live.textContent = '';
    const picked = { ...capture, term: { expression: capture.expression }, focus: document.activeElement,
      undo: undefined, options: null, pending: false, key: crypto.randomUUID() };
    selection = picked;
    shown = true;
    panel.hidden = false;
    renderPanel();
    try {
      picked.options = await send('Options', { expression: picked.expression });
      if (selection === picked && !picked.composing) renderPanel();
    } catch (error) {
      if (selection === picked) {
        picked.options = { decks: [], meanings: [] };
        renderPanel();
        errorText(error);
      }
    }
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
        picked.term = { expression: picked.expression,
          ...(picked.choice === undefined ? {} : { sense: meanings[picked.choice].meaning }) };
        renderPanel({ focus: true });
        panel.querySelector('select')?.focus();
      });
    }
    const row = currentRow(picked.term);
    node('div', effectiveKnown(row) ? 'Known' : row?.hasCards ? 'Learning' : 'Unassessed', panel, { class: 'status' });
    if (row?.clozeMature) node('div', 'Cloze recall', panel);
    const actions = node('div', '', panel, { class: 'actions' });
    const unresolved = meanings.length > 1 && picked.choice === undefined;
    const mark = button(actions, effectiveKnown(row) ? 'Remove from Known' : 'I know this', () => {
      const previous = row?.judgment || 'reviewHistory';
      void judge(effectiveKnown(row) ? 'unfamiliar' : 'known', previous);
    });
    mark.disabled = !picked.options || unresolved || picked.pending;
    if (picked.undo) button(actions, 'Undo', () => { void judge(picked.undo); });
    if (row?.judgment === 'unfamiliar' || row?.judgment === 'known') {
      button(actions, 'Use review history', () => { void judge('reviewHistory', row.judgment); });
    }
    button(actions, 'Create card set', () => { void showComposer(); }).disabled = !picked.options || unresolved || picked.pending;
    positionPanel();
    if (focus) mark.focus();
  }

  async function judge(judgment, previous) {
    const picked = selection;
    if (!picked || picked.pending) return;
    const key = picked.retryJudgment?.judgment === judgment ? picked.retryJudgment.key : crypto.randomUUID();
    picked.retryJudgment = { judgment, key };
    picked.pending = true;
    try {
      await send('Judge', { term: picked.term, judgment, key });
      picked.retryJudgment = undefined;
      picked.undo = previous;
      const row = currentRow(picked.term);
      if (row) row.judgment = judgment;
      else rows.push({ term: { ...picked.term, language: mode.language }, judgment });
      redrawSoon();
      announce(judgment === 'known' ? `${picked.expression} marked as known.` : 'Vocabulary judgment updated.');
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
    if (gloss?.form && gloss.example && normalize(gloss.example) !== normalize(picked.sentence)) {
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
      const draft = { term: picked.term, meaning: meaning.value, meaningLanguage: meaningLanguage.value,
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
      #badge { right: 12px; top: 12px; padding: 7px 9px; border: 1px solid GrayText; border-radius: 7px; }
      section { width: min(340px, calc(100vw - 16px)); max-height: min(72vh, 460px); overflow: auto; padding: 14px; border: 1px solid GrayText; border-radius: 10px; box-shadow: 0 6px 24px #0003; }
      section[hidden], output:empty { display: none; }
      .top, .actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
      .top { justify-content: space-between; overflow-wrap: anywhere; }
      .status { margin-block: 8px; line-height: 1.4; white-space: pre-wrap; }
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
    const names = new Intl.DisplayNames([navigator.language], { type: 'language' });
    const badge = node('div', `Reading · ${names.of(mode.language)} `, shadow, { id: 'badge' });
    button(badge, 'Stop', async () => { try { await send('Stop'); } catch (error) { errorText(error); } });
    panel = node('section', '', shadow, { role: 'dialog', 'aria-label': 'Vocabulary', hidden: '' });
    live = node('output', '', shadow, { role: 'status' });
    document.documentElement.append(host);
    document.addEventListener('pointerup', findSelection);
    document.addEventListener('keyup', keyboard);
    window.addEventListener('focus', refresh);
    observer = new MutationObserver(redrawSoon);
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    void refresh();
  }

  function keyboard(event) {
    if (event.key === 'Escape') close(true);
    if (event.shiftKey && (event.key.startsWith('Arrow') || event.key === 'Home' || event.key === 'End')) findSelection(event);
  }

  function stop() {
    mode = undefined;
    availability = false;
    refreshGeneration++;
    clearTimeout(timer);
    clearTimeout(statusTimer);
    timer = undefined;
    observer?.disconnect();
    document.removeEventListener('pointerup', findSelection);
    document.removeEventListener('keyup', keyboard);
    window.removeEventListener('focus', refresh);
    CSS.highlights?.delete('neoanki-unassessed');
    CSS.highlights?.delete('neoanki-learning');
    close();
    host?.remove();
    host = undefined;
  }

  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.type === 'neoankiReadingStart') { start(message.mode); respond(true); }
    if (message.type === 'neoankiReadingStop') { stop(); respond(true); }
  });
})();
