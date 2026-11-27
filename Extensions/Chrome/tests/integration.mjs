import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const extensionPath = fileURLToPath(new URL('..', import.meta.url));
const repo = path.resolve(extensionPath, '../..');
const results = path.join(extensionPath, 'test-results');
await mkdir(results, { recursive: true });
execFileSync('swift', ['build', '--product', 'neoanki-chrome-fixture'], { cwd: repo, stdio: 'inherit' });
const bin = execFileSync('swift', ['build', '--show-bin-path'], { cwd: repo, encoding: 'utf8' }).trim();
const temporary = await mkdtemp(path.join(os.tmpdir(), 'neoanki-chrome-'));
const root = path.join(temporary, 'neoanki-chrome-api');
await mkdir(root);
const portProbe = net.createServer();
portProbe.listen(0, '127.0.0.1');
await once(portProbe, 'listening');
const port = portProbe.address().port;
await new Promise(resolve => portProbe.close(resolve));
const base = `http://127.0.0.1:${port}`;
let fixture, context, sourceServer;
const failures = [];
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const bulkWords = ('pathway footbridge marketplace hedgerow courtyard neighborhood bookstore lamppost intersection ' +
  'playground observatory riverside allotment cobblestone greenhouse watershed fountain footpath underpass promenade ' +
  'boardwalk waterfront boulevard embankment pedestrian roundabout commuter bicycle garden wetland evergreen').split(' ');
try {
  fixture = spawn(path.join(bin, 'neoanki-chrome-fixture'), ['--test-fixture', String(port), root], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', errors = '';
  fixture.stderr.on('data', bytes => { errors += bytes.toString(); });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Fixture did not become ready. ${errors}`)), 30000);
    fixture.once('exit', code => { clearTimeout(timer); reject(new Error(`Fixture exited (${code}). ${errors}`)); });
    fixture.stdout.on('data', bytes => {
      output += bytes.toString();
      if (output.includes('CHROME_FIXTURE_READY')) { clearTimeout(timer); resolve(); }
    });
  });
  sourceServer = http.createServer((request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(`<!doctype html><html lang="en"><title>Vocabulary reading</title><p id="word">serendipity</p><p id="unicode">їжак 🦔</p><p id="contextual">The novel revealed a <em>subtlety</em> she had missed.</p><p id="bank">bank</p><p id="name">Zorblax</p><p id="count">Chapter 42</p><p>${bulkWords.join(' ')}</p><p id="railing" lang="uk">Степан стояв за <em>поруччям</em> на палубі.</p><p id="sooty" lang="uk">На столі стояв <em>кіптявий</em> чайник.</p><p id="missing-word" lang="uk">Його огорнула <em>млость</em>.</p><p id="dictionary-only" lang="uk"><em>чередою</em>.</p><textarea id="input">selected phrase</textarea><button id="focus">Focus</button></html>`);
  });
  sourceServer.listen(0, '127.0.0.1'); await once(sourceServer, 'listening');
  const sourceURL = `http://127.0.0.1:${sourceServer.address().port}/watch?v=fixture`;
    context = await chromium.launchPersistentContext(path.join(temporary, 'profile'), {
    channel: 'chromium', headless: true,
    args: [`--disable-extensions-except=${extensionPath}`, `--load-extension=${extensionPath}`, '--enable-unsafe-extension-debugging'],
  });
  context.setDefaultTimeout(10000);
  // Fail closed: even a bad settings default must never contact the user's local API.
  await context.route('http://127.0.0.1/**', async route => {
    const requestOrigin = new URL(route.request().url()).origin;
    if (requestOrigin !== base && requestOrigin !== new URL(sourceURL).origin) {
      failures.push(`Blocked unexpected loopback destination: ${requestOrigin}`);
      await route.abort('blockedbyclient');
    } else await route.continue();
  });
  context.on('response', async response => {
    if (response.url().startsWith(base + '/v1/') && response.status() >= 400) {
      const problem = await response.json().catch(() => ({}));
      console.error('API problem:', response.request().method(), new URL(response.url()).pathname,
        response.status(), problem.code, problem.detail);
    }
  });
  context.on('page', page => page.on('pageerror', error => failures.push(error.message)));
  const browserCDP = await context.browser().newBrowserCDPSession();
  await browserCDP.send('Target.setDiscoverTargets', { discover: true, filter: [{}] });
  const extensions = await browserCDP.send('Extensions.getExtensions');
  const extension = extensions.extensions.find(value => value.name === 'NeoAnki2 Companion');
  assert.ok(extension, 'The unpacked extension loads in a real headless Chromium profile.');
  const origin = `chrome-extension://${extension.id}`;
  const settings = await context.newPage();
  await settings.goto(origin + '/settings.html');
  await settings.locator('#port').fill(String(port));
  await settings.locator('#connect').click();
  await settings.locator('#status').filter({ hasText: 'Connected.' }).waitFor();
  await settings.locator('#pack option[value="companion-fixture"]').waitFor({ state: 'attached' });
  assert.equal(await settings.locator('#pack').inputValue(), 'companion-fixture');

  const apiCall = (page, apiPath, options) => page.evaluate(async ({ apiPath, options }) => {
    const { makeAPI } = await import('./core.js');
    const { readState } = await import('./storage.js');
    return makeAPI((await readState()).config)(apiPath, options);
  }, { apiPath, options });
  const waitForStored = (page, key, property, expected) => page.evaluate(({ key, property, expected }) => new Promise((resolve, reject) => {
    const changed = (changes, area) => {
      if (area === 'local' && changes[key]) check(changes[key].newValue);
    };
    const timer = setTimeout(() => { cleanup(); reject(new Error(`Stored ${key}.${property} did not become ready.`)); }, 10000);
    function cleanup() { clearTimeout(timer); chrome.storage.onChanged.removeListener(changed); }
    function check(value) {
      if ((property === null ? value : value?.[property]) === expected) { cleanup(); resolve(); }
    }
    chrome.storage.onChanged.addListener(changed);
    chrome.storage.local.get(key).then(values => check(values[key])).catch(error => { cleanup(); reject(error); });
  }), { key, property, expected });
  const grant = await apiCall(settings, '/v1/clients/current');
  assert.equal(grant.origin, origin, 'Pairing binds the actual extension origin.');
  assert.deepEqual(grant.scopes.sort(), ['items.write', 'known-words.read', 'known-words.write', 'library.read', 'vocabulary.read']);
  console.log('PASS: real-origin pairing and authenticated dictionary/deck reads');

  const source = await context.newPage();
  await source.goto(sourceURL);
  const { targetInfos } = await browserCDP.send('Target.getTargets', { filter: [{ type: 'tab' }] });
  const targetInfo = targetInfos.find(target => target.url === sourceURL);
  assert.ok(targetInfo, `Source tab target missing: ${JSON.stringify(targetInfos.map(({ type, url }) => ({ type, url })))}`);
  let selectedText = '';
  async function select(selector) {
    await source.bringToFront();
    selectedText = await source.locator(selector).evaluate(element => {
      if (element.tagName === 'TEXTAREA') { element.focus(); element.setSelectionRange(0, 8); return element.value.slice(0, 8); }
      document.activeElement?.blur();
      const range = document.createRange(); range.selectNodeContents(element);
      window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
      return window.getSelection().toString();
    });
  }
  async function popup(ready = true) {
    const previous = await settings.evaluate(async () => (await chrome.storage.local.get('draft')).draft);
    await source.bringToFront();
    const targetReady = new Promise((resolve, reject) => {
      const changed = ({ targetInfo }) => {
        if (targetInfo.type === 'page' && targetInfo.url === origin + '/popup.html') {
          cleanup(); resolve(targetInfo);
        }
      };
      const timer = setTimeout(() => { cleanup(); reject(new Error('The toolbar action did not expose its popup target.')); }, 10000);
      function cleanup() {
        clearTimeout(timer);
        browserCDP.off('Target.targetCreated', changed);
        browserCDP.off('Target.targetInfoChanged', changed);
      }
      browserCDP.on('Target.targetCreated', changed);
      browserCDP.on('Target.targetInfoChanged', changed);
    });
    targetReady.catch(() => {});
    await browserCDP.send('Extensions.triggerAction', { id: extension.id, targetId: targetInfo.targetId });
    const actionPopup = await targetReady;
    // Action popups currently lack the browserContextId Playwright needs to
    // expose a Page. Observe their real activeTab capture in durable storage,
    // then drive the same unmodified popup document in a constrained normal tab.
    await waitForStored(settings, 'draft', 'front', previous?.front || previous?.back || previous?.pending ? previous.front : selectedText);
    await browserCDP.send('Target.closeTarget', { targetId: actionPopup.targetId });
    const page = await context.newPage();
    await page.setViewportSize({ width: 380, height: 600 });
    await page.goto(origin + '/popup.html');
    if (ready) await page.locator('#save:not(:disabled)').waitFor();
    return page;
  }
  async function discardStoredDraft() {
    await settings.evaluate(async () => {
      const { writeState } = await import('./storage.js');
      await writeState({ draft: null });
    });
  }
  await select('#word');
  assert.equal(selectedText, 'serendipity', 'The fixture has a real DOM selection before the toolbar invocation.');
  let card = await popup();
  assert.equal(await card.locator('#front').inputValue(), 'serendipity');
  await card.waitForFunction(() => document.getElementById('back').value.includes('Finding something good by chance.'));
  assert.match(await card.locator('#back').inputValue(), /ˌserənˈdɪpəti/);
  const deckId = await card.locator('#deck option').nth(1).getAttribute('value');
  await card.locator('#deck').selectOption(deckId);
  await card.screenshot({ path: path.join(results, 'popup-light.png') });
  await card.emulateMedia({ colorScheme: 'dark' });
  await card.screenshot({ path: path.join(results, 'popup-dark.png') });
  await card.locator('#save').click();
  await card.locator('#status').filter({ hasText: 'Card saved' }).waitFor();
  assert.equal(await card.evaluate(async () => (await chrome.storage.local.get('draft')).draft.source.url), sourceURL,
    'The same popup retains its source for another manually entered card.');
  let items = (await apiCall(settings, '/v1/items?limit=200')).data;
  assert.equal(items.length, 1);
  assert.equal(items[0].deckId, deckId);
  assert.equal(items[0].cardIds.length, 1);
  assert.ok(items[0].fields.some(field => field.value.text?.includes(`Source: Vocabulary reading\n${sourceURL}`)));
  const studyCard = await apiCall(settings, `/v1/cards/${items[0].cardIds[0]}`);
  assert.equal(studyCard.itemId, items[0].id);
  assert.equal(studyCard.isSuspended, false);
  await card.close();
  console.log('PASS: toolbar activeTab gesture → selected text → offline dictionary → one studyable card with source');

  await select('#unicode'); card = await popup();
  assert.equal(await card.locator('#front').inputValue(), 'їжак 🦔');
  assert.equal(await card.locator('#deck').inputValue(), deckId, 'Last deck is remembered.');
  await card.waitForFunction(() => document.getElementById('back').value.includes('A hedgehog.'));
  await card.locator('#back').fill('My own translation 🦔');
  // Wait for the observable storage write before destroying the popup.
  await waitForStored(card, 'draft', 'back', 'My own translation 🦔');
  await card.close(); card = await popup();
  assert.equal(await card.locator('#back').inputValue(), 'My own translation 🦔');
  await card.locator('#suggestions button').first().waitFor();
  await card.locator('#back').fill('');
  await card.locator('#suggestions button').first().click();
  assert.match(await card.locator('#back').inputValue(), /A hedgehog\./);
  await card.locator('#back').fill('My own translation 🦔');
  await card.locator('#front').fill('bank');
  await card.locator('#suggestions button').first().waitFor();
  assert.equal(await card.locator('#suggestions button').count(), 2);
  const saveBounds = await card.locator('#save').boundingBox();
  assert.ok(saveBounds.y + saveBounds.height <= 600, 'Save remains visible within Chrome’s popup height cap.');
  assert.equal(await card.locator('#back').inputValue(), 'My own translation 🦔');
  await card.locator('#suggestions button').first().click();
  await card.locator('#lookup-status').filter({ hasText: 'has edits' }).waitFor();
  await card.locator('#back').fill('');
  await card.locator('#suggestions button').first().click();
  assert.match(await card.locator('#back').inputValue(), /^bank/);
  await card.close(); await discardStoredDraft();
  console.log('PASS: Unicode, remembered deck, draft restoration, ambiguity, and preserved manual edits');

  // Abort the browser response after the real server has committed the card.
  await select('#unicode'); card = await popup();
  await card.waitForFunction(() => document.getElementById('back').value.includes('A hedgehog.'));
  const committed = deferred();
  const dropAfterCommit = async route => {
    const response = await route.fetch();
    assert.equal(response.status(), 201);
    committed.resolve();
    await route.abort('failed');
  };
  await context.route(base + '/v1/items', dropAfterCommit);
  await card.locator('#save').click(); await committed.promise;
  await card.locator('#status').filter({ hasText: 'Your draft is kept' }).waitFor();
  assert.equal((await apiCall(settings, '/v1/items?limit=200')).data.length, 2);
  await card.close(); await context.unroute(base + '/v1/items', dropAfterCommit);
  card = await popup();
  assert.equal(await card.locator('#front').isDisabled(), true);
  assert.equal(await card.locator('#save').textContent(), 'Retry save');
  await card.locator('#save').click();
  await card.locator('#status').filter({ hasText: 'Card saved' }).waitFor();
  items = (await apiCall(settings, '/v1/items?limit=200')).data;
  assert.equal(items.length, 2, 'Retry after popup destruction must not duplicate a committed item.');
  await card.close();
  console.log('PASS: lost POST response and popup destruction retry without duplicate items/cards');

  await select('#word'); card = await popup();
  await card.waitForFunction(() => document.getElementById('back').value.includes('Finding something good by chance.'));
  const rejectInvalid = route => route.fulfill({ status: 422, contentType: 'application/problem+json',
    body: JSON.stringify({ detail: 'Choose another destination deck.' }) });
  await context.route(base + '/v1/items', rejectInvalid);
  await card.locator('#save').click();
  await card.locator('#status').filter({ hasText: 'Choose another destination deck' }).waitFor();
  await card.locator('#front:not(:disabled)').waitFor();
  assert.equal(await card.locator('#front').inputValue(), 'serendipity');
  assert.match(await card.locator('#back').inputValue(), /Finding something good/);
  await context.unroute(base + '/v1/items', rejectInvalid);
  await card.locator('#save').click();
  await card.locator('#status').filter({ hasText: 'Card saved' }).waitFor();
  await card.close();
  console.log('PASS: definite rejected save preserves authored fields and allows correction after absence check');

  await settings.locator('#pack').selectOption('');
  await waitForStored(settings, 'config', 'packId', '');
  await select('#input'); card = await popup();
  assert.equal(await card.locator('#front').inputValue(), 'selected');
  await card.locator('#lookup-status').filter({ hasText: 'No dictionary selected' }).waitFor();
  await card.locator('#back').fill('Manual answer');
  await card.locator('#save').click();
  await card.locator('#status').filter({ hasText: 'Card saved' }).waitFor();
  await card.close();
  console.log('PASS: editable-field selection and manual cards without a dictionary');

  // The Basic compatibility failure is a read-only response fixture, not a library mutation.
  const missingBasic = route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: [], page: { limit: 200 } }) });
  await context.route(base + '/v1/item-types?*', missingBasic);
  card = await popup(false);
  await card.locator('#status').filter({ hasText: 'Basic item type' }).waitFor();
  assert.equal(await card.locator('#save').isDisabled(), true);
  await card.close(); await context.unroute(base + '/v1/item-types?*', missingBasic);
  await discardStoredDraft();

  // Reading Mode uses the pack for meanings and dictionary forms; "bank" has two meanings.
  await settings.locator('#pack').selectOption('companion-fixture');
  await waitForStored(settings, 'config', 'packId', 'companion-fixture');
  await select('#word');
  const reading = await popup();
  const readingAction = (type, language = 'en') => reading.evaluate(async ({ type, language, sourceURL }) => {
    const tabs = await chrome.tabs.query({});
    const sourceTab = tabs.find(tab => tab.url?.startsWith(new URL(sourceURL).origin));
    if (!sourceTab) throw new Error('The toolbar gesture did not grant source-tab access.');
    const result = await chrome.runtime.sendMessage({ type, tabId: sourceTab.id, language, meaningLanguage: language });
    if (result.error) throw new Error(result.error);
    return result.value;
  }, { type, language, sourceURL });
  assert.equal(await source.evaluate(() => CSS.highlights.has('neoanki-unassessed')), false);
  await readingAction('neoankiReadingStart');
  await source.waitForFunction(() => CSS.highlights.get('neoanki-unassessed')?.size > 0);
  const sourceCDP = await context.newCDPSession(source);
  async function axElement(role, name) {
    const end = Date.now() + 5000;
    let element;
    while (Date.now() < end && !element) {
      const { nodes } = await sourceCDP.send('Accessibility.getFullAXTree');
      element = nodes.find(node => node.role?.value === role && node.name?.value === name
        && !node.properties?.some(property => property.name === 'disabled' && property.value?.value));
      if (!element) await source.waitForFunction(() => CSS.highlights.has('neoanki-unassessed'));
    }
    assert.ok(element?.backendDOMNodeId, role + ': ' + name);
    return element.backendDOMNodeId;
  }
  async function tap(role, name) {
    const backendNodeId = await axElement(role, name);
    await sourceCDP.send('DOM.focus', { backendNodeId });
    await source.keyboard.press('Enter');
  }
  async function composerDeck(deckID = null) {
    return composerChoice('Deck', deckID);
  }
  async function composerChoice(name, value) {
    const backendNodeId = await axElement('combobox', name);
    const { object: { objectId } } = await sourceCDP.send('DOM.resolveNode', { backendNodeId });
    const { result } = await sourceCDP.send('Runtime.callFunctionOn', { objectId, arguments: [{ value }],
      returnByValue: true, functionDeclaration: `function (value) {
        if (value !== null) {
          this.value = value;
          this.dispatchEvent(new Event('input', { bubbles: true }));
          this.dispatchEvent(new Event('change', { bubbles: true }));
        }
        return this.value;
      }` });
    return result.value;
  }
  const underlines = ['neoanki-unassessed', 'neoanki-unfamiliar', 'neoanki-learning'];
  const underlined = (word, expected = true, names = underlines) => source.waitForFunction(({ word, expected, names }) =>
    names.some(name => Array.from(CSS.highlights.get(name) || [], String).includes(word)) === expected, { word, expected, names });
  async function badgeText() {
    const { nodes } = await sourceCDP.send('Accessibility.getFullAXTree');
    return nodes.map(node => node.name?.value || '').find(name => name.startsWith('Reading · '));
  }
  await source.locator('#word').evaluate(element => document.getSelection().removeAllRanges());
  await source.locator('#word').click({ position: { x: 14, y: 10 } });
  await tap('button', 'I know this');
  await source.waitForFunction(() => !Array.from(CSS.highlights.get('neoanki-unassessed') || [], String).includes('serendipity'));
  let known = (await apiCall(settings, '/v1/known-words?language=en')).data;
  assert.equal(known.find(row => row.term.expression === 'serendipity').judgment, 'known');
  await tap('button', 'Undo');
  await source.waitForFunction(() => Array.from(CSS.highlights.get('neoanki-unassessed') || [], String).includes('serendipity'));
  known = (await apiCall(settings, '/v1/known-words?language=en')).data;
  assert.ok(!known.some(row => row.term.expression === 'serendipity' && row.judgment === 'known'));
  await underlined('42', false);
  assert.match(await badgeText(), /\d+% known · \d+ new/, 'The badge shows page coverage.');

  // A word with several meanings is known as a whole; choosing a meaning is only for card sets.
  await source.keyboard.press('Escape');
  await source.locator('#bank').click({ position: { x: 10, y: 10 } });
  await tap('button', 'I know this');
  await underlined('bank', false);
  known = (await apiCall(settings, '/v1/known-words?language=en&expression=bank')).data;
  assert.ok(known.some(row => !row.term.sense && row.judgment === 'known'), 'The judgment is saved without a meaning.');
  assert.ok(known.every(row => row.expressionState === 'known'));

  // A plain click on a known word opens nothing; Option/Alt-click reopens it.
  await source.keyboard.press('Escape');
  await source.locator('#bank').click({ position: { x: 10, y: 10 }, modifiers: ['Alt'] });
  await tap('button', 'Remove from Known');
  await underlined('bank', true, ['neoanki-unfamiliar']);

  // Hold both background reads so Ignore must work as soon as the panel opens.
  const panelReads = [`${base}/v1/decks?limit=200`, `${base}/v1/known-words?language=en&expression=Zorblax&limit=200`];
  const releasePanelReads = deferred();
  const holdPanelRead = async route => {
    await releasePanelReads.promise;
    await route.continue();
  };
  for (const url of panelReads) await context.route(url, holdPanelRead);
  try {
    const requested = Promise.all(panelReads.map(url => context.waitForEvent('request', request => request.url() === url)));
    requested.catch(() => {});
    await source.keyboard.press('Escape');
    await source.locator('#name').click({ position: { x: 10, y: 10 } });
    await requested;
    const { nodes } = await sourceCDP.send('Accessibility.getFullAXTree');
    const ignore = nodes.find(node => node.role?.value === 'button' && node.name?.value === 'Ignore');
    assert.ok(ignore, 'Ignore is shown when the word panel opens.');
    assert.ok(!ignore.properties?.some(property => property.name === 'disabled' && property.value?.value),
      'Ignore is enabled while deck and word details are still loading.');
    await tap('button', 'Ignore');
    await underlined('Zorblax', false);
    known = (await apiCall(settings, '/v1/known-words?language=en&expression=zorblax')).data;
    assert.equal(known.find(row => !row.term.sense)?.judgment, 'ignored');
    await tap('button', 'Undo');
    await underlined('Zorblax', true, ['neoanki-unassessed']);
    known = (await apiCall(settings, '/v1/known-words?language=en&expression=zorblax')).data;
    assert.ok(!known.some(row => row.judgment === 'ignored'), 'Undo works while the panel reads are still held.');
    await tap('button', 'Ignore');
    await underlined('Zorblax', false);
  } finally {
    releasePanelReads.resolve();
    for (const url of panelReads) await context.unroute(url, holdPanelRead);
  }

  await source.keyboard.press('Escape');
  await source.locator('#contextual em').click();
  await tap('button', 'Create card set');
  assert.equal(await composerDeck(), '', 'Reading Mode starts with no saved deck for English.');
  assert.equal(await composerDeck(deckId), deckId);
  await waitForStored(settings, 'card-set-deck:en', null, deckId);
  await sourceCDP.send('DOM.focus', { backendNodeId: await axElement('textbox', 'Meaning') });
  await source.keyboard.type('a fine distinction');
  await tap('button', 'Create card set');
  await source.waitForFunction(() => Array.from(CSS.highlights.get('neoanki-learning') || [], String).includes('subtlety'));
  const sets = (await apiCall(settings, '/v1/items?limit=200')).data.filter(item => item.cardIds.length === 2);
  assert.equal(sets.length, 1);
  assert.equal(sets[0].deckId, deckId);

  // Mark the rest as known skips words opened on this page, learning, not-known, and ignored words.
  await source.setViewportSize({ width: 1000, height: 650 });
  await source.keyboard.press('Escape');
  await tap('button', 'Mark the rest as known');
  const preview = await axElement('region', 'Words in this batch');
  const { object } = await sourceCDP.send('DOM.resolveNode', { backendNodeId: preview });
  const readBulkPreview = async () => (await sourceCDP.send('Runtime.callFunctionOn', {
    objectId: object.objectId,
    functionDeclaration: `function() {
      const entries = Array.from(this.querySelectorAll('.word-entry'));
      const [first, second] = entries;
      const panel = this.closest('section');
      const { left, right, width, bottom } = panel.getBoundingClientRect();
      return { entries: entries.map(word => word.firstElementChild.textContent),
        actions: [...new Set(Array.from(this.querySelectorAll('button'), button => button.textContent))],
        inline: first.getBoundingClientRect().top === second.getBoundingClientRect().top,
        scrollable: this.scrollHeight > this.clientHeight,
        footerVisible: panel.querySelector('.actions').getBoundingClientRect().bottom <= bottom,
        left, right, width };
    }`,
    returnByValue: true,
  })).result.value;
  const widePreview = await readBulkPreview();
  assert.ok(widePreview.width >= 600 && widePreview.inline, 'Desktop preview gives the inline words a wider panel.');
  await source.setViewportSize({ width: 320, height: 480 });
  await source.evaluate(() => new Promise(requestAnimationFrame));
  const words = await readBulkPreview();
  assert.ok(words.inline && words.left >= 8 && words.right <= 312, 'The open preview wraps inline words inside a narrow viewport.');
  assert.ok(words.scrollable, 'Long word lists can scroll inside the confirmation panel.');
  assert.ok(words.footerVisible, 'The confirmation buttons remain visible when the list scrolls.');
  assert.deepEqual(words.actions, ['×'], 'The full list uses compact controls at narrow widths.');
  assert.deepEqual(words.entries.filter(word => bulkWords.includes(word)), bulkWords, 'The preview includes every bulk word in page order.');
  assert.ok(['serendipity', 'subtlety', 'bank', 'Zorblax'].every(word => !words.entries.includes(word)),
    'The full preview omits every word excluded from the batch.');
  await tap('button', 'Ignore evergreen');
  await tap('button', 'Ignore pathway');
  await tap('button', 'Keep pathway');
  await underlined('evergreen', true, ['neoanki-unassessed']);
  known = (await apiCall(settings, '/v1/known-words?language=en&expression=evergreen')).data;
  assert.equal(known.length, 0, 'Preview choices are saved only on confirmation.');
  await tap('button', 'Apply changes');
  await underlined('revealed', false);
  await underlined('evergreen', false);
  await underlined('serendipity', true, ['neoanki-unassessed']);
  await underlined('subtlety', true, ['neoanki-learning']);
  await underlined('bank', true, ['neoanki-unfamiliar']);
  known = (await apiCall(settings, '/v1/known-words?language=en')).data;
  const judgment = word => known.find(row => !row.term.sense && row.term.expression === word)?.judgment;
  assert.equal(judgment('revealed'), 'known');
  assert.equal(judgment('pathway'), 'known', 'Keep restores the word to the known portion of the batch.');
  assert.equal(judgment('evergreen'), 'ignored', 'Ignore saves the word as ignored, even at the end of the full list.');
  await tap('button', 'Undo');
  await underlined('revealed', true, ['neoanki-unassessed']);
  await underlined('evergreen', true, ['neoanki-unassessed']);
  known = (await apiCall(settings, '/v1/known-words?language=en')).data;
  assert.equal(judgment('revealed'), undefined);
  assert.equal(judgment('evergreen'), undefined, 'The same Undo restores both statuses.');
  await source.goto(new URL('/next', sourceURL).href);
  await source.waitForFunction(() => Array.from(CSS.highlights.get('neoanki-learning') || [], String).includes('subtlety'));
  await readingAction('neoankiReadingStop');
  await source.waitForFunction(() => ['unassessed', 'unfamiliar', 'learning'].every(state => !CSS.highlights.has(`neoanki-${state}`)));
  await readingAction('neoankiReadingStart', 'uk');
  await underlined('кіптявий');
  await source.locator('#sooty em').click();
  await axElement('StaticText', 'Який коптить.');
  await tap('button', 'Create card set');
  await axElement('StaticText', 'Cloze hint · Який коптить.');
  await tap('button', 'Back');
  await tap('button', 'Close');
  await underlined('поруччям');
  await source.locator('#railing em').click();
  const definition = 'по́ручні — Невисока огорожа, за яку можна триматися.';
  await axElement('StaticText', definition);
  const { nodes: wordPanel } = await sourceCDP.send('Accessibility.getFullAXTree');
  assert.ok(!wordPanel.some(node => node.role?.value === 'combobox' && node.name?.value === 'Meaning' && !node.ignored),
    'A single definition is visible without an empty meaning picker.');
  await tap('button', 'Create card set');
  await axElement('StaticText', `Cloze hint · ${definition}`);
  assert.equal(await composerDeck(), '', 'A new learning language starts unassigned.');
  const ukrainianDeck = (await apiCall(settings, '/v1/decks')).data.find(value => value.name === 'Ukrainian vocabulary');
  assert.ok(ukrainianDeck);
  assert.equal(await composerDeck(ukrainianDeck.id), ukrainianDeck.id);
  await waitForStored(settings, 'card-set-deck:uk', null, ukrainianDeck.id);
  await axElement('StaticText', 'Cloze preview: Степан стояв за […] на палубі.');
  assert.equal(await composerChoice('Dictionary example for Cloze', '0'), '0');
  await axElement('StaticText', 'Cloze preview: […] блищало на сонці.');
  await tap('button', 'Create card set');
  await underlined('поруччям', true, ['neoanki-learning']);
  const ukrainianSet = (await apiCall(settings, '/v1/items?limit=200')).data.find(item => item.cardIds.length === 2
    && item.fields.some(field => field.value.text === 'поруччям'));
  assert.ok(ukrainianSet?.fields.some(field => field.value.text === definition && field.value.lang === 'uk'),
    'The local Ukrainian gloss is saved as the Meaning field without manual input.');
  assert.equal(ukrainianSet.deckId, ukrainianDeck.id);
  const cloze = ukrainianSet.fields.find(field => field.value.type === 'cloze').value;
  const { start, length } = cloze.blanks[0];
  assert.equal(cloze.text.slice(start, start + length), 'Поруччя');
  assert.ok(ukrainianSet.fields.some(field => field.value.text?.includes(source.url())
    && field.value.text.includes('СУМ-11 · (Тестовий автор, 12)')));
  await source.locator('#dictionary-only em').click();
  await axElement('StaticText', 'Ряд предметів.');
  await tap('button', 'Create card set');
  await axElement('StaticText', 'Cloze preview: Події тяглися […].');
  await tap('button', 'Create card set');
  await underlined('чередою', true, ['neoanki-learning']);
  const dictionarySet = (await apiCall(settings, '/v1/items?limit=200')).data.find(item => item.cardIds.length === 2
    && item.fields.some(field => field.value.text === 'чередою'));
  assert.ok(dictionarySet?.fields.some(field => field.value.text === 'СУМ-11 · (Тестовий автор, 19)'));
  await source.locator('#missing-word em').click();
  await axElement('StaticText', 'No definition found. You can enter one in the card set.');
  await tap('button', 'Create card set');
  await axElement('StaticText', 'Cloze preview: Його огорнула […].');
  assert.equal(await composerDeck(), ukrainianDeck.id, 'Another Ukrainian card set defaults to the last picked deck.');
  assert.equal(await composerDeck(''), '');
  await waitForStored(settings, 'card-set-deck:uk', null, '');
  await tap('button', 'Back');
  await tap('button', 'Create card set');
  assert.equal(await composerDeck(), '', 'Unassigned is remembered even before saving.');
  await readingAction('neoankiReadingStop');
  await readingAction('neoankiReadingStart');
  await underlined('subtlety', true, ['neoanki-learning']);
  await source.locator('#contextual em').click();
  await tap('button', 'Create card set');
  assert.equal(await composerDeck(), deckId, 'Returning to English restores its own deck.');
  await readingAction('neoankiReadingStop');
  await reading.close();
  console.log('PASS: opt-in Reading Mode, mark and undo, meanings, Ignore, Option-click, mark the rest, Cloze set, navigation, and cleanup');

  await settings.evaluate(async () => { window.fixtureConfig = (await chrome.storage.local.get('config')).config; });
  await settings.locator('#disconnect').click();
  await settings.locator('#status').filter({ hasText: 'Disconnected.' }).waitFor();
  // Restore only the fixture's now-revoked credential to exercise stale-token recovery.
  await settings.evaluate(async () => { await chrome.storage.local.set({ config: window.fixtureConfig }); });
  await source.bringToFront();
  const revokedPage = await context.newPage();
  await revokedPage.goto(origin + '/popup.html');
  await revokedPage.locator('#status').filter({ hasText: 'revoked or expired' }).waitFor();
  assert.equal(await revokedPage.locator('#save').isDisabled(), true);
  await revokedPage.close();
  console.log('PASS: incompatible Basic and revoked access show actionable errors and disable Save');

  fixture.stdin.end(); await once(fixture, 'exit');
  const offline = await context.newPage();
  await offline.goto(origin + '/popup.html');
  await offline.locator('#status').filter({ hasText: 'Could not reach NeoAnki2' }).waitFor();
  assert.equal(await offline.locator('#save').isDisabled(), true);
  assert.deepEqual(failures, [], 'No uncaught extension-page errors.');
  console.log('PASS: offline recovery and no uncaught extension errors');
  console.log(`Screenshots: ${results}`);
} catch (error) {
  if (context) {
    const cdp = await context.browser().newBrowserCDPSession();
    console.error('Targets:', (await cdp.send('Target.getTargets', { filter: [{}] })).targetInfos.map(({ type, url }) => ({ type, url })));
    for (const page of context.pages()) {
      if (page.url().startsWith('chrome-extension://')) {
        console.error('Extension status:', await page.locator('#status').textContent().catch(() => 'unavailable'));
        await page.screenshot({ path: path.join(results, `failure-${context.pages().indexOf(page)}.png`) }).catch(() => {});
      }
    }
  }
  throw error;
} finally {
  if (context) await context.close();
  if (fixture && fixture.exitCode === null) {
    fixture.stdin.end();
    const deadline = setTimeout(() => fixture.kill('SIGTERM'), 3000);
    await once(fixture, 'exit'); clearTimeout(deadline);
  }
  if (sourceServer) await new Promise(resolve => sourceServer.close(resolve));
  await rm(temporary, { recursive: true, force: true });
}
