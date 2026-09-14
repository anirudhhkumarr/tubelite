// parser.js
// Lightweight Feed & Response Adapter for LiteTube Web App
// All heavy AST parsing & shorts filtering is performed centrally in Cloudflare Worker normalizer.

import {
  extractRunsText,
  extractWatchedAnnotation,
  normalizeFeedResponse,
  normalizeWatchNextResponse
} from '../../cloudflare/normalizer.js';

export { extractRunsText, extractWatchedAnnotation };

/**
 * Standardized browse and search parser.
 * Handles both the normalized FeedResponse schema from Cloudflare Worker
 * and provides transparent fallback for raw InnerTube ASTs.
 */
export function parseBrowseResponse(data) {
  if (!data || typeof data !== 'object') {
    return { videos: [], continuationToken: null };
  }

  // 1. Direct consumption of standardized FeedResponse from Cloudflare Worker
  if (Array.isArray(data.items)) {
    return {
      videos: data.items,
      continuationToken: data.continuationToken || null
    };
  }

  if (Array.isArray(data.videos)) {
    return {
      videos: data.videos,
      continuationToken: data.continuationToken || null
    };
  }

  // 2. Fallback: Parse raw InnerTube AST using centralized normalizer
  const normalized = normalizeFeedResponse(data, { filterShorts: true });
  return {
    videos: normalized.items,
    continuationToken: normalized.continuationToken
  };
}

/**
 * Standardized watch-next parser.
 */
export function parseWatchNextResponse(data) {
  if (!data || typeof data !== 'object') {
    return { details: null, items: [], continuationToken: null };
  }

  // 1. Direct consumption of standardized WatchNextResponse
  if (data.details !== undefined && Array.isArray(data.items)) {
    return {
      details: data.details,
      items: data.items,
      continuationToken: data.continuationToken || null
    };
  }

  // 2. Fallback: Parse raw InnerTube AST
  return normalizeWatchNextResponse(data);
}
