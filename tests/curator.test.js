import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  resolveApiKey,
  buildWatchNextPayload,
  buildFeedPayload,
  curateWatchNext,
  curateFeed,
  executeJevQuery
} from '../cloudflare/curator.js';

describe('TypeSafe Jev Recommendation & Feed Curator Engine', () => {
  describe('API Key Resolution & Hygiene', () => {
    it('resolves key from env.TYPESAFE_API_KEY', () => {
      const key = resolveApiKey({ TYPESAFE_API_KEY: 'apikey_test_123' });
      assert.equal(key, 'apikey_test_123');
    });

    it('resolves key from env.JEV_API_KEY as secondary option', () => {
      const key = resolveApiKey({ JEV_API_KEY: 'apikey_test_456' });
      assert.equal(key, 'apikey_test_456');
    });

    it('returns null when env has no API key', () => {
      const key = resolveApiKey({});
      assert.equal(key, null);
    });

    it('returns null when env is undefined', () => {
      const key = resolveApiKey(undefined);
      assert.equal(key, null);
    });
  });

  describe('Payload Builders', () => {
    it('buildWatchNextPayload constructs valid SystemOne schema with context', () => {
      const current = { title: 'SwiftUI Advanced Layouts', channelTitle: 'Apple Dev' };
      const candidates = [
        { title: 'CoreAudio in Swift', channelTitle: 'Audio Dev' },
        { title: 'Celebrity Drama Video', channelTitle: 'ClickDaily' }
      ];

      const payload = buildWatchNextPayload(current, candidates);
      assert.equal(payload.model, 'jev-latest');
      assert.ok(payload.state.includes('Current Video:'));
      assert.ok(payload.state.includes('SwiftUI Advanced Layouts'));
      assert.ok(payload.state.includes('CoreAudio in Swift'));
      assert.ok(payload.questions['rec_0']);
      assert.ok(payload.questions['rec_1']);
      assert.equal(payload.questions['rec_0'].type, 'score');
      assert.deepEqual(payload.questions['rec_0'].criteria, ['1', '2', '3', '4', '5']);
    });

    it('buildFeedPayload constructs valid SystemOne schema for feed curation', () => {
      const candidates = [
        { title: 'Transformer Architecture Explained', channelTitle: 'AI Research' },
        { title: 'You will NOT believe this!', channelTitle: 'Sensationalism' }
      ];

      const payload = buildFeedPayload(candidates);
      assert.equal(payload.model, 'jev-latest');
      assert.ok(payload.state.includes('Feed Candidates:'));
      assert.ok(payload.questions['feed_0']);
      assert.ok(payload.questions['feed_1']);
      assert.equal(payload.questions['feed_0'].type, 'score');
    });
  });

  describe('Graceful Fail-Open Behavior', () => {
    it('curateWatchNext fails open to original input when no API key is set', async () => {
      const input = {
        details: { id: 'v0', title: 'Video 0' },
        items: [
          { id: 'v1', title: 'Video 1' },
          { id: 'v2', title: 'Video 2' }
        ]
      };

      const result = await curateWatchNext(input, {});
      assert.deepEqual(result, input);
    });

    it('curateFeed fails open to original input when no API key is set', async () => {
      const input = {
        items: [
          { id: 'v1', title: 'Video 1' },
          { id: 'v2', title: 'Video 2' }
        ]
      };

      const result = await curateFeed(input, {});
      assert.deepEqual(result, input);
    });

    it('executeJevQuery returns null on invalid or unreachable endpoint', async () => {
      const result = await executeJevQuery(
        { state: 'test', questions: {} },
        'apikey_invalid_test',
        50 // Very short timeout
      );
      assert.equal(result, null);
    });
  });

  describe('Re-Ranking and Scoring Logic', () => {
    it('curateWatchNext re-ranks items according to Jev answer scores and confidence', async () => {
      const originalFetch = globalThis.fetch;
      try {
        // Mock Jev response elevating high-signal candidate (index 1) over low-signal candidate (index 0)
        globalThis.fetch = async () => {
          return new Response(JSON.stringify({
            model: 'jev-1.13.0',
            answers: {
              rec_0: { type: 'score', score: 0.1, confidence: 0.95 }, // Clickbait
              rec_1: { type: 'score', score: 3.8, confidence: 0.90 }  // High relevance
            }
          }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          });
        };

        const watchNext = {
          details: { id: 'v0', title: 'Building Apple TV Apps', channelTitle: 'Dev' },
          items: [
            { id: 'v_clickbait', title: 'SHOCKING SECRET!' },
            { id: 'v_relevant', title: 'SwiftUI TV Performance Optimization' }
          ]
        };

        const env = { TYPESAFE_API_KEY: 'apikey_mock_test' };
        const curated = await curateWatchNext(watchNext, env);

        assert.equal(curated.items[0].id, 'v_relevant');
        assert.equal(curated.items[1].id, 'v_clickbait');
      } finally {
        globalThis.fetch = originalFetch;
      }
    });

    it('curateFeed re-ranks items according to substance scores', async () => {
      const originalFetch = globalThis.fetch;
      try {
        globalThis.fetch = async () => {
          return new Response(JSON.stringify({
            model: 'jev-1.13.0',
            answers: {
              feed_0: { type: 'score', score: 0.2, confidence: 0.8 },
              feed_1: { type: 'score', score: 3.5, confidence: 0.85 }
            }
          }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          });
        };

        const feed = {
          items: [
            { id: 'f_low', title: 'Random Gossip' },
            { id: 'f_high', title: 'Deep Tech Documentary' }
          ]
        };

        const env = { TYPESAFE_API_KEY: 'apikey_mock_test' };
        const curated = await curateFeed(feed, env);

        assert.equal(curated.items[0].id, 'f_high');
        assert.equal(curated.items[1].id, 'f_low');
      } finally {
        globalThis.fetch = originalFetch;
      }
    });

    it('preserves items beyond MAX_CURATION_ITEMS in their original order', async () => {
      const originalFetch = globalThis.fetch;
      try {
        globalThis.fetch = async () => {
          const answers = {};
          for (let i = 0; i < 10; i++) {
            // Invert the top 10 items
            answers[`rec_${i}`] = { type: 'score', score: 10 - i, confidence: 1 };
          }
          return new Response(JSON.stringify({ model: 'jev-1.13.0', answers }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          });
        };

        const items = [];
        for (let i = 0; i < 15; i++) {
          items.push({ id: `item_${i}`, title: `Title ${i}` });
        }

        const watchNext = { details: { id: 'main', title: 'Main' }, items };
        const env = { TYPESAFE_API_KEY: 'apikey_mock_test' };
        const curated = await curateWatchNext(watchNext, env);

        assert.equal(curated.items.length, 15);
        // Top 10 should be re-ranked (item_0 had highest score 10, so it remains first)
        assert.equal(curated.items[0].id, 'item_0');
        // Trailing items 10..14 should remain untouched at index 10..14
        assert.equal(curated.items[10].id, 'item_10');
        assert.equal(curated.items[14].id, 'item_14');
      } finally {
        globalThis.fetch = originalFetch;
      }
    });

    it('ensures API key is never exposed on the returned FeedResponse or WatchNextResponse objects', async () => {
      const originalFetch = globalThis.fetch;
      try {
        globalThis.fetch = async () => {
          return new Response(JSON.stringify({
            model: 'jev-1.13.0',
            answers: {
              rec_0: { type: 'score', score: 3.0, confidence: 0.9 },
              rec_1: { type: 'score', score: 2.0, confidence: 0.9 }
            }
          }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          });
        };

        const SECRET_KEY = 'apikey_super_private_secret_never_leak';
        const watchNext = {
          details: { id: 'v0', title: 'Test Video' },
          items: [
            { id: 'v1', title: 'Rec 1' },
            { id: 'v2', title: 'Rec 2' }
          ]
        };

        const curated = await curateWatchNext(watchNext, { TYPESAFE_API_KEY: SECRET_KEY });
        const serialized = JSON.stringify(curated);

        assert.ok(!serialized.includes(SECRET_KEY), 'Curated response must not leak API key');
      } finally {
        globalThis.fetch = originalFetch;
      }
    });
  });
});
