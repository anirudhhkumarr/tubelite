// parser.js
// Lightweight Feed & Response Adapter for LiteTube Web App
// Thin consumer decoding standardized FeedResponse and WatchNextResponse from Cloudflare Worker gateway.

import {
  extractRunsText,
  extractWatchedAnnotation
} from '../../cloudflare/normalizer.js';

export { extractRunsText, extractWatchedAnnotation };

/**
 * Standardized browse and search parser.
 * Strictly decodes standardized FeedResponse models from Cloudflare Worker gateway.
 */
export function parseBrowseResponse(data) {
  if (!data || typeof data !== 'object') {
    return { videos: [], continuationToken: null };
  }

  const items = Array.isArray(data.items)
    ? data.items
    : Array.isArray(data.videos)
      ? data.videos
      : [];

  return {
    videos: items,
    continuationToken: data.continuationToken || null
  };
}

/**
 * Standardized watch-next parser.
 * Strictly decodes standardized WatchNextResponse models from Cloudflare Worker gateway.
 */
export function parseWatchNextResponse(data) {
  if (!data || typeof data !== 'object') {
    return { details: null, items: [], continuationToken: null };
  }

  return {
    details: data.details || null,
    items: Array.isArray(data.items) ? data.items : [],
    continuationToken: data.continuationToken || null
  };
}
