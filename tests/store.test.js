import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../src/state/store.js';

// In-memory mock storage for Node environment
class MockStorage {
  constructor() {
    this.data = {};
  }
  getItem(key) {
    return this.data[key] || null;
  }
  setItem(key, value) {
    this.data[key] = String(value);
  }
  removeItem(key) {
    delete this.data[key];
  }
  clear() {
    this.data = {};
  }
}


describe('State Store - Session & Settings Management', () => {
  let store;
  let mockStorage;

  beforeEach(() => {
    mockStorage = new MockStorage();
    store = createStore({ storage: mockStorage });
  });

  it('stores and clears YouTube session credentials', () => {
    assert.equal(store.hasSession(), false);
    store.setSession({
      accessToken: 'ya29.test_token',
      refreshToken: 'ref_tok',
      expiresAt: Date.now() + 3600_000,
      clientType: 'TVHTML5'
    });
    assert.equal(store.hasSession(), true);
    assert.equal(store.getSession().clientType, 'TVHTML5');

    store.clearSession();
    assert.equal(store.hasSession(), false);
    assert.equal(store.getSession(), null);
  });

  it('updates filter settings', () => {
    assert.equal(store.getFilterSettings().blockShorts, true);
    store.setFilterSettings({ blockShorts: false });
    assert.equal(store.getFilterSettings().blockShorts, false);
  });
});

describe('State Store - Reactivity & Events', () => {
  it('notifies subscribers when state changes', () => {
    const store = createStore({ storage: new MockStorage() });
    let calls = 0;
    const unsubscribe = store.subscribe(() => {
      calls++;
    });

    store.setFilterSettings({ blockShorts: false });
    store.setSession({ token: 'abc' });
    assert.equal(calls, 2);

    unsubscribe();
    store.setFilterSettings({ minViews: 500 });
    assert.equal(calls, 2); // Unsubscribed, no extra call
  });
});
