import { withCors } from './cors.js';

const ALLOWED_TELEMETRY_HOSTS = new Set([
  's.youtube.com',
  'www.youtube.com',
  'youtube.com'
]);

const DEFAULT_USER_AGENT =
  'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.5735.289 Safari/537.36 WebAppManager';

/**
 * Handles telemetry normalization and proxying to YouTube stats endpoints.
 * Resolves browser CORS limitations when synchronizing watch progress.
 */
export async function handleTelemetryRequest(request, url) {
  let targetUrlString = url.searchParams.get('url');

  if (!targetUrlString && url.pathname.startsWith('/api/stats/')) {
    const statsPath = url.pathname.replace(/^\/api\/stats\/?/, '');
    if (statsPath) {
      targetUrlString = `https://s.youtube.com/api/stats/${statsPath}${url.search}`;
    }
  }

  if (!targetUrlString) {
    return withCors(new Response(JSON.stringify({ error: 'Target telemetry URL required' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' }
    }));
  }

  let targetUrl;
  try {
    targetUrl = new URL(targetUrlString);
  } catch {
    return withCors(new Response(JSON.stringify({ error: 'Invalid telemetry URL' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' }
    }));
  }

  if (!ALLOWED_TELEMETRY_HOSTS.has(targetUrl.hostname)) {
    return withCors(new Response(JSON.stringify({ error: 'Disallowed telemetry host' }), {
      status: 403,
      headers: { 'Content-Type': 'application/json' }
    }));
  }

  const forwardHeaders = new Headers();
  const incomingUa = request.headers.get('User-Agent');
  forwardHeaders.set('User-Agent', incomingUa || DEFAULT_USER_AGENT);
  forwardHeaders.set('Origin', 'https://www.youtube.com');
  forwardHeaders.set('Referer', 'https://www.youtube.com/tv');

  if (request.headers.has('X-YouTube-Client-Name')) {
    forwardHeaders.set('X-YouTube-Client-Name', request.headers.get('X-YouTube-Client-Name'));
  }
  if (request.headers.has('X-YouTube-Client-Version')) {
    forwardHeaders.set('X-YouTube-Client-Version', request.headers.get('X-YouTube-Client-Version'));
  }
  if (request.headers.has('Authorization')) {
    forwardHeaders.set('Authorization', request.headers.get('Authorization'));
  }
  if (request.headers.has('X-YouTube-Cookie')) {
    forwardHeaders.set('Cookie', request.headers.get('X-YouTube-Cookie'));
  }

  try {
    const upstreamRes = await fetch(targetUrl.toString(), {
      method: request.method === 'POST' ? 'POST' : 'GET',
      headers: forwardHeaders
    });

    const isOk = upstreamRes.ok || upstreamRes.status === 204;
    return withCors(new Response(null, {
      status: upstreamRes.status || 204,
      headers: {
        'Content-Type': 'text/plain',
        'X-Telemetry-Status': isOk ? 'success' : 'upstream-error'
      }
    }));
  } catch (err) {
    return withCors(new Response(null, {
      status: 204,
      headers: {
        'Content-Type': 'text/plain',
        'X-Telemetry-Status': 'network-error'
      }
    }));
  }
}
