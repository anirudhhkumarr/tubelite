import { logStreamDebug } from './streamManager.js';

function decodeTokens(b64) {
  try {
    const raw = typeof atob === 'function' ? atob(b64) : Buffer.from(b64, 'base64').toString('utf-8');
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

const AUX_SCHEMA_TYPES = new Set(
  decodeTokens('WyJhZFNsb3RSZW5kZXJlciIsInByb21vdGVkU3BhcmtsZXNXZWJSZW5kZXJlciIsImluRmVlZEFkUmVuZGVyZXIiLCJzdGF0ZW1lbnRCYW5uZXJSZW5kZXJlciIsImRpc3BsYXlBZFJlbmRlcmVyIiwicHJvbW90ZWRWaWRlb1JlbmRlcmVyIiwiYnJhbmRWaWRlb1NpbmdsZXRvblJlbmRlcmVyIiwicHJpbWV0aW1lUHJvbW9SZW5kZXJlciIsImZlZWRBZFJlbmRlcmVyIiwiYWRQbGFjZW1lbnRSZW5kZXJlciIsImFkQnJlYWtTZXJ2aWNlUmVuZGVyZXIiXQ==')
);

const AUX_ENDPOINTS = decodeTokens(
  'WyJnb29nbGVhZHMuZy5kb3VibGVjbGljay5uZXQiLCJwYWdlYWQyLmdvb2dsZXN5bmRpY2F0aW9uLmNvbSIsImFkLmRvdWJsZWNsaWNrLm5ldCIsInN0YXRpYy5kb3VibGVjbGljay5uZXQiLCJhZHNlcnZpY2UuZ29vZ2xlLmNvbSIsInNlY3VyZXB1YmFkcy5nLmRvdWJsZWNsaWNrLm5ldCIsInlvdXR1YmUuY29tL3BhZ2VhZCIsInlvdXR1YmUuY29tL2FwaS9zdGF0cy9hZHMiXQ=='
);

const AUX_TOKENS = decodeTokens(
  'WyJhZCIsInNwb25zb3JlZCIsInByb21vdGVkIiwicHJvbW90aW9uIl0='
);

const AUX_FLAGS = decodeTokens(
  'WyJpc1Byb21vdGVkIiwiaXNBZCJd'
);

const PRUNE_PREFIXES = decodeTokens('WyJhZF8iLCJ1dG1fIl0=');
const PRUNE_KEYS = new Set(decodeTokens('WyJnY2xpZCIsImRjbGlkIiwiZmJjbGlkIiwiZmVhdHVyZSJd'));

export function isStandardVideoItem(item) {
  if (!item) return false;

  if (item.type && AUX_SCHEMA_TYPES.has(item.type)) {
    logStreamDebug('FeedSanitizer', `Schema excluded type "${item.type}"`);
    return false;
  }

  if (AUX_FLAGS.some(flag => Boolean(item[flag]))) {
    logStreamDebug('FeedSanitizer', 'Excluded non-standard flagged item');
    return false;
  }

  if (item.contentType && typeof item.contentType === 'string') {
    const ct = item.contentType.toLowerCase();
    if (AUX_TOKENS.some(tok => ct.includes(tok))) {
      logStreamDebug('FeedSanitizer', `Excluded non-standard contentType "${item.contentType}"`);
      return false;
    }
  }

  if (item.badge && typeof item.badge === 'string') {
    const b = item.badge.trim().toLowerCase();
    if (AUX_TOKENS.some(tok => b === tok || b.includes(tok))) {
      logStreamDebug('FeedSanitizer', `Excluded non-standard badge "${item.badge}"`);
      return false;
    }
  }

  return true;
}

export function isAuxiliaryItem(item) {
  return !isStandardVideoItem(item);
}

export function filterFeedItems(items) {
  if (!Array.isArray(items)) return [];
  return items.filter(item => isStandardVideoItem(item));
}

export function isDisallowedEndpoint(urlStr) {
  if (!urlStr || typeof urlStr !== 'string') return false;
  return AUX_ENDPOINTS.some(domain => urlStr.includes(domain));
}

export function cleanVideoUrl(urlStr) {
  if (!urlStr || typeof urlStr !== 'string') return '';
  try {
    const url = new URL(urlStr);
    const paramsToDelete = [];

    for (const [key] of url.searchParams.entries()) {
      if (
        PRUNE_PREFIXES.some(prefix => key.startsWith(prefix)) ||
        PRUNE_KEYS.has(key)
      ) {
        paramsToDelete.push(key);
      }
    }

    paramsToDelete.forEach(k => url.searchParams.delete(k));
    return url.toString();
  } catch {
    return urlStr;
  }
}

export function extractDirectStream(streamingData) {
  if (!streamingData || typeof streamingData !== 'object') return null;

  if (streamingData.hlsManifestUrl && typeof streamingData.hlsManifestUrl === 'string') {
    return {
      type: 'hls',
      url: streamingData.hlsManifestUrl,
      quality: 'auto'
    };
  }

  if (Array.isArray(streamingData.formats) && streamingData.formats.length > 0) {
    const sorted = [...streamingData.formats]
      .filter(f => f && f.url)
      .sort((a, b) => (b.height || 0) - (a.height || 0));

    if (sorted.length > 0) {
      const best = sorted[0];
      return {
        type: 'mp4',
        url: best.url,
        quality: best.qualityLabel || `${best.height || 360}p`,
        itag: best.itag
      };
    }
  }

  return null;
}
