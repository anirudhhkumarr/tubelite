export const ALLOWED_YOUTUBE_ORIGINS = new Set([
  'https://www.youtube.com',
  'https://www.youtube-nocookie.com'
]);

export function isAllowedOrigin(origin) {
  if (!origin || typeof origin !== 'string') return false;
  return ALLOWED_YOUTUBE_ORIGINS.has(origin);
}

export function sendListeningHandshake(iframe) {
  if (!iframe?.contentWindow) return false;
  try {
    iframe.contentWindow.postMessage(
      JSON.stringify({ event: 'listening', id: 1, channel: 'widget' }),
      '*'
    );
    return true;
  } catch {
    return false;
  }
}

export function getStreamDesyncReason(data, targetVideoId) {
  if (!data) return null;

  const info = data.info || (data.event === 'infoDelivery' ? data : null);
  if (!info) return null;

  const progress = info.progressState;
  if (progress) {
    if (progress.allowSeeking === false) {
      const dur = typeof progress.duration === 'number' ? `${progress.duration}s` : 'unknown';
      return `locked-seeking (progressState.allowSeeking=false, duration=${dur})`;
    }

    if (
      typeof progress.seekableEnd === 'number' &&
      progress.seekableEnd === 0 &&
      typeof info.currentTime === 'number' &&
      info.currentTime > 0.5
    ) {
      return `zero-seekable-window (seekableEnd=0 at ${info.currentTime.toFixed(1)}s)`;
    }
  }

  if (
    info.videoData &&
    info.videoData.video_id &&
    targetVideoId &&
    info.videoData.video_id !== targetVideoId
  ) {
    return `video_id mismatch ("${info.videoData.video_id}" !== "${targetVideoId}")`;
  }

  return null;
}

export function detectStreamDesync(data, targetVideoId) {
  return getStreamDesyncReason(data, targetVideoId) !== null;
}

export function sendPlayerCommand(iframe, func, args = []) {
  if (!iframe) {
    logStreamWarning('StreamManager', `Cannot send "${func}": iframe element is null`);
    return false;
  }
  if (!iframe.contentWindow) {
    logStreamWarning('StreamManager', `Cannot send "${func}": iframe.contentWindow is inaccessible`);
    return false;
  }
  try {
    iframe.contentWindow.postMessage(
      JSON.stringify({
        event: 'command',
        func,
        args
      }),
      '*'
    );
    logStreamVerbose(`postMessage dispatched → ${func}`, { args });
    return true;
  } catch (err) {
    logStreamWarning('StreamManager', `Failed to post "${func}" command: ${err.message}`, { error: err });
    return false;
  }
}

export function isLocalhost() {
  if (typeof window === 'undefined' || !window.location) return false;
  const h = window.location.hostname;
  return h === 'localhost' || h === '127.0.0.1' || h === '[::1]' || (typeof h === 'string' && h.endsWith('.local'));
}

export function isDevMode() {
  try {
    if (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.DEV) {
      return true;
    }
  } catch {}
  return isLocalhost();
}

export const PLAYER_STATE_MAP = {
  '-1': 'UNSTARTED',
  '0': 'ENDED',
  '1': 'PLAYING',
  '2': 'PAUSED',
  '3': 'BUFFERING',
  '5': 'VIDEO_CUED'
};

export function getYouTubeErrorMessage(code) {
  switch (Number(code)) {
    case 2:
      return 'Invalid parameter value (e.g. malformed video ID)';
    case 5:
      return 'HTML5 player error (cannot be played in HTML5 player)';
    case 100:
      return 'Video not found (removed or marked private)';
    case 101:
    case 150:
      return 'Video owner does not allow embedded playback';
    default:
      return `Unknown player error (${code})`;
  }
}

export function logStreamDebug(label, payload) {
  if (!isDevMode()) return;
  const prefix = '%c[LiteTube Stream]';
  const prefixStyle = 'background: #2997ff; color: #ffffff; padding: 2px 6px; border-radius: 4px; font-weight: 600; font-size: 11px;';
  if (payload !== undefined) {
    console.log(`${prefix}%c ${label}`, prefixStyle, 'color: inherit; font-weight: 500;', payload);
  } else {
    console.log(`${prefix}%c ${label}`, prefixStyle, 'color: inherit; font-weight: 500;');
  }
}

export function logStreamEvent(component, action, details) {
  if (!isDevMode()) return;
  const prefix = `%c[LiteTube ${component}]`;
  const prefixStyle = 'background: #00875a; color: #ffffff; padding: 2px 6px; border-radius: 4px; font-weight: 700; font-size: 11px;';
  if (details !== undefined) {
    console.log(`${prefix}%c ${action}`, prefixStyle, 'color: inherit; font-weight: 600;', details);
  } else {
    console.log(`${prefix}%c ${action}`, prefixStyle, 'color: inherit; font-weight: 600;');
  }
}

export function logStreamWarning(component, reason, details) {
  if (!isDevMode()) return;
  const prefix = `%c[LiteTube ${component}] ⚠️`;
  const prefixStyle = 'background: #de350b; color: #ffffff; padding: 2px 6px; border-radius: 4px; font-weight: 700; font-size: 11px;';
  if (details !== undefined) {
    console.warn(`${prefix}%c ${reason}`, prefixStyle, 'color: inherit; font-weight: 600;', details);
  } else {
    console.warn(`${prefix}%c ${reason}`, prefixStyle, 'color: inherit; font-weight: 600;');
  }
}

export function logStreamVerbose(label, payload) {
  if (!isDevMode()) return;
  const prefix = '%c[LiteTube Stream:Verbose]';
  const prefixStyle = 'background: #5243aa; color: #ffffff; padding: 2px 6px; border-radius: 4px; font-weight: 600; font-size: 10px;';
  if (payload !== undefined) {
    console.log(`${prefix}%c ${label}`, prefixStyle, 'color: #888; font-weight: 400;', payload);
  } else {
    console.log(`${prefix}%c ${label}`, prefixStyle, 'color: #888; font-weight: 400;');
  }
}
