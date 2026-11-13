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
    response.end('<!doctype html><html lang="en"><title>Vocabulary reading</title><p id="word">serendipity</p><p id="unicode">їжак 🦔</p><textarea id="input">selected phrase</textarea><button id="focus">Focus</button></html>');
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
      if (value?.[property] === expected) { cleanup(); resolve(); }
    }
    chrome.storage.onChanged.addListener(changed);
    chrome.storage.local.get(key).then(values => check(values[key])).catch(error => { cleanup(); reject(error); });
  }), { key, property, expected });
  const grant = await apiCall(settings, '/v1/clients/current');
  assert.equal(grant.origin, origin, 'Pairing binds the actual extension origin.');
  assert.deepEqual(grant.scopes.sort(), ['items.write', 'library.read', 'vocabulary.read']);
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
