// Content scripts never receive the token, and cannot read extension-local storage.
export const storageReady = chrome.storage.local.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });

export async function readState() {
  await storageReady;
  const state = await chrome.storage.local.get(['config', 'draft', 'lastDeck']);
  return { ...state, config: { port: 8766, ...state.config } };
}

let writes = Promise.resolve();
export function writeState(values) {
  const snapshot = structuredClone(values);
  const operation = writes.catch(() => {}).then(async () => {
    await storageReady;
    await chrome.storage.local.set(snapshot);
  });
  writes = operation;
  return operation;
}
