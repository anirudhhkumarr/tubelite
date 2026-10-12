/**
 * Generates a 16-character random alphanumeric Client Playback Nonce (CPN).
 */
export function generateCPN() {
  const charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
  let cpn = '';
  for (let i = 0; i < 16; i++) {
    cpn += charset.charAt(Math.floor(Math.random() * charset.length));
  }
  return cpn;
}

const DEFAULT_WORKER_URL = 'https://litetube-gateway.anirudhkumar.workers.dev';
const FLUSH_INTERVAL_MS = 15000; // 15s interval for telemetry updates

/**
 * Creates an unblocking, lightweight telemetry session for a video playback instance.
 */
export function createTelemetrySession({
  videoId,
  getAccessToken = async () => null,
  workerUrl = DEFAULT_WORKER_URL,
  clientName = 'TVHTML5',
  clientVersion = '7.20240901.00.00'
}) {
  if (!videoId) return null;

  const cpn = generateCPN();
  const sessionStartTime = Date.now();
  let trackingUrls = null;
  let isInitialized = false;
  let isInitializing = false;
  let isDisposed = false;
  let lastReportedTime = 0;
  let lastFlushTimestamp = 0;

  /**
   * Dispatches an asynchronous, fire-and-forget telemetry ping through the gateway.
   */
  async function dispatchPing(targetUrl, pingType = 'Watch progress', currentTime = null) {
    if (!targetUrl || isDisposed) return;

    try {
      const token = await getAccessToken().catch(() => null);
      const headers = {};
      if (token) {
        headers['Authorization'] = `Bearer ${token}`;
      }

      const gatewayUrl = `${workerUrl || DEFAULT_WORKER_URL}/api/telemetry/ping?url=${encodeURIComponent(targetUrl)}`;

      const res = await fetch(gatewayUrl, {
        method: 'GET',
        headers,
        keepalive: true
      }).catch(err => {
        console.warn(`[LiteTube Telemetry] ⚠️ Watchtime request failed: ${err?.message || 'Network error'}`);
        return null;
      });

      if (!res) return;

      const isNetworkError = res.headers?.get?.('X-Telemetry-Status') === 'network-error';
      if (!res.ok || isNetworkError) {
        const errorDesc = isNetworkError ? 'Upstream network timeout' : `HTTP ${res.status}`;
        console.warn(`[LiteTube Telemetry] ⚠️ Watchtime request failed (${errorDesc})`);
      } else {
        const timeLabel = typeof currentTime === 'number' ? ` @ ${currentTime.toFixed(1)}s` : '';
        console.log(`[LiteTube Telemetry] ${pingType} synced${timeLabel} (HTTP ${res.status})`);
      }
    } catch (err) {
      console.warn(`[LiteTube Telemetry] ⚠️ Watchtime request failed: ${err?.message || 'Unknown error'}`);
    }
  }

  /**
   * Initializes playback tracking by fetching the player metadata and dispatching the init ping.
   */
  async function init(initialTracking = null) {
    if (isInitialized || isInitializing || isDisposed) return;
    isInitializing = true;

    try {
      if (initialTracking?.videostatsPlaybackUrl?.baseUrl) {
        trackingUrls = initialTracking;
      } else {
        const token = await getAccessToken().catch(() => null);
        const headers = {
          'Content-Type': 'application/json',
          'X-YouTube-Client-Name': clientName,
          'X-YouTube-Client-Version': clientVersion
        };
        if (token) {
          headers['Authorization'] = `Bearer ${token}`;
        }

        const gatewayEndpoint = `${workerUrl || DEFAULT_WORKER_URL}/api/innertube/player`;
        const res = await fetch(gatewayEndpoint, {
          method: 'POST',
          headers,
          body: JSON.stringify({
            context: {
              client: { clientName, clientVersion }
            },
            videoId
          })
        }).catch(() => null);

        if (res && res.ok) {
          const data = await res.json().catch(() => null);
          trackingUrls = data?.playbackTracking || null;
        }
      }

      if (trackingUrls?.videostatsPlaybackUrl?.baseUrl && !isDisposed) {
        const pbBase = trackingUrls.videostatsPlaybackUrl.baseUrl;
        const fullPbUrl = `${pbBase}&cpn=${cpn}&ver=2&cmt=0&c=${clientName}&cver=${clientVersion}`;
        await dispatchPing(fullPbUrl, 'Session init', 0);
        isInitialized = true;
        lastFlushTimestamp = Date.now();
      }
    } catch {
      // Graceful fallback
    } finally {
      isInitializing = false;
    }
  }

  /**
   * Reports playback progress. Throttled to 15s intervals to protect performance.
   */
  function onProgress(currentTime, isPlaying = true) {
    if (isDisposed || typeof currentTime !== 'number' || currentTime < 0) return;

    if (!isInitialized && !isInitializing) {
      init();
      return;
    }

    const now = Date.now();
    if (now - lastFlushTimestamp < FLUSH_INTERVAL_MS) {
      return;
    }

    if (!trackingUrls?.videostatsWatchtimeUrl?.baseUrl) return;

    const wtBase = trackingUrls.videostatsWatchtimeUrl.baseUrl;
    const rt = Math.floor((now - sessionStartTime) / 1000);
    const cmt = currentTime.toFixed(1);
    const st = lastReportedTime.toFixed(1);
    const et = currentTime.toFixed(1);
    const state = isPlaying ? 'playing' : 'paused';

    const fullWtUrl = `${wtBase}&cpn=${cpn}&ver=2&cmt=${cmt}&st=${st}&et=${et}&state=${state}&rt=${rt}&c=${clientName}&cver=${clientVersion}`;

    lastReportedTime = currentTime;
    lastFlushTimestamp = now;

    return dispatchPing(fullWtUrl, 'Watch progress', currentTime);
  }

  /**
   * Reports state transitions (pause, finish, seek).
   */
  function onStateChange(stateName, currentTime = lastReportedTime) {
    if (isDisposed || !trackingUrls?.videostatsWatchtimeUrl?.baseUrl || !isInitialized) return;

    const now = Date.now();
    const wtBase = trackingUrls.videostatsWatchtimeUrl.baseUrl;
    const rt = Math.floor((now - sessionStartTime) / 1000);
    const cmt = typeof currentTime === 'number' ? currentTime.toFixed(1) : lastReportedTime.toFixed(1);
    const st = lastReportedTime.toFixed(1);
    const et = cmt;
    const state = stateName === 'PLAYING' ? 'playing' : 'paused';

    const fullWtUrl = `${wtBase}&cpn=${cpn}&ver=2&cmt=${cmt}&st=${st}&et=${et}&state=${state}&rt=${rt}&c=${clientName}&cver=${clientVersion}`;

    const numCurrentTime = typeof currentTime === 'number' ? currentTime : lastReportedTime;
    lastReportedTime = numCurrentTime;
    lastFlushTimestamp = now;

    const actionLabel = stateName === 'PLAYING' ? 'Playback resumed' : 'Playback paused';
    return dispatchPing(fullWtUrl, actionLabel, numCurrentTime);
  }

  /**
   * Tears down the telemetry session cleanly.
   */
  function dispose(finalCurrentTime = lastReportedTime) {
    if (isDisposed) return;
    let promise;
    if (isInitialized && trackingUrls?.videostatsWatchtimeUrl?.baseUrl) {
      promise = onStateChange('PAUSED', finalCurrentTime);
    }
    isDisposed = true;
    return promise;
  }

  return {
    cpn,
    init,
    onProgress,
    onStateChange,
    dispose,
    isInitialized: () => isInitialized,
    isDisposed: () => isDisposed
  };
}
