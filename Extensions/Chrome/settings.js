import './reading-model.js';
import { apiBase, batchKeys, hasCapabilities, makeAPI, PLACEMENT_CAPABILITIES, postJudgmentBatches, revokeClient, READING_SCOPES, SCOPES,
  undoJudgmentBatches } from './core.js';
import { readState, writeState } from './storage.js';

const $ = id => document.getElementById(id);
const model = globalThis.NeoAnkiReadingModel;
// Frequency bands for "Estimate my level", as [offset, end] from the most frequent word.
const BANDS = [[0, 1000], [1000, 3000], [3000, 5000], [5000, 10000]];
let config;
let busy = true;
let packs = [];
let placement = null;
let placementBusy = false;
function status(message, error = false) {
  $('status').textContent = message;
  $('status').classList.toggle('error', error);
}
function controls() {
  $('connect').disabled = busy || !config;
  $('disconnect').disabled = busy;
  $('port').disabled = busy;
  $('pack').disabled = busy || !config?.token;
  $('connect').textContent = busy ? 'Waiting…' : config?.token ? 'Reconnect' : 'Connect';
  $('disconnect').hidden = !config?.token;
}
async function dictionaries() {
  packs = (await makeAPI(config)('/v1/vocabulary-packs')).data;
  packs.sort((a, b) => a.title.localeCompare(b.title));
  $('pack').replaceChildren(new Option('None — type answers manually', ''));
  for (const pack of packs) $('pack').add(new Option(`${pack.title} (${pack.languages.join(', ')})`, pack.id));
  const chosen = config.packId === '' ? '' : packs.find(pack => pack.id === config.packId)?.id || packs[0]?.id || '';
  $('pack').value = chosen;
  config.packId = chosen;
  await writeState({ config });
  $('dictionary-status').textContent = packs.length ? '' : 'No vocabulary packs installed. Add one in NeoAnki2, then reconnect to refresh this list.';
  await showPlacement().catch(error => placementStatus(error.message, true));
}

function placementStatus(message, error = false) {
  $('placement-status').textContent = message;
  $('placement-status').classList.toggle('error', error);
}

function placementControls() {
  $('placement-start').disabled = placementBusy || !placement?.allowed;
  $('placement-language').disabled = placementBusy;
  $('placement-mark').disabled = placementBusy;
  $('placement-undo').disabled = placementBusy;
}

// "Estimate my level" needs a pack with frequency data and Known Words access.
function resetPlacement() {
  $('placement-bands').replaceChildren();
  $('placement-mark').hidden = true;
  $('placement-undo').hidden = true;
  placementStatus('');
  if (placement) placement = { allowed: placement.allowed };
}

async function showPlacement() {
  const pack = packs.find(value => value.id === config.packId);
  $('placement').hidden = !pack || !config.token;
  resetPlacement();
  placement = null;
  if (!pack || !config.token) return;
  const client = await makeAPI(config)('/v1/clients/current');
  const supported = await hasCapabilities(config, PLACEMENT_CAPABILITIES);
  placement = { allowed: supported && READING_SCOPES.every(scope => client.scopes?.includes(scope)) };
  const { readingLanguages = {} } = await readState();
  $('placement-language').replaceChildren(...pack.languages.map(code => new Option(code, code)));
  if (pack.languages.includes(readingLanguages.language)) $('placement-language').value = readingLanguages.language;
  if (!supported) placementStatus('Update NeoAnki2 to estimate your level with this version of the companion.');
  else if (!placement.allowed) placementStatus('Reconnect and approve Known Words access in NeoAnki2 to estimate your level.');
  placementControls();
}

function placementBands() {
  return placement.bands.map((band, index) => {
    const boxes = Array.from(document.querySelectorAll(`#placement-bands input[data-band="${index}"]`));
    return { ...band, sample: boxes.length, known: boxes.filter(box => box.checked).length,
      unknown: boxes.filter(box => !box.checked).map(box => box.value) };
  });
}

function updatePlacement() {
  const bands = placementBands();
  for (const [index, band] of bands.entries()) {
    $(`placement-band-${index}`).textContent = `You know ${band.known} of ${band.sample}.`;
  }
  placement.target = model.placementTarget(bands, placement.total);
  placement.request = null;
  $('placement-mark').hidden = !placement.target;
  $('placement-mark').textContent = `Mark the top ${placement.target.toLocaleString()} words as known`;
}

function renderPlacement() {
  const language = placement.language;
  $('placement-bands').replaceChildren();
  for (const [index, band] of placement.bands.entries()) {
    const group = document.createElement('fieldset');
    group.className = 'band';
    const legend = document.createElement('legend');
    legend.textContent = `Most common ${(band.offset + 1).toLocaleString()}–${band.end.toLocaleString()}`;
    const words = document.createElement('div');
    words.className = 'words';
    for (const word of band.words) {
      const label = document.createElement('label');
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.value = word;
      box.dataset.band = String(index);
      box.addEventListener('change', updatePlacement);
      const text = document.createElement('span');
      text.lang = language;
      text.textContent = word;
      label.append(box, text);
      words.append(label);
    }
    const summary = document.createElement('p');
    summary.className = 'hint';
    summary.id = `placement-band-${index}`;
    group.append(legend, words, summary);
    $('placement-bands').append(group);
  }
  updatePlacement();
}
$('connection-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (busy) return;
  busy = true; controls();
  try {
    const port = Number($('port').value);
    apiBase(port);
    const state = await readState();
    if (state.draft?.pending) throw new Error('Finish the pending card save, or check NeoAnki2 and discard its draft, before changing the connection.');
    const meta = await makeAPI({ port })('/v1/meta');
    const requestedScopes = meta.capabilities?.includes('vocabulary.known-words') ? [...SCOPES, ...READING_SCOPES] : SCOPES;
    const prior = config.token && port === config.port ? await makeAPI(config)('/v1/clients/current') : null;
    if (!prior || !requestedScopes.every(scope => prior.scopes.includes(scope))) {
      status('Approve “NeoAnki2 Chrome Companion” in NeoAnki2. Keep this tab open while you approve.');
      const paired = await makeAPI({ port })('/v1/pairings', {
        method: 'POST', timeout: 310000,
        body: { displayName: 'NeoAnki2 Chrome Companion', requestedScopes, origin: location.origin },
      });
      const previousConfig = config;
      config = { port, token: paired.token, clientId: paired.client.id,
        ...(config.port === port && config.packId !== undefined ? { packId: config.packId } : {}) };
      await writeState({ config });
      if (prior) await revokeClient(makeAPI(previousConfig)).catch(() => {});
    }
    status('Connected. You can close this tab and add a card from the toolbar.');
    await dictionaries();
  } catch (error) {
    // A revoked token must be removed so the next Connect can actually pair.
    if (error.status === 401 || error.status === 403) {
      config = { port: config.port, packId: config.packId };
      await writeState({ config });
    }
    status(error.message, true);
  } finally { busy = false; controls(); }
});
$('disconnect').addEventListener('click', async () => {
  if (busy) return;
  busy = true; controls();
  try {
    const state = await readState();
    if (state.draft?.pending) throw new Error('Finish the pending save, or check NeoAnki2 and discard its draft, before disconnecting.');
    try { await revokeClient(makeAPI(config)); }
    catch (error) { if (error.status !== 401) throw error; }
    config = { port: config.port, packId: config.packId };
    await writeState({ config });
    status('Disconnected.');
    await showPlacement();
  } catch (error) { status(error.message, true); }
  finally { busy = false; controls(); }
});
$('pack').addEventListener('change', async () => {
  config.packId = $('pack').value;
  try { await writeState({ config }); }
  catch { status('The dictionary choice could not be saved. Try again.', true); }
  await showPlacement().catch(error => placementStatus(error.message, true));
});
$('placement-language').addEventListener('change', resetPlacement);
$('placement-start').addEventListener('click', async () => {
  if (placementBusy || !placement?.allowed) return;
  placementBusy = true; placementControls();
  const language = $('placement-language').value;
  const pack = encodeURIComponent(config.packId);
  try {
    const bands = [];
    let total = 0;
    for (const [offset, end] of BANDS) {
      const query = new URLSearchParams({ language, offset: String(offset), limit: String(end - offset), sample: '20' });
      const band = await makeAPI(config)(`/v1/vocabulary-packs/${pack}/frequency-band?${query}`);
      total = band.total;
      if (band.words.length) bands.push({ offset, end: Math.min(end, total), words: band.words });
      if (total <= end) break;
    }
    if (!bands.length) throw new Error('This vocabulary pack has no word frequencies for this language.');
    placement = { ...placement, language, total, bands };
    renderPlacement();
    placementStatus('Tick every word you know. Leave the rest unticked.');
  } catch (error) { placementStatus(error.message, true); }
  finally { placementBusy = false; placementControls(); }
});
// Marks the top words as known with one undoable batch. Words that already have a status and
// sample words you left unticked are skipped. Retries reuse the same batch keys.
$('placement-mark').addEventListener('click', async () => {
  if (placementBusy || !placement?.target) return;
  placementBusy = true; placementControls();
  const { language, target } = placement;
  const api = makeAPI(config);
  try {
    if (!placement.request) {
      const snapshot = await api(`/v1/known-words/snapshot?${new URLSearchParams({ language })}`);
      const query = new URLSearchParams({ language, offset: '0', limit: String(target) });
      const { words } = await api(`/v1/vocabulary-packs/${encodeURIComponent(config.packId)}/frequency-band?${query}`);
      const skipped = new Set(placementBands().filter(band => band.end <= target)
        .flatMap(band => band.unknown).map(word => model.matchKey(word, language)));
      const has = (map, key) => map && Object.hasOwn(map, key) && map[key] !== 'unassessed';
      const entries = [];
      for (const word of words) {
        const key = model.matchKey(word, language);
        if (skipped.has(key) || has(snapshot.expressions, key) || has(snapshot.lemmas, key)) continue;
        skipped.add(key);
        // Pack words are dictionary forms, which can carry stress marks; the lemma keeps them.
        entries.push({ term: { language, expression: model.withoutStress(word, language), lemma: word }, judgment: 'known' });
      }
      placement.request = { entries, keys: batchKeys(entries.length) };
    }
    const { entries, keys } = placement.request;
    if (!entries.length) { placementStatus('All of these words already have a status.'); return; }
    const receipt = await postJudgmentBatches(api, entries, keys);
    placement.request = null;
    placement.receipt = { ...receipt, undoKeys: receipt.batchIds.map(() => crypto.randomUUID()) };
    $('placement-undo').hidden = false;
    placementStatus(`Marked ${receipt.recorded.toLocaleString()} words as known.`);
  } catch (error) { placementStatus(`${error.message} Try again to finish the same change.`, true); }
  finally { placementBusy = false; placementControls(); }
});
$('placement-undo').addEventListener('click', async () => {
  const receipt = placement?.receipt;
  if (placementBusy || !receipt) return;
  placementBusy = true; placementControls();
  try {
    await undoJudgmentBatches(makeAPI(config), receipt.batchIds, receipt.undoKeys);
    placement.receipt = null;
    $('placement-undo').hidden = true;
    placementStatus('Undone. Those words are unassessed again.');
  } catch (error) { placementStatus(error.message, true); }
  finally { placementBusy = false; placementControls(); }
});
async function init() {
  config = (await readState()).config;
  $('port').value = config.port;
  controls();
  if (!config.token) { status('Connect once and approve access in NeoAnki2.'); return; }
  await makeAPI(config)('/v1/clients/current');
  status('Connected to NeoAnki2.');
  await dictionaries();
}
controls();
init().catch(async error => {
  if (error.status === 401 || error.status === 403) {
    config = { port: config.port, packId: config.packId };
    await writeState({ config });
  }
  status(error.message, true);
}).finally(() => { busy = false; controls(); });
