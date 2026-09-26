// curator.js
// Probabilistic Recommendation Re-Ranking & Feed Curation Engine for Cloudflare Worker Gateway
// Powered by TypeSafe AI System One (Jev)

const JEV_API_ENDPOINT = 'https://api.typesafe.ai/v1/systemone';
const DEFAULT_TIMEOUT_MS = 1500;
const MAX_CURATION_ITEMS = 10;

/**
 * Resolves the private TypeSafe / Jev API key from Worker environment or process.
 * @param {object} [env] Cloudflare Worker environment bindings
 * @returns {string|null}
 */
export function resolveApiKey(env) {
  if (env?.TYPESAFE_API_KEY && typeof env.TYPESAFE_API_KEY === 'string') {
    return env.TYPESAFE_API_KEY.trim();
  }
  if (env?.JEV_API_KEY && typeof env.JEV_API_KEY === 'string') {
    return env.JEV_API_KEY.trim();
  }
  if (typeof process !== 'undefined' && process.env) {
    if (process.env.TYPESAFE_API_KEY) return process.env.TYPESAFE_API_KEY.trim();
    if (process.env.JEV_API_KEY) return process.env.JEV_API_KEY.trim();
  }
  return null;
}

/**
 * Executes a SystemOne query to TypeSafe AI with fail-open timeout handling.
 * @param {object} payload Request body matching SystemOne schema
 * @param {string} apiKey Private TypeSafe API key
 * @param {number} [timeoutMs] Request timeout in milliseconds
 * @returns {Promise<object|null>} Parsed JSON response or null on error/timeout
 */
export async function executeJevQuery(payload, apiKey, timeoutMs = DEFAULT_TIMEOUT_MS) {
  if (!apiKey || !payload) return null;

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(JEV_API_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`
      },
      body: JSON.stringify(payload),
      signal: controller.signal
    });

    if (!res.ok) {
      return null;
    }

    return await res.json();
  } catch (err) {
    // Fail open on network errors or aborts
    return null;
  } finally {
    clearTimeout(timeoutId);
  }
}

/**
 * Builds the Jev SystemOne payload for evaluating WatchNext recommendation candidates.
 * @param {object} currentVideo Active video details { title, channelTitle }
 * @param {Array<object>} candidates Candidate recommendation videos
 * @returns {object}
 */
export function buildWatchNextPayload(currentVideo, candidates) {
  const currentTitle = currentVideo?.title || 'Unknown Video';
  const currentChannel = currentVideo?.channelTitle || 'Unknown Channel';

  const candidateDescriptions = candidates
    .map((item, idx) => `[${idx + 1}] Title: ${item.title || 'Untitled'} (Channel: ${item.channelTitle || 'Unknown'})`)
    .join('\n');

  const state = `Current Video:\nTitle: ${currentTitle}\nChannel: ${currentChannel}\n\nCandidate Recommendations:\n${candidateDescriptions}`;

  const questions = {};
  candidates.forEach((_, idx) => {
    questions[`rec_${idx}`] = {
      type: 'score',
      instructions: `Rate how relevant, substantive, and high-value Candidate [${idx + 1}] is as a follow-up recommendation for someone watching the Current Video (1 to 5).`,
      criteria: ['1', '2', '3', '4', '5']
    };
  });

  return {
    model: 'jev-latest',
    state,
    questions
  };
}

/**
 * Curates and re-ranks WatchNext recommendations based on Jev relevance scores.
 * @param {object} watchNext Standardized WatchNextResponse { details, items, continuationToken }
 * @param {object} [env] Worker environment
 * @returns {Promise<object>} Curated WatchNextResponse (fails open to original on error)
 */
export async function curateWatchNext(watchNext, env) {
  if (!watchNext?.items || watchNext.items.length < 2) {
    return watchNext;
  }

  const apiKey = resolveApiKey(env);
  if (!apiKey) {
    return watchNext;
  }

  const candidatePool = watchNext.items.slice(0, MAX_CURATION_ITEMS);
  const remainingPool = watchNext.items.slice(MAX_CURATION_ITEMS);

  const payload = buildWatchNextPayload(watchNext.details, candidatePool);
  const response = await executeJevQuery(payload, apiKey);

  if (!response?.answers) {
    return watchNext;
  }

  const scoredCandidates = candidatePool.map((item, idx) => {
    const answer = response.answers[`rec_${idx}`];
    let score = 0;
    let confidence = 1;

    if (answer && typeof answer.score === 'number') {
      score = answer.score;
      if (typeof answer.confidence === 'number') {
        confidence = answer.confidence;
      }
    }

    // Effective rank score = calibrated score * confidence
    const effectiveScore = score * confidence;
    return { item, effectiveScore, originalIndex: idx };
  });

  // Sort descending by effectiveScore, preserving original relative order for ties
  scoredCandidates.sort((a, b) => {
    if (b.effectiveScore !== a.effectiveScore) {
      return b.effectiveScore - a.effectiveScore;
    }
    return a.originalIndex - b.originalIndex;
  });

  const reRankedItems = scoredCandidates.map(sc => sc.item).concat(remainingPool);

  return {
    ...watchNext,
    items: reRankedItems
  };
}

/**
 * Builds the Jev SystemOne payload for evaluating Feed candidates.
 * @param {Array<object>} candidates Candidate feed videos
 * @returns {object}
 */
export function buildFeedPayload(candidates) {
  const candidateDescriptions = candidates
    .map((item, idx) => `[${idx + 1}] Title: ${item.title || 'Untitled'} (Channel: ${item.channelTitle || 'Unknown'})`)
    .join('\n');

  const state = `Feed Candidates:\n${candidateDescriptions}`;

  const questions = {};
  candidates.forEach((_, idx) => {
    questions[`feed_${idx}`] = {
      type: 'score',
      instructions: `Rate the educational, technical, or production substance of Candidate [${idx + 1}] from 1 (sensationalist/low substance) to 5 (high educational/creative substance).`,
      criteria: ['1', '2', '3', '4', '5']
    };
  });

  return {
    model: 'jev-latest',
    state,
    questions
  };
}

/**
 * Curates and re-ranks Feed items based on Jev substance scores.
 * @param {object} feed Standardized FeedResponse { items, continuationToken }
 * @param {object} [env] Worker environment
 * @returns {Promise<object>} Curated FeedResponse (fails open to original on error)
 */
export async function curateFeed(feed, env) {
  if (!feed?.items || feed.items.length < 2) {
    return feed;
  }

  const apiKey = resolveApiKey(env);
  if (!apiKey) {
    return feed;
  }

  const candidatePool = feed.items.slice(0, MAX_CURATION_ITEMS);
  const remainingPool = feed.items.slice(MAX_CURATION_ITEMS);

  const payload = buildFeedPayload(candidatePool);
  const response = await executeJevQuery(payload, apiKey);

  if (!response?.answers) {
    return feed;
  }

  const scoredCandidates = candidatePool.map((item, idx) => {
    const answer = response.answers[`feed_${idx}`];
    let score = 0;
    let confidence = 1;

    if (answer && typeof answer.score === 'number') {
      score = answer.score;
      if (typeof answer.confidence === 'number') {
        confidence = answer.confidence;
      }
    }

    const effectiveScore = score * confidence;
    return { item, effectiveScore, originalIndex: idx };
  });

  // Sort descending by substance score, preserving original relative order for ties
  scoredCandidates.sort((a, b) => {
    if (b.effectiveScore !== a.effectiveScore) {
      return b.effectiveScore - a.effectiveScore;
    }
    return a.originalIndex - b.originalIndex;
  });

  const reRankedItems = scoredCandidates.map(sc => sc.item).concat(remainingPool);

  return {
    ...feed,
    items: reRankedItems
  };
}
