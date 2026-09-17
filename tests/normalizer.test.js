import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  extractRunsText,
  parseDurationToSeconds,
  parseViewCount,
  isShortVideo,
  isValidVideo,
  parseVideoNode,
  normalizeFeedResponse,
  normalizeWatchNextResponse
} from '../cloudflare/normalizer.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const fixturesDir = path.resolve(__dirname, 'fixtures');
const scratchDir = path.resolve(__dirname, '../scratch');

function loadFixtureJson(filename) {
  const fixturePath = path.join(fixturesDir, filename);
  if (fs.existsSync(fixturePath)) {
    return JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  }
  const scratchPath = path.join(scratchDir, filename);
  if (fs.existsSync(scratchPath)) {
    return JSON.parse(fs.readFileSync(scratchPath, 'utf8'));
  }
  throw new Error(`Required test fixture not found: ${fixturePath}`);
}
const loadScratchJson = loadFixtureJson;

describe('Cloudflare Worker Normalizer - Enterprise Parsing & Filtering', () => {
  describe('Helper Utilities', () => {
    it('extractRunsText handles string, simpleText, content, and runs array correctly', () => {
      assert.equal(extractRunsText('hello'), 'hello');
      assert.equal(extractRunsText({ simpleText: 'simple' }), 'simple');
      assert.equal(extractRunsText({ content: 'content' }), 'content');
      assert.equal(extractRunsText({ runs: [{ text: 'a ' }, { text: 'b' }] }), 'a b');
      assert.equal(extractRunsText(null), '');
      assert.equal(extractRunsText(undefined), '');
    });

    it('parseDurationToSeconds correctly converts MM:SS and HH:MM:SS', () => {
      assert.equal(parseDurationToSeconds('0:45'), 45);
      assert.equal(parseDurationToSeconds('3:33'), 213);
      assert.equal(parseDurationToSeconds('1:02:05'), 3725);
      assert.equal(parseDurationToSeconds(120), 120);
      assert.equal(parseDurationToSeconds(null), null);
      assert.equal(parseDurationToSeconds('invalid'), null);
    });

    it('parseViewCount converts view strings to integers', () => {
      assert.equal(parseViewCount('1.5M views'), 1500000);
      assert.equal(parseViewCount('250K views'), 250000);
      assert.equal(parseViewCount('1,234 views'), 1234);
      assert.equal(parseViewCount('No views'), 0);
      assert.equal(parseViewCount(100), 100);
    });
  });

  describe('Shorts Detection & Exclusion', () => {
    it('detects explicit shorts renderers and formats', () => {
      assert.equal(isShortVideo({ reelItemRenderer: { videoId: 'short1' } }), true);
      assert.equal(isShortVideo({ shortsLockupViewModel: { entityId: 'short2' } }), true);
    });

    it('detects contentType SHORT / REEL', () => {
      assert.equal(isShortVideo({ videoRenderer: { contentType: 'LOCKUP_CONTENT_TYPE_SHORTS' } }), true);
      assert.equal(isShortVideo({ contentType: 'LOCKUP_CONTENT_TYPE_REEL' }), true);
    });

    it('detects SHORTS overlay badge', () => {
      const item = {
        videoRenderer: {
          videoId: 'vid1',
          thumbnailOverlays: [{
            thumbnailOverlayTimeStatusRenderer: {
              style: 'SHORTS',
              text: { simpleText: 'SHORTS' }
            }
          }]
        }
      };
      assert.equal(isShortVideo(item), true);
    });

    it('detects structural reelWatchEndpoint navigation as shorts', () => {
      assert.equal(isShortVideo({ videoRenderer: { navigationEndpoint: { reelWatchEndpoint: { videoId: 'reel_1' } } } }), true);
      assert.equal(isShortVideo({ tileRenderer: { onSelectCommand: { reelWatchEndpoint: { videoId: 'reel_2' } } } }), true);
    });

    it('detects vertical / portrait aspect ratio enums as shorts', () => {
      assert.equal(isShortVideo({
        lockupViewModel: {
          contentImage: {
            thumbnailViewModel: {
              contentImageAspectRatio: 'LOCKUP_CONTENT_IMAGE_ASPECT_RATIO_VERTICAL'
            }
          }
        }
      }), true);
      assert.equal(isShortVideo({
        tileRenderer: {
          contentImageAspectRatio: 'LOCKUP_CONTENT_IMAGE_ASPECT_RATIO_PORTRAIT'
        }
      }), true);
    });

    it('detects reel player overlay style and videoType enums as shorts', () => {
      assert.equal(isShortVideo({
        videoRenderer: {
          overlay: {
            reelPlayerOverlayRenderer: {
              style: 'REEL_PLAYER_OVERLAY_STYLE_SHORTS'
            }
          }
        }
      }), true);
      assert.equal(isShortVideo({
        videoRenderer: {
          videoType: 'REEL_VIDEO_TYPE_VIDEO'
        }
      }), true);
      assert.equal(isShortVideo({
        videoRenderer: {
          navigationEndpoint: {
            commandMetadata: {
              webCommandMetadata: {
                url: '/shorts/abcdef123'
              }
            }
          }
        }
      }), true);
    });

    it('detects duration < 60s as shorts', () => {
      assert.equal(isShortVideo({ videoRenderer: { lengthText: { simpleText: '0:45' } } }), true);
      assert.equal(isShortVideo({ videoRenderer: { lengthText: { simpleText: '0:59' } } }), true);
    });

    it('preserves long-form videos (>60s)', () => {
      assert.equal(isShortVideo({ videoRenderer: { lengthText: { simpleText: '1:01' } } }), false);
      assert.equal(isShortVideo({ videoRenderer: { lengthText: { simpleText: '14:20' } } }), false);
    });
  });

  describe('Non-Video & Invalid Item Exclusion', () => {
    it('rejects playlists, channels, radios, and non-video schemas', () => {
      assert.equal(isValidVideo({ playlistRenderer: { playlistId: 'PL123' } }), false);
      assert.equal(isValidVideo({ channelRenderer: { channelId: 'UC123' } }), false);
      assert.equal(isValidVideo({ radioRenderer: { playlistId: 'RD123' } }), false);
    });

    it('rejects non-video IDs (VL, PL, RD, UU, UC, @)', () => {
      assert.equal(isValidVideo({ videoRenderer: { videoId: 'PL12345' } }), false);
      assert.equal(isValidVideo({ videoRenderer: { videoId: 'UC12345' } }), false);
    });

    it('rejects stacked card collections and sponsored ad tiles', () => {
      assert.equal(isValidVideo({ videoRenderer: { videoId: 'v1', contentImage: { collectionThumbnailViewModel: {} } } }), false);
      assert.equal(isValidVideo({
        tileRenderer: {
          contentId: 'ad_tile_1',
          contentType: 'TILE_CONTENT_TYPE_VIDEO',
          metadata: {
            tileMetadataRenderer: {
              lines: [{
                lineRenderer: {
                  items: [{
                    lineItemRenderer: {
                      badge: { adBadgeViewModel: { style: 'AD_BADGE_STYLE_STARK', label: { content: 'Sponsored' } } }
                    }
                  }]
                }
              }]
            }
          }
        }
      }), false);
    });
  });

  describe('Empirical Real-World Corpus Validation (Corpus Fixtures)', () => {
    it('normalizes authentic Home Recommendations feed (browse_what_to_watch_page_1.json)', () => {
      const raw = loadScratchJson('browse_what_to_watch_page_1.json');
      const feed = normalizeFeedResponse(raw);

      assert.ok(feed.items.length > 0, 'Feed should return normalized items');
      assert.ok(feed.continuationToken, 'Continuation token should be present');

      for (const item of feed.items) {
        assert.ok(item.id && item.id.trim().length > 0, 'Item must have a non-empty id');
        assert.ok(item.title && item.title.trim().length > 0, `Item ${item.id} must have a non-empty title`);
        assert.ok(item.channelTitle && item.channelTitle.trim().length > 0, `Item ${item.id} must have a non-empty channelTitle`);
        assert.ok(item.views && item.views.trim().length > 0, `Item ${item.id} (${item.title}) must have a non-empty views string`);
        assert.ok(item.publishedAt && item.publishedAt.trim().length > 0, `Item ${item.id} (${item.title}) must have a non-empty publishedAt string`);
        assert.notEqual(item.publishedAt, '•', `Item ${item.id} publishedAt must never be delimiter bullet`);
        assert.notEqual(item.publishedTime, '•', `Item ${item.id} publishedTime must never be delimiter bullet`);
      }
    });

    it('normalizes authentic Subscriptions feed across pages (browse_subscriptions_page_1.json)', () => {
      const raw = loadScratchJson('browse_subscriptions_page_1.json');
      const feed = normalizeFeedResponse(raw);

      assert.ok(feed.items.length > 0, 'Subscriptions feed should return normalized items');
      for (const item of feed.items) {
        assert.ok(item.id && item.id.trim().length > 0);
        assert.ok(item.title && item.title.trim().length > 0);
        assert.ok(item.channelTitle && item.channelTitle.trim().length > 0, `Item ${item.id} must have a channel title`);
        assert.ok(item.views && item.views.trim().length > 0, `Item ${item.id} must have views`);
        assert.ok(item.publishedAt && item.publishedAt.trim().length > 0, `Item ${item.id} must have publishedAt`);
        assert.notEqual(item.publishedAt, '•');
        assert.notEqual(item.publishedTime, '•');
      }
    });

    it('normalizes authentic Watch Next recommendations (next_tuBCgJK6vxc_page_1.json)', () => {
      const raw = loadScratchJson('next_tuBCgJK6vxc_page_1.json');
      const watchNext = normalizeWatchNextResponse(raw);

      assert.ok(watchNext.items.length > 0, 'Watch next should contain related recommendation items');
      for (const item of watchNext.items) {
        assert.ok(item.id && item.id.trim().length > 0);
        assert.ok(item.title && item.title.trim().length > 0);
        assert.ok(item.channelTitle && item.channelTitle.trim().length > 0, `Item ${item.id} must have a channel title`);
        assert.ok(item.views && item.views.trim().length > 0, `Item ${item.id} must have views`);
        // Live streams have 'watching' metric and naturally have no published date
        if (!item.views.includes('watching')) {
          assert.ok(item.publishedAt && item.publishedAt.trim().length > 0, `Item ${item.id} must have publishedAt`);
        }
        assert.notEqual(item.publishedAt, '•');
        assert.notEqual(item.publishedTime, '•');
      }
    });

    it('normalizes authentic Search results across TV and Web clients', () => {
      const tvNews = loadScratchJson('search_tv_news_page_1.json');
      const tvFeed = normalizeFeedResponse(tvNews);
      assert.ok(tvFeed.items.length > 0, 'TV search should return items');
      for (const item of tvFeed.items) {
        assert.ok(item.id && item.id.trim().length > 0);
        assert.ok(item.title && item.title.trim().length > 0);
        assert.ok(item.channelTitle && item.channelTitle.trim().length > 0);
        assert.ok(item.views && item.views.trim().length > 0);
        assert.ok(item.publishedAt && item.publishedAt.trim().length > 0);
        assert.notEqual(item.publishedAt, '•');
      }

      const webSpace = loadScratchJson('search_web_space_page_1.json');
      const webFeed = normalizeFeedResponse(webSpace);
      assert.ok(webFeed.items.length > 0, 'Web search should return items');
      for (const item of webFeed.items) {
        assert.ok(item.id && item.id.trim().length > 0);
        assert.ok(item.title && item.title.trim().length > 0);
        assert.ok(item.channelTitle && item.channelTitle.trim().length > 0);
        assert.ok(item.views && item.views.trim().length > 0);
        assert.ok(item.publishedAt && item.publishedAt.trim().length > 0);
        assert.notEqual(item.publishedAt, '•');
      }
    });
  });
});
