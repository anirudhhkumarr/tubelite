import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
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

describe('Cloudflare Worker Normalizer - Enterprise Parsing & Filtering', () => {
  it('extractRunsText handles string, simpleText, content, and runs array correctly', () => {
    assert.equal(extractRunsText('hello'), 'hello');
    assert.equal(extractRunsText({ simpleText: 'simple' }), 'simple');
    assert.equal(extractRunsText({ content: 'content' }), 'content');
    assert.equal(extractRunsText({ runs: [{ text: 'a ' }, { text: 'b' }] }), 'a b');
    assert.equal(extractRunsText(null), '');
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

    it('detects #shorts hashtag in title', () => {
      const item = {
        videoRenderer: {
          videoId: 'vid2',
          title: { simpleText: 'Funny cat video #shorts' }
        }
      };
      assert.equal(isShortVideo(item), true);
    });

    it('detects duration < 60s as shorts', () => {
      const item = {
        videoRenderer: {
          videoId: 'vid3',
          lengthText: { simpleText: '0:45' }
        }
      };
      assert.equal(isShortVideo(item), true);
    });

    it('preserves long-form videos (>60s)', () => {
      const item = {
        videoRenderer: {
          videoId: 'vid4',
          title: { simpleText: 'Full Length Video' },
          lengthText: { simpleText: '10:05' }
        }
      };
      assert.equal(isShortVideo(item), false);
    });
  });

  describe('Non-Video & Invalid Item Exclusion', () => {
    it('rejects playlists, channels, radios, and non-video schemas', () => {
      assert.equal(isValidVideo({ playlistRenderer: { playlistId: 'PL123' } }), false);
      assert.equal(isValidVideo({ channelRenderer: { channelId: 'UC123' } }), false);
      assert.equal(isValidVideo({ radioRenderer: { playlistId: 'RD123' } }), false);
      assert.equal(isValidVideo({ adSlotRenderer: {} }), false);
      assert.equal(isValidVideo({ promotedVideoRenderer: {} }), false);
    });

    it('rejects non-video IDs (VL, PL, RD, UU, UC, @)', () => {
      assert.equal(isValidVideo({ videoRenderer: { videoId: 'PLabcdef123456' } }), false);
      assert.equal(isValidVideo({ videoRenderer: { videoId: 'UCabcdef123456' } }), false);
      assert.equal(isValidVideo({ videoRenderer: { videoId: '@channelhandle' } }), false);
    });

    it('rejects stacked card collections', () => {
      assert.equal(isValidVideo({
        videoRenderer: {
          videoId: 'v1234567890',
          contentImage: { collectionThumbnailViewModel: {} }
        }
      }), false);
    });
  });

  describe('Full Normalization Pipeline', () => {
    it('normalizes heterogeneous browse payload into clean FeedResponse', () => {
      const rawPayload = {
        contents: {
          twoColumnBrowseResultsRenderer: {
            tabs: [{
              tabRenderer: {
                content: {
                  richGridRenderer: {
                    contents: [
                      // Valid video
                      {
                        richItemRenderer: {
                          content: {
                            videoRenderer: {
                              videoId: 'validVid123',
                              title: { runs: [{ text: 'Sample Long Form Video' }] },
                              ownerText: { runs: [{ text: 'Awesome Creator' }] },
                              viewCountText: { simpleText: '1.2M views' },
                              publishedTimeText: { simpleText: '2 days ago' },
                              lengthText: { simpleText: '14:22' },
                              thumbnail: {
                                thumbnails: [{ url: 'https://i.ytimg.com/vi/validVid123/hqdefault.jpg' }]
                              }
                            }
                          }
                        }
                      },
                      // Modern Lockup View Model (Valid)
                      {
                        lockupViewModel: {
                          contentId: 'lockupVid456',
                          contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
                          metadata: {
                            lockupMetadataViewModel: {
                              title: { content: 'Modern Lockup Video' },
                              metadata: {
                                contentMetadataViewModel: {
                                  metadataRows: [
                                    { parts: [{ text: { content: 'Tech Channel' } }] },
                                    { parts: [{ text: { content: '50K views' } }, { text: { content: '1 week ago' } }] }
                                  ]
                                }
                              }
                            }
                          },
                          contentImage: {
                            thumbnailViewModel: {
                              image: {
                                sources: [{ url: 'https://i.ytimg.com/vi/lockupVid456/hqdefault.jpg' }]
                              },
                              overlays: [{
                                thumbnailBottomOverlayViewModel: {
                                  badges: [{ thumbnailBadgeViewModel: { text: '8:45' } }]
                                }
                              }]
                            }
                          }
                        }
                      },
                      // Shorts (MUST BE FILTERED)
                      {
                        richItemRenderer: {
                          content: {
                            videoRenderer: {
                              videoId: 'shortDropMe',
                              title: { simpleText: 'Short clip #shorts' },
                              lengthText: { simpleText: '0:30' }
                            }
                          }
                        }
                      },
                      // Playlist (MUST BE FILTERED)
                      {
                        playlistRenderer: {
                          playlistId: 'PLplaylistDropMe'
                        }
                      },
                      // Continuation Item
                      {
                        continuationItemRenderer: {
                          continuationEndpoint: {
                            continuationCommand: {
                              token: 'next_page_token_abc'
                            }
                          }
                        }
                      }
                    ]
                  }
                }
              }
            }]
          }
        }
      };

      const feed = normalizeFeedResponse(rawPayload);

      assert.equal(feed.items.length, 2, 'Should only contain the 2 valid long-form videos');
      assert.equal(feed.continuationToken, 'next_page_token_abc');

      const v1 = feed.items[0];
      assert.equal(v1.id, 'validVid123');
      assert.equal(v1.title, 'Sample Long Form Video');
      assert.equal(v1.channelTitle, 'Awesome Creator');
      assert.equal(v1.duration, '14:22');
      assert.equal(v1.durationSeconds, 862);
      assert.equal(v1.views, '1.2M views');
      assert.equal(v1.viewCount, 1200000);
      assert.equal(v1.publishedAt, '2 days ago');
      assert.equal(v1.isShort, undefined);

      const v2 = feed.items[1];
      assert.equal(v2.id, 'lockupVid456');
      assert.equal(v2.title, 'Modern Lockup Video');
      assert.equal(v2.channelTitle, 'Tech Channel');
      assert.equal(v2.duration, '8:45');
      assert.equal(v2.durationSeconds, 525);
      assert.equal(v2.isShort, undefined);
    });

    it('normalizes Watch Next response into details, related items, and continuation', () => {
      const rawNext = {
        currentVideoEndpoint: {
          watchEndpoint: { videoId: 'mainVideoId1' }
        },
        contents: {
          twoColumnWatchNextResults: {
            results: {
              results: {
                contents: [
                  {
                    videoPrimaryInfoRenderer: {
                      title: { runs: [{ text: 'Main Playing Video' }] },
                      viewCount: { videoViewCountRenderer: { viewCount: { simpleText: '3.4M views' } } },
                      dateText: { simpleText: 'Premiered Oct 12, 2024' }
                    }
                  },
                  {
                    videoSecondaryInfoRenderer: {
                      owner: {
                        videoOwnerRenderer: {
                          title: { runs: [{ text: 'Main Channel' }] },
                          subscriberCountText: { simpleText: '2.1M subscribers' }
                        }
                      },
                      description: { simpleText: 'Full video description here...' }
                    }
                  }
                ]
              }
            },
            secondaryResults: {
              secondaryResults: {
                results: [
                  {
                    compactVideoRenderer: {
                      videoId: 'relatedVid1',
                      title: { simpleText: 'Related Video 1' },
                      shortBylineText: { simpleText: 'Related Creator' },
                      lengthText: { simpleText: '12:00' },
                      viewCountText: { simpleText: '400K views' }
                    }
                  },
                  // Related short (MUST BE DROPPED)
                  {
                    compactVideoRenderer: {
                      videoId: 'relatedShort',
                      title: { simpleText: 'Quick Short #shorts' },
                      lengthText: { simpleText: '0:20' }
                    }
                  }
                ]
              }
            }
          }
        }
      };

      const watchNext = normalizeWatchNextResponse(rawNext);

      assert.ok(watchNext.details, 'details should be present');
      assert.equal(watchNext.details.id, 'mainVideoId1');
      assert.equal(watchNext.details.title, 'Main Playing Video');
      assert.equal(watchNext.details.channelTitle, 'Main Channel');
      assert.equal(watchNext.details.subscriberCount, '2.1M subscribers');
      assert.equal(watchNext.details.videoDescription, 'Full video description here...');

      assert.equal(watchNext.items.length, 1);
      assert.equal(watchNext.items[0].id, 'relatedVid1');
      assert.equal(watchNext.items[0].isShort, undefined);
    });
  });
});
