import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  isStandardVideoItem,
  filterFeedItems,
  extractDirectStream,
  isDisallowedEndpoint,
  cleanVideoUrl
} from '../src/playback/sanitizer.js';

describe('Feed Item Sanitizer - Item Schema Validation', () => {
  it('detects non-standard auxiliary schemas and badges', () => {
    assert.equal(isStandardVideoItem({ type: 'adSlotRenderer' }), false);
    assert.equal(isStandardVideoItem({ type: 'promotedSparklesWebRenderer' }), false);
    assert.equal(isStandardVideoItem({ type: 'inFeedAdRenderer' }), false);
    assert.equal(isStandardVideoItem({ isPromoted: true }), false);
    assert.equal(isStandardVideoItem({ badge: 'Ad' }), false);
    assert.equal(isStandardVideoItem({ badge: 'Sponsored' }), false);
  });

  it('preserves authentic organic videos', () => {
    assert.equal(isStandardVideoItem({ id: 'v123', title: 'Calculus Explained', badge: null }), true);
    assert.equal(isStandardVideoItem({ id: 'v456', title: 'WWDC Keynote', type: 'videoRenderer' }), true);
  });

  it('filters auxiliary schemas out of feed lists', () => {
    const mixedFeed = [
      { id: 'v1', title: 'Organic Video 1', type: 'videoRenderer' },
      { id: 'aux1', title: 'Buy Best Car Now', type: 'promotedSparklesWebRenderer', badge: 'Sponsored' },
      { id: 'v2', title: 'Organic Video 2', type: 'videoRenderer' },
      { id: 'aux2', title: 'Insurance Discount', isPromoted: true }
    ];

    const cleaned = filterFeedItems(mixedFeed);
    assert.equal(cleaned.length, 2);
    assert.deepEqual(cleaned.map(i => i.id), ['v1', 'v2']);
  });
});

describe('Direct Native Stream Resolution', () => {
  it('prioritizes HLS adaptive master manifest if available', () => {
    const streamingData = {
      hlsManifestUrl: 'https://manifest.googlevideo.com/api/manifest/hls_variant/...',
      formats: [
        { itag: 22, qualityLabel: '720p', url: 'https://googlevideo.com/videoplayback?itag=22' }
      ]
    };

    const stream = extractDirectStream(streamingData);
    assert.equal(stream.type, 'hls');
    assert.equal(stream.url, 'https://manifest.googlevideo.com/api/manifest/hls_variant/...');
  });

  it('falls back to progressive MP4 stream with highest quality', () => {
    const streamingData = {
      formats: [
        { itag: 18, qualityLabel: '360p', height: 360, url: 'https://googlevideo.com/360p.mp4' },
        { itag: 22, qualityLabel: '720p', height: 720, url: 'https://googlevideo.com/720p.mp4' }
      ]
    };

    const stream = extractDirectStream(streamingData);
    assert.equal(stream.type, 'mp4');
    assert.equal(stream.url, 'https://googlevideo.com/720p.mp4');
    assert.equal(stream.quality, '720p');
  });

  it('returns null if streamingData is invalid', () => {
    assert.equal(extractDirectStream(null), null);
    assert.equal(extractDirectStream({}), null);
  });
});

describe('Network and URL Parameter Sanitization', () => {
  it('identifies disallowed tracking endpoints', () => {
    assert.equal(isDisallowedEndpoint('https://googleads.g.doubleclick.net/pagead/ads?client=ca-pub-123'), true);
    assert.equal(isDisallowedEndpoint('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'), true);
    assert.equal(isDisallowedEndpoint('https://ad.doubleclick.net/ddm/track/clk'), true);
    assert.equal(isDisallowedEndpoint('https://static.doubleclick.net/instream/ad_status.js'), true);
    assert.equal(isDisallowedEndpoint('https://googlevideo.com/videoplayback?expire=123'), false);
  });

  it('strips tracking and non-standard query parameters from video URLs', () => {
    const dirtyUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&ad_type=preroll&gclid=Cj0KCQ&feature=emb_rel_end';
    const cleaned = cleanVideoUrl(dirtyUrl);
    assert.equal(cleaned, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
  });
});

import {
  detectStreamDesync,
  getStreamDesyncReason,
  isLocalhost,
  logStreamDebug,
  logStreamEvent,
  logStreamWarning,
  logStreamVerbose,
  getYouTubeErrorMessage,
  PLAYER_STATE_MAP
} from '../src/playback/streamManager.js';

describe('Stream Manager - Synchronization & Desync Detection', () => {
  it('detects desync when progressState.allowSeeking is false', () => {
    const desyncData = {
      info: {
        progressState: {
          allowSeeking: false,
          duration: 15,
          seekableStart: 0,
          seekableEnd: 0
        },
        currentTime: 2.5
      }
    };
    assert.equal(detectStreamDesync(desyncData, 'real123'), true);
    assert.ok(getStreamDesyncReason(desyncData, 'real123')?.includes('progressState.allowSeeking=false'));
  });

  it('allows normal playback when progressState.allowSeeking is true', () => {
    const normalData = {
      info: {
        progressState: {
          allowSeeking: true,
          duration: 12021,
          seekableStart: 0,
          seekableEnd: 12020.641
        },
        currentTime: 3.9
      }
    };
    assert.equal(detectStreamDesync(normalData, 'real123'), false);
    assert.equal(getStreamDesyncReason(normalData, 'real123'), null);
  });

  it('detects zero seekable window as desync condition', () => {
    const zeroSeekData = {
      info: {
        progressState: {
          seekableEnd: 0
        },
        currentTime: 2.0
      }
    };
    assert.equal(detectStreamDesync(zeroSeekData, 'real123'), true);
    assert.ok(getStreamDesyncReason(zeroSeekData, 'real123')?.includes('zero-seekable-window'));
  });

  it('detects stream video ID mismatch', () => {
    assert.equal(detectStreamDesync({
      info: { videoData: { video_id: 'mismatched_id_999' } }
    }, 'real123'), true);

    assert.equal(detectStreamDesync({
      info: { videoData: { video_id: 'real123' } }
    }, 'real123'), false);
  });

  it('returns false for authentic video playback', () => {
    assert.equal(detectStreamDesync({
      info: {
        videoData: { video_id: 'real123' },
        currentTime: 42
      }
    }, 'real123'), false);
    assert.equal(detectStreamDesync(null, 'real123'), false);
  });

  it('detects localhost and loopback environments correctly', () => {
    const originalWindow = globalThis.window;
    try {
      delete globalThis.window;
      assert.equal(isLocalhost(), false);

      globalThis.window = { location: { hostname: 'localhost' } };
      assert.equal(isLocalhost(), true);

      globalThis.window = { location: { hostname: '127.0.0.1' } };
      assert.equal(isLocalhost(), true);

      globalThis.window = { location: { hostname: 'app.local' } };
      assert.equal(isLocalhost(), true);

      globalThis.window = { location: { hostname: 'litetube.pages.dev' } };
      assert.equal(isLocalhost(), false);
    } finally {
      if (originalWindow === undefined) {
        delete globalThis.window;
      } else {
        globalThis.window = originalWindow;
      }
    }
  });

  it('verifies PLAYER_STATE_MAP mappings', () => {
    assert.equal(PLAYER_STATE_MAP['-1'], 'UNSTARTED');
    assert.equal(PLAYER_STATE_MAP['1'], 'PLAYING');
    assert.equal(PLAYER_STATE_MAP['2'], 'PAUSED');
    assert.equal(PLAYER_STATE_MAP['3'], 'BUFFERING');
    assert.equal(PLAYER_STATE_MAP['0'], 'ENDED');
  });

  it('logs stream debug messages only in localhost', () => {
    const originalWindow = globalThis.window;
    const originalLog = console.log;
    const logs = [];

    try {
      console.log = (...args) => logs.push(args);

      globalThis.window = { location: { hostname: 'youtube.com' } };
      logStreamDebug('Test Remote Event', { foo: 'bar' });
      assert.equal(logs.length, 0);

      globalThis.window = { location: { hostname: 'localhost' } };
      logStreamDebug('Stream State → PLAYING', { state: 1 });
      assert.equal(logs.length, 1);
      assert.ok(logs[0][0].includes('[LiteTube Stream]'));
      assert.ok(logs[0][0].includes('Stream State → PLAYING'));
      assert.deepEqual(logs[0][3], { state: 1 });
    } finally {
      console.log = originalLog;
      if (originalWindow === undefined) {
        delete globalThis.window;
      } else {
        globalThis.window = originalWindow;
      }
    }
  });

  it('logs stream events in dev mode and suppresses on remote host', () => {
    const originalWindow = globalThis.window;
    const originalLog = console.log;
    const logs = [];

    try {
      console.log = (...args) => logs.push(args);

      globalThis.window = { location: { hostname: 'youtube.com' } };
      logStreamEvent('FeedSanitizer', 'Excluded item', { id: 'item123' });
      assert.equal(logs.length, 0);

      globalThis.window = { location: { hostname: 'localhost' } };
      logStreamEvent('StreamManager', 'Stream synchronized', { isSynced: true });
      assert.equal(logs.length, 1);
      assert.ok(logs[0][0].includes('[LiteTube StreamManager]'));
      assert.ok(logs[0][0].includes('Stream synchronized'));
      assert.deepEqual(logs[0][3], { isSynced: true });
    } finally {
      console.log = originalLog;
      if (originalWindow === undefined) {
        delete globalThis.window;
      } else {
        globalThis.window = originalWindow;
      }
    }
  });

  it('logs stream failure warnings in dev mode', () => {
    const originalWindow = globalThis.window;
    const originalWarn = console.warn;
    const warnings = [];

    try {
      console.warn = (...args) => warnings.push(args);

      globalThis.window = { location: { hostname: 'localhost' } };
      logStreamWarning('StreamManager', 'Timeout during sync after 5.0s', { attempts: 3 });
      assert.equal(warnings.length, 1);
      assert.ok(warnings[0][0].includes('[LiteTube StreamManager] ⚠️'));
      assert.ok(warnings[0][0].includes('Timeout during sync after 5.0s'));
      assert.deepEqual(warnings[0][3], { attempts: 3 });
    } finally {
      console.warn = originalWarn;
      if (originalWindow === undefined) {
        delete globalThis.window;
      } else {
        globalThis.window = originalWindow;
      }
    }
  });

  it('logs stream verbose details in dev mode', () => {
    const originalWindow = globalThis.window;
    const originalLog = console.log;
    const logs = [];

    try {
      console.log = (...args) => logs.push(args);

      globalThis.window = { location: { hostname: 'localhost' } };
      logStreamVerbose('Stream rate adaptation active (elapsed: 1.2s at 16x speed)', { elapsed: 1.2 });
      assert.equal(logs.length, 1);
      assert.ok(logs[0][0].includes('[LiteTube Stream:Verbose]'));
      assert.ok(logs[0][0].includes('Stream rate adaptation active'));
    } finally {
      console.log = originalLog;
      if (originalWindow === undefined) {
        delete globalThis.window;
      } else {
        globalThis.window = originalWindow;
      }
    }
  });

  it('translates YouTube player API error codes into descriptive messages', () => {
    assert.ok(getYouTubeErrorMessage(2).includes('Invalid parameter'));
    assert.ok(getYouTubeErrorMessage(5).includes('HTML5'));
    assert.ok(getYouTubeErrorMessage(100).includes('not found'));
    assert.ok(getYouTubeErrorMessage(101).includes('embedded playback'));
    assert.ok(getYouTubeErrorMessage(150).includes('embedded playback'));
    assert.ok(getYouTubeErrorMessage(999).includes('Unknown player error'));
  });
});
