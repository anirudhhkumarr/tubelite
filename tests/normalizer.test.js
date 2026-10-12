import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  extractRunsText,
  parseDurationToSeconds,
  parseViewCount,
  extractFeedbackToken,
  extractFeedbackTokens,
  formatRelativeDate,
  isShortVideo,
  isValidVideo,
  parseVideoNode,
  normalizeFeedResponse,
  normalizeWatchNextResponse
} from '../cloudflare/normalizer.js';

// Synthetic mock fixtures for normalizer validation without user data
const mockHomeFeed = {
  contents: {
    tvBrowseRenderer: {
      content: {
        tvSurfaceContentRenderer: {
          content: {
            sectionListRenderer: {
              contents: [
                {
                  shelfRenderer: {
                    content: {
                      horizontalListRenderer: {
                        items: [
                          {
                            tileRenderer: {
                              contentId: 'abc12345678',
                              header: {
                                tileHeaderRenderer: {
                                  thumbnail: {
                                    thumbnails: [{ url: 'https://i.ytimg.com/vi/abc12345678/hqdefault.jpg', width: 480, height: 360 }]
                                  },
                                  thumbnailOverlays: [
                                    {
                                      thumbnailOverlayTimeStatusRenderer: {
                                        text: { simpleText: '12:34' }
                                      }
                                    }
                                  ]
                                }
                              },
                              metadata: {
                                tileMetadataRenderer: {
                                  title: { simpleText: 'Test Video Title' },
                                  lines: [
                                    {
                                      lineRenderer: {
                                        items: [
                                          { lineItemRenderer: { text: { runs: [{ text: 'Test Channel' }] } } }
                                        ]
                                      }
                                    },
                                    {
                                      lineRenderer: {
                                        items: [
                                          { lineItemRenderer: { text: { simpleText: '1.2M views' } } },
                                          { lineItemRenderer: { text: { simpleText: '3 days ago' } } }
                                        ]
                                      }
                                    }
                                  ]
                                }
                              }
                            }
                          },
                          {
                            continuationItemRenderer: {
                              continuationEndpoint: {
                                continuationCommand: { token: 'continuation_token_123' }
                              }
                            }
                          }
                        ]
                      }
                    }
                  }
                }
              ]
            }
          }
        }
      }
    }
  }
};

const mockWatchNext = {
  contents: {
    singleColumnWatchNextResults: {
      results: {
        results: {
          contents: [
            {
              itemSectionRenderer: {
                contents: [
                  {
                    compactVideoRenderer: {
                      videoId: 'rel12345678',
                      title: { simpleText: 'Related Video Title' },
                      longBylineText: { runs: [{ text: 'Related Channel' }] },
                      viewCountText: { simpleText: '500K views' },
                      publishedTimeText: { simpleText: '1 week ago' },
                      lengthText: { simpleText: '8:45' },
                      thumbnail: {
                        thumbnails: [{ url: 'https://i.ytimg.com/vi/rel12345678/hqdefault.jpg' }]
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    }
  }
};

const mockSearchResults = {
  contents: {
    sectionListRenderer: {
      contents: [
        {
          itemSectionRenderer: {
            contents: [
              {
                videoRenderer: {
                  videoId: 'search123456',
                  title: { runs: [{ text: 'Search Result Video' }] },
                  ownerText: { runs: [{ text: 'Search Channel' }] },
                  viewCountText: { simpleText: '250K views' },
                  publishedTimeText: { simpleText: '5 days ago' },
                  lengthText: { simpleText: '15:20' },
                  thumbnail: {
                    thumbnails: [{ url: 'https://i.ytimg.com/vi/search123456/hqdefault.jpg' }]
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }
};

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

    it('formatRelativeDate converts exact dates, compact dates, and prefixes to relative format', () => {
      assert.equal(formatRelativeDate('2 days ago'), '2 days ago');
      assert.equal(formatRelativeDate('2d ago'), '2 days ago');
      assert.equal(formatRelativeDate('1w ago'), '1 week ago');
      assert.equal(formatRelativeDate('Premiered 3 days ago'), '3 days ago');
      assert.ok(formatRelativeDate('Oct 24, 2023').includes('ago'));
      assert.ok(formatRelativeDate('Streamed live on May 10, 2022').includes('ago'));
      assert.equal(formatRelativeDate(''), '');
      assert.equal(formatRelativeDate(null), '');
    });

    it('extractFeedbackToken extracts token from feedbackEndpoint or menuServiceItemRenderer', () => {
      assert.equal(extractFeedbackToken(null), null);
      assert.equal(extractFeedbackToken({}), null);

      const direct = { feedbackEndpoint: { feedbackToken: 'direct_token_123' } };
      assert.equal(extractFeedbackToken(direct), 'direct_token_123');

      const menu = {
        menu: {
          menuRenderer: {
            items: [
              {
                menuServiceItemRenderer: {
                  text: { runs: [{ text: 'Not interested' }] },
                  serviceEndpoint: {
                    feedbackEndpoint: { feedbackToken: 'menu_token_456' }
                  }
                }
              },
              {
                menuServiceItemRenderer: {
                  text: { runs: [{ text: "Don't recommend channel" }] },
                  command: {
                    openPopupAction: {
                      popup: {
                        overlaySectionRenderer: {
                          overlay: {
                            overlayTwoPanelRenderer: {
                              actionPanel: {
                                overlayPanelRenderer: {
                                  content: {
                                    overlayPanelItemListRenderer: {
                                      items: [
                                        {
                                          compactLinkRenderer: {
                                            serviceEndpoint: {
                                              commandExecutorCommand: {
                                                commands: [
                                                  {
                                                    feedbackEndpoint: { feedbackToken: 'channel_token_789' }
                                                  }
                                                ]
                                              }
                                            }
                                          }
                                        }
                                      ]
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            ]
          }
        }
      };

      const tokens = extractFeedbackTokens(menu);
      assert.equal(tokens.feedbackToken, 'menu_token_456');
      assert.equal(tokens.channelFeedbackToken, 'channel_token_789');
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

  describe('Feed & Watch Next Schema Normalization Validation', () => {
    it('normalizes synthetic TV Browse recommendations feed', () => {
      const feed = normalizeFeedResponse(mockHomeFeed);

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

    it('normalizes synthetic Watch Next recommendations', () => {
      const watchNext = normalizeWatchNextResponse(mockWatchNext);

      assert.ok(watchNext.items.length > 0, 'Watch next should contain related recommendation items');
      for (const item of watchNext.items) {
        assert.ok(item.id && item.id.trim().length > 0);
        assert.ok(item.title && item.title.trim().length > 0);
        assert.ok(item.channelTitle && item.channelTitle.trim().length > 0, `Item ${item.id} must have a channel title`);
        assert.ok(item.views && item.views.trim().length > 0, `Item ${item.id} must have views`);
        assert.ok(item.publishedAt && item.publishedAt.trim().length > 0, `Item ${item.id} must have publishedAt`);
        assert.notEqual(item.publishedAt, '•');
        assert.notEqual(item.publishedTime, '•');
      }
    });

    it('normalizes synthetic Search results', () => {
      const searchFeed = normalizeFeedResponse(mockSearchResults);
      assert.ok(searchFeed.items.length > 0, 'Search should return items');
      for (const item of searchFeed.items) {
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
