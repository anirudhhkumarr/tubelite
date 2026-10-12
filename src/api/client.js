/**
 * LiteTube InnerTube Gateway Client
 * Proxies standardized requests through the Cloudflare Worker gateway with authenticated TVHTML5 identity.
 */

export const DEFAULT_WORKER_URL = 'https://litetube-gateway.anirudhkumar.workers.dev';

export async function callInnerTube(endpoint, payload, options = {}) {
  return callViaWorker(endpoint, payload, options);
}

/** Proxied call through the Cloudflare Worker gateway */
async function callViaWorker(endpoint, payload, options = {}) {
  const gatewayUrl = (options.workerUrl && String(options.workerUrl).trim()) || DEFAULT_WORKER_URL;
  const url = `${gatewayUrl.replace(/\/+$/, '')}/api/innertube/${endpoint}`;

  const clientName = payload?.context?.client?.clientName || 'TVHTML5';
  const clientVersion = payload?.context?.client?.clientVersion || '7.20240901.00.00';
  const clientNameHeader = clientName;

  const headers = {
    'Content-Type': 'application/json',
    'X-YouTube-Client-Name': clientNameHeader,
    'X-YouTube-Client-Version': clientVersion
  };

  if (options.accessToken) {
    headers['Authorization'] = `Bearer ${options.accessToken}`;
  }

  let currentHeaders = { ...headers };
  const MAX_CLIENT_RETRIES = 2;

  for (let attempt = 0; attempt <= MAX_CLIENT_RETRIES; attempt++) {
    const res = await fetch(url, {
      method: 'POST',
      headers: currentHeaders,
      body: JSON.stringify(payload)
    });

    if (res.ok) {
      try {
        const data = await res.json();
        if (data) return data;
      } catch {}
    }

    if (res.status === 429 && attempt < MAX_CLIENT_RETRIES) {
      await new Promise(resolve => setTimeout(resolve, (attempt + 1) * 1200));
      continue;
    }

    const err = new Error(`Gateway error (${res.status}): ${res.statusText}`);
    err.status = res.status;
    throw err;
  }
}

export async function fetchContinuation(endpoint, continuationToken, options = {}) {
  const isTv = options.clientType === 'TVHTML5' || options.clientName === 'TVHTML5' || (!options.clientType && !options.clientName);
  const clientName = options.clientName || (isTv ? 'TVHTML5' : 'WEB');
  const clientVersion = options.clientVersion || (isTv ? '7.20240901.00.00' : '2.20240901.00.00');
  const region = options.region || 'US';

  const payload = {
    context: {
      client: {
        clientName,
        clientVersion,
        hl: 'en',
        gl: region
      }
    },
    continuation: continuationToken
  };

  return callInnerTube(endpoint, payload, options);
}
