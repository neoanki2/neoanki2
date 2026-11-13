import { apiBase, makeAPI, revokeClient, SCOPES } from './core.js';
import { readState, writeState } from './storage.js';

const $ = id => document.getElementById(id);
let config;
let busy = true;
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
  const packs = (await makeAPI(config)('/v1/vocabulary-packs')).data;
  packs.sort((a, b) => a.title.localeCompare(b.title));
  $('pack').replaceChildren(new Option('None — type answers manually', ''));
  for (const pack of packs) $('pack').add(new Option(`${pack.title} (${pack.languages.join(', ')})`, pack.id));
  const chosen = config.packId === '' ? '' : packs.find(pack => pack.id === config.packId)?.id || packs[0]?.id || '';
  $('pack').value = chosen;
  config.packId = chosen;
  await writeState({ config });
  $('dictionary-status').textContent = packs.length ? '' : 'No vocabulary packs installed. Add one in NeoAnki2, then reconnect to refresh this list.';
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
    if (config.token && port === config.port) {
      // Refresh an existing connection instead of accumulating new grants.
      await makeAPI(config)('/v1/clients/current');
    } else {
      status('Approve “NeoAnki2 Chrome Companion” in NeoAnki2. Keep this tab open while you approve.');
      const paired = await makeAPI({ port })('/v1/pairings', {
        method: 'POST', timeout: 310000,
        body: { displayName: 'NeoAnki2 Chrome Companion', requestedScopes: SCOPES, origin: location.origin },
      });
      config = { port, token: paired.token, clientId: paired.client.id,
        ...(config.port === port && config.packId !== undefined ? { packId: config.packId } : {}) };
      await writeState({ config });
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
  } catch (error) { status(error.message, true); }
  finally { busy = false; controls(); }
});
$('pack').addEventListener('change', async () => {
  config.packId = $('pack').value;
  try { await writeState({ config }); }
  catch { status('The dictionary choice could not be saved. Try again.', true); }
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
