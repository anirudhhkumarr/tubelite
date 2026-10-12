import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { generateCPN, createTelemetrySession } from '../src/playback/telemetryManager.js';
import { handleTelemetryRequest } from '../cloudflare/telemetry.js';

describe('Watch Telemetry Manager - Web Architecture', () => {
  it('generates compliant 16-character alphanumeric CPN', () => {
    const cpn1 = generateCPN();
    const cpn2 = generateCPN();

    assert.equal(typeof cpn1, 'string');
    assert.equal(cpn1.length, 16);
    assert.match(cpn1, /^[a-zA-Z0-9_-]{16}$/);

    assert.notEqual(cpn1, cpn2);
  });

  it('safely handles missing video ID', () => {
    const session = createTelemetrySession({ videoId: null });
    assert.equal(session, null);
  });

  it('manages telemetry lifecycle with lazy initialization', async () => {
    const dispatchedUrls = [];
    const originalFetch = globalThis.fetch;

    globalThis.fetch = async (url) => {
      dispatchedUrls.push(String(url));
      return new Response(null, { status: 204 });
    };

    try {
      const mockTracking = {
        videostatsPlaybackUrl: {
          baseUrl: 'https://s.youtube.com/api/stats/playback?docid=test12345'
        },
        videostatsWatchtimeUrl: {
          baseUrl: 'https://s.youtube.com/api/stats/watchtime?docid=test12345'
        }
      };

      const session = createTelemetrySession({
        videoId: 'test12345',
        getAccessToken: async () => 'mock-token',
        workerUrl: 'https://mock-worker.dev'
      });

      assert.equal(session.isInitialized(), false);
      assert.equal(session.isDisposed(), false);

      await session.init(mockTracking);

      assert.equal(session.isInitialized(), true);
      assert.equal(dispatchedUrls.length, 1);
      assert.ok(dispatchedUrls[0].includes('api%2Fstats%2Fplayback'));
      assert.ok(dispatchedUrls[0].includes('test12345'));
      assert.ok(dispatchedUrls[0].includes('cmt%3D0'));

      // Progress reporting (throttled)
      session.onProgress(15.5, true);
      // Immediately after init, progress within 15s is throttled
      assert.equal(dispatchedUrls.length, 1);

      // State change reporting (pause)
      await session.onStateChange('PAUSED', 15.5);
      assert.equal(dispatchedUrls.length, 2);
      assert.ok(dispatchedUrls[1].includes('api%2Fstats%2Fwatchtime'));
      assert.ok(dispatchedUrls[1].includes('state%3Dpaused'));

      // Teardown
      session.dispose();
      assert.equal(session.isDisposed(), true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

describe('Cloudflare Worker Telemetry Gateway', () => {
  it('rejects missing or empty target URL', async () => {
    const req = new Request('https://worker.dev/api/telemetry/ping');
    const res = await handleTelemetryRequest(req, new URL(req.url));
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.error, 'Target telemetry URL required');
  });

  it('rejects disallowed target hosts', async () => {
    const req = new Request('https://worker.dev/api/telemetry/ping?url=https://evil.com/api/stats');
    const res = await handleTelemetryRequest(req, new URL(req.url));
    assert.equal(res.status, 403);
    const body = await res.json();
    assert.equal(body.error, 'Disallowed telemetry host');
  });

  it('forwards telemetry ping to allowed s.youtube.com host with headers', async () => {
    let upstreamCapturedUrl = null;
    let upstreamCapturedHeaders = null;
    const originalFetch = globalThis.fetch;

    globalThis.fetch = async (url, opts) => {
      upstreamCapturedUrl = String(url);
      upstreamCapturedHeaders = opts.headers;
      return new Response(null, { status: 204 });
    };

    try {
      const target = 'https://s.youtube.com/api/stats/playback?docid=abc12345&cpn=1234567890123456';
      const req = new Request(`https://worker.dev/api/telemetry/ping?url=${encodeURIComponent(target)}`, {
        headers: {
          'Authorization': 'Bearer test-bearer-token',
          'X-YouTube-Cookie': 'SID=123;'
        }
      });

      const res = await handleTelemetryRequest(req, new URL(req.url));
      assert.equal(res.status, 204);
      assert.equal(res.headers.get('access-control-allow-origin'), '*');
      assert.equal(upstreamCapturedUrl, target);
      assert.equal(upstreamCapturedHeaders.get('Authorization'), 'Bearer test-bearer-token');
      assert.equal(upstreamCapturedHeaders.get('Cookie'), 'SID=123;');
      assert.equal(upstreamCapturedHeaders.get('Origin'), 'https://www.youtube.com');
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it('silently recovers with 204 if upstream fetch fails', async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async () => {
      throw new Error('Network timeout');
    };

    try {
      const target = 'https://s.youtube.com/api/stats/watchtime?docid=abc12345';
      const req = new Request(`https://worker.dev/api/telemetry/ping?url=${encodeURIComponent(target)}`);
      const res = await handleTelemetryRequest(req, new URL(req.url));
      assert.equal(res.status, 204);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
