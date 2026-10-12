// normalizer.js
// Enterprise-grade InnerTube Normalizer & Filter Engine for Cloudflare Worker

/**
 * Robust text extractor that concatenates all runs if present,
 * or extracts simpleText / content.
 */
export function extractRunsText(obj) {
  if (!obj) return '';
  if (typeof obj === 'string') return obj;
  if (typeof obj.content === 'string') return obj.content;
  if (typeof obj.simpleText === 'string') return obj.simpleText;
  if (Array.isArray(obj.runs)) {
    return obj.runs.map((r) => (typeof r?.text === 'string' ? r.text : '')).join('');
  }
  return '';
}

/**
 * Parses duration string ("MM:SS" or "HH:MM:SS") into total seconds.
 */
export function parseDurationToSeconds(duration) {
  if (typeof duration === 'number') return duration;
  if (!duration || typeof duration !== 'string') return null;

  const parts = duration.trim().split(':');
  if (parts.length === 2) {
    const min = parseInt(parts[0], 10);
    const sec = parseInt(parts[1], 10);
    if (!isNaN(min) && !isNaN(sec)) return min * 60 + sec;
  } else if (parts.length === 3) {
    const hr = parseInt(parts[0], 10);
    const min = parseInt(parts[1], 10);
    const sec = parseInt(parts[2], 10);
    if (!isNaN(hr) && !isNaN(min) && !isNaN(sec)) return hr * 3600 + min * 60 + sec;
  }

  return null;
}

/**
 * Parses human-readable view string (e.g. "1.2M views", "500K views") to integer.
 */
export function parseViewCount(views) {
  if (typeof views === 'number') return views;
  if (!views || typeof views !== 'string') return null;

  const cleaned = views.trim().toLowerCase();
  if (cleaned.includes('no view') || cleaned === '0 views' || cleaned === '0') return 0;

  const match = cleaned.match(/([\d,.]+)\s*(billion|million|thousand|[kmb])?\b/i);
  if (!match) return null;

  const numStr = match[1].replace(/,/g, '');
  let val = parseFloat(numStr);
  if (isNaN(val)) return null;

  const unit = match[2] ? match[2].toLowerCase() : '';
  if (unit === 'k' || unit === 'thousand') val *= 1000;
  else if (unit === 'm' || unit === 'million') val *= 1000000;
  else if (unit === 'b' || unit === 'billion') val *= 1000000000;

  return Math.round(val);
}

/**
 * Normalizes an exact or relative date string into standard relative format ("X days ago").
 */
export function formatRelativeDate(rawDate) {
  if (!rawDate || typeof rawDate !== 'string') return '';
  const trimmed = rawDate.trim();
  const cleaned = trimmed
    .replace(/^(Premiered|Streamed live on|Streamed on|Streamed|Published on|Published)\s+/i, '')
    .trim();

  if (/\b(ago|yesterday|today|now|just now)\b/i.test(cleaned)) {
    const compactMatch = cleaned.match(/^(\d+)\s*(d|w|mo|m|y)\s*ago$/i);
    if (compactMatch) {
      const count = parseInt(compactMatch[1], 10);
      const unitChar = compactMatch[2].toLowerCase();
      let unit = '';
      if (unitChar === 'd') unit = count === 1 ? 'day' : 'days';
      else if (unitChar === 'w') unit = count === 1 ? 'week' : 'weeks';
      else if (unitChar === 'mo') unit = count === 1 ? 'month' : 'months';
      else if (unitChar === 'm') unit = count === 1 ? 'minute' : 'minutes';
      else if (unitChar === 'y') unit = count === 1 ? 'year' : 'years';
      if (unit) return `${count} ${unit} ago`;
    }
    return cleaned;
  }

  const timestamp = Date.parse(cleaned);
  if (isNaN(timestamp)) return trimmed;

  const diffMs = Date.now() - timestamp;
  if (diffMs < 0) return 'Just now';

  const diffSeconds = Math.floor(diffMs / 1000);
  const diffMinutes = Math.floor(diffSeconds / 60);
  const diffHours = Math.floor(diffMinutes / 60);
  const diffDays = Math.floor(diffHours / 24);
  const diffWeeks = Math.floor(diffDays / 7);
  const diffMonths = Math.floor(diffDays / 30.4375);
  const diffYears = Math.floor(diffDays / 365.25);

  if (diffDays < 1) {
    if (diffHours < 1) {
      if (diffMinutes < 1) return 'Just now';
      return `${diffMinutes} ${diffMinutes === 1 ? 'minute' : 'minutes'} ago`;
    }
    return `${diffHours} ${diffHours === 1 ? 'hour' : 'hours'} ago`;
  }
  if (diffDays < 7) {
    return `${diffDays} ${diffDays === 1 ? 'day' : 'days'} ago`;
  }
  if (diffWeeks < 5) {
    return `${diffWeeks} ${diffWeeks === 1 ? 'week' : 'weeks'} ago`;
  }
  if (diffMonths < 12) {
    return `${diffMonths} ${diffMonths === 1 ? 'month' : 'months'} ago`;
  }
  return `${diffYears} ${diffYears === 1 ? 'year' : 'years'} ago`;
}

/**
 * Detects if a video renderer contains an official YouTube "WATCHED" or resume playback annotation.
 */
export function extractWatchedAnnotation(renderer, overlays = []) {
  let isWatched = false;
  let percentWatched = null;

  if (Array.isArray(overlays)) {
    for (const ov of overlays) {
      if (!ov) continue;

      const resumeRenderer = ov.thumbnailOverlayResumePlaybackRenderer;
      if (resumeRenderer && typeof resumeRenderer.percentDurationWatched === 'number') {
        percentWatched = resumeRenderer.percentDurationWatched;
        if (percentWatched >= 80) isWatched = true;
      }

      const progressBarVM = ov.thumbnailOverlayProgressBarViewModel;
      if (progressBarVM && typeof progressBarVM.progressBarPercentage === 'number') {
        percentWatched = progressBarVM.progressBarPercentage;
        if (percentWatched >= 80) isWatched = true;
      }

      const playbackStatus = ov.thumbnailOverlayPlaybackStatusRenderer;
      if (playbackStatus) {
        const texts = playbackStatus.texts || [];
        for (const t of texts) {
          const txt = typeof t === 'string' ? t : (t?.runs?.[0]?.text || t?.simpleText || '');
          if (txt.toUpperCase().includes('WATCHED')) isWatched = true;
        }
      }

      const timeStatus = ov.thumbnailOverlayTimeStatusRenderer;
      if (timeStatus) {
        const style = timeStatus.style || '';
        const text = timeStatus.text?.simpleText || timeStatus.text?.runs?.[0]?.text || '';
        if (style.toUpperCase() === 'WATCHED' || text.toUpperCase() === 'WATCHED') {
          isWatched = true;
        }
      }

      const badges = ov.thumbnailBottomOverlayViewModel?.badges || [];
      for (const b of badges) {
        const badgeText = b?.thumbnailBadgeViewModel?.text || '';
        if (badgeText.toUpperCase().includes('WATCHED')) isWatched = true;
      }
    }
  }

  if (renderer && Array.isArray(renderer.badges)) {
    for (const b of renderer.badges) {
      const label = b?.metadataBadgeRenderer?.label || b?.metadataBadgeRenderer?.tooltip || '';
      const style = b?.metadataBadgeRenderer?.style || '';
      if (label.toUpperCase().includes('WATCHED') || style.toUpperCase().includes('WATCHED')) {
        isWatched = true;
      }
    }
  }

  const lockupBadge = renderer?.metadata?.lockupMetadataViewModel?.badge?.badgeViewModel?.text || '';
  if (lockupBadge.toUpperCase().includes('WATCHED')) {
    isWatched = true;
  }

  return { isWatched, percentWatched };
}

/**
 * Extracts feedback tokens directly from schema-defined AST structures in YouTube payloads.
 * Extracts:
 * - feedbackToken: Video dismissal feedback token (e.g. "Not interested", "Hide", direct feedbackEndpoint)
 * - channelFeedbackToken: Channel dismissal feedback token (e.g. "Don't recommend channel")
 */
export function extractFeedbackTokens(renderer) {
  if (!renderer || typeof renderer !== 'object') {
    return { feedbackToken: null, channelFeedbackToken: null };
  }

  let videoFeedbackToken = renderer.feedbackEndpoint?.feedbackToken ||
                           renderer.serviceEndpoint?.feedbackEndpoint?.feedbackToken ||
                           null;
  let channelFeedbackToken = null;

  const menuItems =
    renderer.menu?.menuRenderer?.items ||
    renderer.onLongPressCommand?.showMenuCommand?.menu?.menuRenderer?.items ||
    renderer.header?.tileHeaderRenderer?.menu?.menuRenderer?.items ||
    [];

  for (const item of menuItems) {
    const serviceItem = item?.menuServiceItemRenderer;
    if (!serviceItem) continue;

    // 1. Direct feedback endpoint on menu item (e.g. "Not interested", "Hide")
    const directToken = serviceItem.serviceEndpoint?.feedbackEndpoint?.feedbackToken ||
                        serviceItem.command?.feedbackEndpoint?.feedbackToken;
    if (directToken) {
      videoFeedbackToken = directToken;
    }

    // 2. Channel dismissal popup confirm command (e.g. "Don't recommend channel")
    const popupCommands =
      serviceItem.command?.openPopupAction?.popup?.overlaySectionRenderer?.overlay?.overlayTwoPanelRenderer?.actionPanel?.overlayPanelRenderer?.content?.overlayPanelItemListRenderer?.items?.[0]?.compactLinkRenderer?.serviceEndpoint?.commandExecutorCommand?.commands;
    if (Array.isArray(popupCommands)) {
      for (const cmd of popupCommands) {
        if (cmd?.feedbackEndpoint?.feedbackToken) {
          channelFeedbackToken = cmd.feedbackEndpoint.feedbackToken;
          break;
        }
      }
    }
  }

  // Fallback for commandExecutorCommand on onLongPressCommand if present
  if (!videoFeedbackToken && Array.isArray(renderer.onLongPressCommand?.commandExecutorCommand?.commands)) {
    for (const cmd of renderer.onLongPressCommand.commandExecutorCommand.commands) {
      if (cmd?.feedbackEndpoint?.feedbackToken) {
        videoFeedbackToken = cmd.feedbackEndpoint.feedbackToken;
        break;
      }
    }
  }

  return {
    feedbackToken: videoFeedbackToken || null,
    channelFeedbackToken: channelFeedbackToken || null
  };
}

export function extractFeedbackToken(renderer) {
  return extractFeedbackTokens(renderer).feedbackToken;
}

/**
 * Determines if an item is a YouTube Short.
 */
export function isShortVideo(item) {
  if (!item || typeof item !== 'object') return false;
  if (item.isShort === true) return true;
  if (item.reelItemRenderer || item.shortsLockupViewModel) return true;

  const renderer =
    item.videoRenderer ||
    item.compactVideoRenderer ||
    item.gridVideoRenderer ||
    item.tileRenderer ||
    item.lockupViewModel ||
    item.movieRenderer ||
    item.compactMovieRenderer ||
    item.gridMovieRenderer ||
    (item.metadata?.tileMetadataRenderer ? item : null);

  const target = renderer || item;
  if (target.isShort === true) return true;

  // 1. ContentType enum check
  const contentType = String(target.contentType || item.contentType || '').toUpperCase();
  if (contentType.includes('SHORT') || contentType.includes('REEL')) {
    return true;
  }

  // 2. Aspect ratio enum check (e.g. LOCKUP_CONTENT_IMAGE_ASPECT_RATIO_VERTICAL / PORTRAIT)
  const aspectRatio = String(
    target.contentImage?.thumbnailViewModel?.contentImageAspectRatio ||
    target.contentImageAspectRatio ||
    target.thumbnail?.contentImageAspectRatio ||
    ''
  ).toUpperCase();
  if (aspectRatio.includes('VERTICAL') || aspectRatio.includes('PORTRAIT')) {
    return true;
  }

  // 3. Overlays check
  const overlays =
    target.thumbnailOverlays ||
    target.header?.tileHeaderRenderer?.thumbnailOverlays ||
    target.contentImage?.thumbnailViewModel?.overlays ||
    [];

  for (const ov of overlays) {
    const timeStatus = ov?.thumbnailOverlayTimeStatusRenderer;
    if (timeStatus) {
      const style = (timeStatus.style || '').toUpperCase();
      const text = extractRunsText(timeStatus.text).toUpperCase();
      if (style === 'SHORTS' || text === 'SHORTS') return true;
    }

    const badges = ov?.thumbnailBottomOverlayViewModel?.badges || [];
    for (const b of badges) {
      const badgeText = (b?.thumbnailBadgeViewModel?.text || '').toUpperCase();
      if (badgeText === 'SHORTS') return true;
    }
  }

  // 4. Navigation URL, reelWatchEndpoint, and player style/type enums
  const onTap =
    target.onSelectCommand ||
    target.navigationEndpoint ||
    target.rendererContext?.commandContext?.onTap?.innertubeCommand ||
    target.onTap?.innertubeCommand;

  if (onTap?.reelWatchEndpoint) return true;
  const navUrl = onTap?.commandMetadata?.webCommandMetadata?.url || '';
  if (navUrl.includes('/shorts/')) return true;

  const reelStyle = String(
    onTap?.reelWatchEndpoint?.overlay?.reelPlayerOverlayRenderer?.style ||
    target.overlay?.reelPlayerOverlayRenderer?.style ||
    ''
  ).toUpperCase();
  if (reelStyle.includes('SHORTS')) return true;

  const videoType = String(
    onTap?.reelWatchEndpoint?.videoType ||
    target.videoType ||
    ''
  ).toUpperCase();
  if (videoType.includes('REEL')) return true;

  // 5. Duration check (< 60s is considered a short)
  let durationStr = '';
  if (target.lengthText) {
    durationStr = extractRunsText(target.lengthText);
  }
  if (!durationStr && typeof target.duration === 'string') {
    durationStr = target.duration;
  }

  if (durationStr) {
    const sec = parseDurationToSeconds(durationStr);
    if (sec !== null && sec > 0 && sec < 60) {
      return true;
    }
  }

  return false;
}

/**
 * Validates if an item is a genuine playable video schema.
 */
export function isValidVideo(item, options = {}) {
  if (!item || typeof item !== 'object') return false;
  const { filterShorts = true } = options;

  // 1. Explicit non-video renderers
  if (
    item.playlistRenderer ||
    item.compactPlaylistRenderer ||
    item.radioRenderer ||
    item.compactStationRenderer ||
    item.channelRenderer ||
    item.gridChannelRenderer ||
    item.compactChannelRenderer ||
    item.gridPlaylistRenderer ||
    item.gridShelfViewModel ||
    item.reelItemRenderer ||
    item.reelShelfRenderer ||
    item.adSlotRenderer ||
    item.inFeedAdRenderer ||
    item.promotedSparklesWebRenderer ||
    item.statementBannerRenderer ||
    item.displayAdRenderer ||
    item.promotedVideoRenderer ||
    item.brandVideoSingletonRenderer
  ) {
    return false;
  }

  const renderer =
    item.videoRenderer ||
    item.compactVideoRenderer ||
    item.gridVideoRenderer ||
    item.tileRenderer ||
    item.lockupViewModel ||
    item.shortsLockupViewModel ||
    item.movieRenderer ||
    item.compactMovieRenderer ||
    item.gridMovieRenderer ||
    item.videoWithContextRenderer ||
    (item.metadata?.tileMetadataRenderer ? item : null);

  if (!renderer) return false;

  // 2. Check contentType
  const contentType = String(
    item.contentType ||
    renderer.contentType ||
    item.tileRenderer?.contentType ||
    item.lockupViewModel?.contentType ||
    ''
  ).toUpperCase();

  if (contentType) {
    if (
      contentType.includes('PLAYLIST') ||
      contentType.includes('CHANNEL') ||
      contentType.includes('ALBUM') ||
      contentType.includes('RADIO') ||
      contentType.includes('MIX') ||
      contentType.includes('POST') ||
      contentType.includes('GAME')
    ) {
      return false;
    }
    if (filterShorts && (contentType.includes('SHORT') || contentType.includes('REEL'))) {
      return false;
    }
    if (
      contentType !== 'LOCKUP_CONTENT_TYPE_VIDEO' &&
      contentType !== 'LOCKUP_CONTENT_TYPE_MUSIC' &&
      contentType !== 'LOCKUP_CONTENT_TYPE_MOVIE' &&
      contentType !== 'TILE_CONTENT_TYPE_VIDEO' &&
      contentType !== 'TILE_CONTENT_TYPE_MOVIE' &&
      !contentType.includes('MOVIE') &&
      !contentType.includes('VIDEO') &&
      (!filterShorts ? contentType !== 'LOCKUP_CONTENT_TYPE_SHORTS' : true)
    ) {
      return false;
    }
  }

  // 3. Validate navigation command & endpoints
  const onSelect =
    renderer.onSelectCommand ||
    renderer.navigationEndpoint ||
    renderer.rendererContext?.commandContext?.onTap?.innertubeCommand ||
    renderer.onTap?.innertubeCommand;

  const browseEndpoint = onSelect?.browseEndpoint;
  if (browseEndpoint) {
    const browseId = browseEndpoint.browseId || '';
    if (
      browseId.startsWith('VL') ||
      browseId.startsWith('PL') ||
      browseId.startsWith('RD') ||
      browseId.startsWith('UU') ||
      browseId.startsWith('LL') ||
      browseId.startsWith('FL') ||
      browseId.startsWith('OLAK') ||
      browseId.startsWith('UC') ||
      browseId.startsWith('@')
    ) {
      return false;
    }
    if (browseEndpoint.pageAnimation?.preloadPageConfig?.ghostState === 'GHOST_STATE_EPISODIC_SHOW_PAGE') {
      return false;
    }
    if (!onSelect.watchEndpoint) {
      return false;
    }
  }

  // 4. Extract and validate video ID
  const id =
    onSelect?.watchEndpoint?.videoId ||
    renderer.videoId ||
    renderer.contentId ||
    item.contentId ||
    '';

  if (!id || typeof id !== 'string') return false;

  if (
    id.startsWith('VL') ||
    id.startsWith('PL') ||
    id.startsWith('RD') ||
    id.startsWith('UU') ||
    id.startsWith('LL') ||
    id.startsWith('FL') ||
    id.startsWith('OLAK') ||
    id.startsWith('UC') ||
    id.startsWith('@')
  ) {
    return false;
  }

  // 5. Stacked collections
  if (renderer.contentImage?.collectionThumbnailViewModel) {
    return false;
  }

  const overlays =
    renderer.thumbnailOverlays ||
    renderer.header?.tileHeaderRenderer?.thumbnailOverlays ||
    renderer.contentImage?.thumbnailViewModel?.overlays ||
    [];

  for (const ov of overlays) {
    if (ov?.thumbnailOverlayStackingEffectRenderer) return false;
    const timeText = extractRunsText(ov?.thumbnailOverlayTimeStatusRenderer?.text).toLowerCase();
    if (timeText.includes('episode') || timeText.includes('video')) return false;
  }

  // 6. Strict shorts elimination if requested
  if (filterShorts && (isShortVideo(item) || isShortVideo(renderer))) {
    return false;
  }

  // 7. Exclude sponsored / ad items (e.g. adBadgeViewModel in tileRenderer lines or adPingingEndpoint)
  if (renderer.metadata?.tileMetadataRenderer?.lines) {
    const lines = renderer.metadata.tileMetadataRenderer.lines;
    const hasAdBadge = lines.some((l) =>
      (l.lineRenderer?.items || []).some((it) => it.lineItemRenderer?.badge?.adBadgeViewModel)
    );
    if (hasAdBadge) return false;
  }

  const firstVisible = renderer.onFirstVisibleCommand || item.onFirstVisibleCommand;
  if (firstVisible?.commandExecutorCommand?.commands?.some((c) => c.adPingingEndpoint)) {
    return false;
  }

  return true;
}

/**
 * Extracts channel avatar / thumbnail URL from diverse InnerTube structures.
 */
function extractChannelThumbnailURL(node) {
  if (!node || typeof node !== 'object') return null;

  // Direct sources array (avatarViewModel.image)
  const sources = node.sources || node.avatarViewModel?.image?.sources || node.image?.sources;
  if (Array.isArray(sources) && sources.length > 0) {
    const last = sources[sources.length - 1]?.url || sources[0]?.url;
    if (last) return normalizeThumbnailUrl(last);
  }

  // Direct thumbnails array
  const thumbs = node.thumbnails || node.channelThumbnail?.thumbnails || node.thumbnail?.thumbnails;
  if (Array.isArray(thumbs) && thumbs.length > 0) {
    const last = thumbs[thumbs.length - 1]?.url || thumbs[0]?.url;
    if (last) return normalizeThumbnailUrl(last);
  }

  // DecoratedAvatarViewModel
  const decorated = node.decoratedAvatarViewModel?.avatar?.avatarViewModel?.image?.sources;
  if (Array.isArray(decorated) && decorated.length > 0) {
    const last = decorated[decorated.length - 1]?.url || decorated[0]?.url;
    if (last) return normalizeThumbnailUrl(last);
  }

  return null;
}

function normalizeThumbnailUrl(url) {
  if (!url || typeof url !== 'string') return null;
  if (url.startsWith('//')) return `https:${url}`;
  return url;
}

/**
 * Parses any video renderer into the standardized VideoItem schema.
 */
export function parseVideoNode(item, options = {}) {
  if (!item) return null;
  const { filterShorts = true } = options;
  if (!isValidVideo(item, { filterShorts })) return null;

  const renderer =
    item.videoRenderer ||
    item.compactVideoRenderer ||
    item.gridVideoRenderer ||
    item.tileRenderer ||
    item.lockupViewModel ||
    item.shortsLockupViewModel ||
    item.movieRenderer ||
    item.compactMovieRenderer ||
    item.gridMovieRenderer ||
    item.videoWithContextRenderer ||
    (item.metadata?.tileMetadataRenderer ? item : null);

  if (!renderer) return null;

  let type = 'videoRenderer';
  if (item.tileRenderer) type = 'tileRenderer';
  else if (item.lockupViewModel) type = 'lockupViewModel';
  else if (item.shortsLockupViewModel) type = 'shortsLockupViewModel';
  else if (item.compactVideoRenderer) type = 'compactVideoRenderer';
  else if (item.gridVideoRenderer) type = 'gridVideoRenderer';
  else if (item.movieRenderer) type = 'movieRenderer';
  else if (item.videoWithContextRenderer) type = 'videoWithContextRenderer';

  const onSelect =
    renderer.onSelectCommand ||
    renderer.navigationEndpoint ||
    renderer.rendererContext?.commandContext?.onTap?.innertubeCommand ||
    renderer.onTap?.innertubeCommand;

  const id =
    onSelect?.watchEndpoint?.videoId ||
    renderer.videoId ||
    renderer.contentId ||
    item.contentId ||
    '';

  if (!id || typeof id !== 'string') return null;

  const isShort = isShortVideo(item) || isShortVideo(renderer);
  if (filterShorts && isShort) return null;

  // Title extraction
  let title = '';
  if (renderer.title) {
    title = extractRunsText(renderer.title);
  }
  if (!title && renderer.headline) {
    title = extractRunsText(renderer.headline);
  }
  if (!title && renderer.metadata?.lockupMetadataViewModel?.title) {
    title = extractRunsText(renderer.metadata.lockupMetadataViewModel.title);
  }
  if (!title && renderer.header?.tileHeaderRenderer?.title) {
    title = extractRunsText(renderer.header.tileHeaderRenderer.title);
  }
  if (!title && renderer.metadata?.tileMetadataRenderer?.title) {
    title = extractRunsText(renderer.metadata.tileMetadataRenderer.title);
  }

  // Channel Title & ID extraction
  let channelTitle = '';
  let channelId = null;

  if (renderer.ownerText) {
    channelTitle = extractRunsText(renderer.ownerText);
    channelId = renderer.ownerText.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId || null;
  }
  if (!channelTitle && renderer.shortBylineText) {
    channelTitle = extractRunsText(renderer.shortBylineText);
    channelId = renderer.shortBylineText.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId || null;
  }
  if (!channelTitle && renderer.longBylineText) {
    channelTitle = extractRunsText(renderer.longBylineText);
    channelId = renderer.longBylineText.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId || null;
  }

  // Views & Published Time
  let views = '';
  let publishedAt = '';

  if (renderer.viewCountText) {
    views = extractRunsText(renderer.viewCountText);
  } else if (renderer.shortViewCountText) {
    views = extractRunsText(renderer.shortViewCountText);
  }

  if (renderer.publishedTimeText) {
    publishedAt = extractRunsText(renderer.publishedTimeText);
  }

  // Lockup metadata extraction (Web / Modern TV lockupViewModel)
  const lockupMeta = renderer.metadata?.lockupMetadataViewModel;
  if (lockupMeta) {
    // Channel ID directly from avatar browse endpoint
    const avatar = lockupMeta.image?.decoratedAvatarViewModel;
    const avatarBrowseId = avatar?.rendererContext?.commandContext?.onTap?.innertubeCommand?.browseEndpoint?.browseId;
    if (avatarBrowseId && avatarBrowseId.startsWith('UC') && !channelId) {
      channelId = avatarBrowseId;
    }

    if (lockupMeta.metadata?.contentMetadataViewModel?.metadataRows) {
      const rows = lockupMeta.metadata.contentMetadataViewModel.metadataRows;
      if (rows.length === 1) {
        // Single row containing parts
        const parts = (rows[0].metadataParts || rows[0].parts || []).filter((p) => {
          const txt = extractRunsText(p.text);
          return txt && txt.trim() !== '•';
        });
        if (parts.length >= 3) {
          if (!channelTitle) channelTitle = extractRunsText(parts[0].text).trim();
          if (!views) views = extractRunsText(parts[1].text).trim();
          if (!publishedAt) publishedAt = (extractRunsText(parts[2].text) || parts[2].accessibilityLabel || '').trim();
        } else if (parts.length === 2) {
          if (!channelTitle) channelTitle = extractRunsText(parts[0].text).trim();
          if (!views) views = extractRunsText(parts[1].text).trim();
        } else if (parts.length === 1) {
          if (!channelTitle) channelTitle = extractRunsText(parts[0].text).trim();
        }
      } else if (rows.length >= 2) {
        let channelParts = null;
        let metricsParts = null;

        for (const row of rows) {
          const parts = (row.metadataParts || row.parts || []).filter((p) => {
            const txt = extractRunsText(p.text);
            return txt && txt.trim() !== '•';
          });
          if (!parts.length) continue;

          const hasChannelBrowseId = parts.some((p) => {
            const bId =
              p.commandContext?.onTap?.innertubeCommand?.browseEndpoint?.browseId ||
              p.text?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId ||
              '';
            return bId && (bId.startsWith('UC') || bId.startsWith('@'));
          });

          const isMetrics =
            !hasChannelBrowseId &&
            (parts.length >= 2 || parts.some((p) => p.accessibilityLabel || p.text?.accessibility?.accessibilityData?.label));

          if (hasChannelBrowseId) {
            channelParts = parts;
          } else if (isMetrics) {
            metricsParts = parts;
          } else if (!channelParts) {
            channelParts = parts;
          } else if (!metricsParts) {
            metricsParts = parts;
          }
        }

        if (channelParts) {
          for (const p of channelParts) {
            const browseId =
              p.commandContext?.onTap?.innertubeCommand?.browseEndpoint?.browseId ||
              p.text?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId ||
              '';
            if (browseId && (browseId.startsWith('UC') || browseId.startsWith('@')) && !channelId) {
              channelId = browseId;
            }
            const text = extractRunsText(p.text);
            if (text && !channelTitle) {
              channelTitle = text.trim();
            }
          }
        }

        if (metricsParts) {
          if (metricsParts.length >= 2) {
            if (!views) views = (metricsParts[0].accessibilityLabel || metricsParts[0].text?.accessibility?.accessibilityData?.label || extractRunsText(metricsParts[0].text)).trim();
            if (!publishedAt) publishedAt = (extractRunsText(metricsParts[1].text) || metricsParts[1].accessibilityLabel || '').trim();
          } else if (metricsParts.length === 1) {
            if (!views) views = (metricsParts[0].accessibilityLabel || metricsParts[0].text?.accessibility?.accessibilityData?.label || extractRunsText(metricsParts[0].text)).trim();
          }
        }
      }
    }
  }

  // Tile metadata extraction (YouTube TV tileRenderer)
  const tileMeta = renderer.metadata?.tileMetadataRenderer;
  if (tileMeta) {
    if (!title && tileMeta.title) {
      title = extractRunsText(tileMeta.title);
    }
    if (tileMeta.lines && Array.isArray(tileMeta.lines)) {
      // Line 0: Channel info (skip delimiter bullets and badges)
      const line0Items = tileMeta.lines[0]?.lineRenderer?.items || tileMeta.lines[0]?.tileMetadataLineRenderer?.texts || tileMeta.lines[0]?.texts || [];
      for (const it of line0Items) {
        if (it.lineItemRenderer?.badge) continue;
        const textNode = it.lineItemRenderer?.text || (it.lineItemRenderer ? null : it);
        const text = extractRunsText(textNode);
        if (text && text.trim() !== '•') {
          if (!channelTitle) channelTitle = text.trim();
          const browseId = textNode?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId;
          if (browseId && browseId.startsWith('UC') && !channelId) {
            channelId = browseId;
          }
          break;
        }
      }

      // Line 1: Metrics (filter out badges and delimiter bullets)
      const line1Items = tileMeta.lines[1]?.lineRenderer?.items || tileMeta.lines[1]?.tileMetadataLineRenderer?.texts || tileMeta.lines[1]?.texts || [];
      const textSegments = [];
      for (const it of line1Items) {
        if (it.lineItemRenderer?.badge) continue;
        const textNode = it.lineItemRenderer?.text || (it.lineItemRenderer ? null : it);
        const text = extractRunsText(textNode);
        if (text && text.trim() !== '•') {
          textSegments.push(text.trim());
        }
      }

      if (textSegments.length >= 2) {
        if (!views) views = textSegments[0];
        if (!publishedAt) publishedAt = textSegments[1];
      } else if (textSegments.length === 1) {
        // If single segment (e.g. '245 watching'), treat as primary metric/views without speculative age
        if (!views) views = textSegments[0];
      }
    }
  }

  // Duration
  let duration = '';
  if (renderer.lengthText) {
    duration = extractRunsText(renderer.lengthText);
  }

  const overlays =
    renderer.thumbnailOverlays ||
    renderer.header?.tileHeaderRenderer?.thumbnailOverlays ||
    renderer.contentImage?.thumbnailViewModel?.overlays ||
    [];

  for (const ov of overlays) {
    if (!duration && ov?.thumbnailOverlayTimeStatusRenderer?.text) {
      duration = extractRunsText(ov.thumbnailOverlayTimeStatusRenderer.text);
    }
    if (!duration && ov?.thumbnailBottomOverlayViewModel?.badges) {
      for (const b of ov.thumbnailBottomOverlayViewModel.badges) {
        const badgeText = b?.thumbnailBadgeViewModel?.text;
        if (badgeText && badgeText.includes(':')) {
          duration = badgeText;
          break;
        }
      }
    }
  }

  const durationSeconds = parseDurationToSeconds(duration);
  const viewCount = parseViewCount(views);

  // Thumbnail URL
  let thumbnailUrl = `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;
  const thumbs =
    renderer.thumbnail?.thumbnails ||
    renderer.header?.tileHeaderRenderer?.thumbnail?.thumbnails ||
    renderer.contentImage?.thumbnailViewModel?.image?.sources;

  if (Array.isArray(thumbs) && thumbs.length > 0) {
    const best = thumbs[thumbs.length - 1]?.url || thumbs[0]?.url;
    if (best) thumbnailUrl = normalizeThumbnailUrl(best);
  }

  // Channel Thumbnail URL
  const channelThumbnailUrl =
    extractChannelThumbnailURL(renderer.channelThumbnailSupportedRenderers?.channelThumbnailWithLinkRenderer?.thumbnail) ||
    extractChannelThumbnailURL(renderer.metadata?.lockupMetadataViewModel?.image) ||
    extractChannelThumbnailURL(renderer.avatar) ||
    extractChannelThumbnailURL(renderer.decoratedAvatarViewModel) ||
    null;

  // Watched Annotation
  const { isWatched, percentWatched } = extractWatchedAnnotation(renderer, overlays);

  // Description
  let videoDescription = '';
  if (renderer.descriptionSnippet) {
    videoDescription = extractRunsText(renderer.descriptionSnippet);
  } else if (renderer.detailedMetadataSnippets?.[0]?.snippetText) {
    videoDescription = extractRunsText(renderer.detailedMetadataSnippets[0].snippetText);
  }

  const tokens = extractFeedbackTokens(renderer);

  return {
    id,
    title,
    channelTitle,
    channelId,
    duration,
    durationSeconds,
    views,
    viewCount,
    publishedAt,
    publishedTime: publishedAt,
    thumbnailUrl,
    channelThumbnailUrl,
    isWatched,
    percentDurationWatched: percentWatched,
    videoDescription,
    badge: isWatched ? 'WATCHED' : null,
    feedbackToken: tokens.feedbackToken,
    channelFeedbackToken: tokens.channelFeedbackToken,
    type,
    contentType: renderer.contentType || 'LOCKUP_CONTENT_TYPE_VIDEO'
  };
}

/**
 * Extracts continuation token from any InnerTube JSON response.
 */
export function extractContinuationToken(jsonObj) {
  let token = null;

  function walk(node) {
    if (token || !node) return;
    if (Array.isArray(node)) {
      for (const item of node) walk(item);
    } else if (typeof node === 'object') {
      if (node.continuationItemRenderer?.continuationEndpoint?.continuationCommand?.token) {
        token = node.continuationItemRenderer.continuationEndpoint.continuationCommand.token;
        return;
      }
      if (node.nextContinuationData?.continuation) {
        token = node.nextContinuationData.continuation;
        return;
      }
      for (const key in node) {
        walk(node[key]);
      }
    }
  }

  walk(jsonObj);
  return token;
}

/**
 * Recursively extracts and normalizes all valid videos from an InnerTube JSON response.
 */
export function normalizeFeedResponse(rawJson, options = {}) {
  if (!rawJson || typeof rawJson !== 'object') {
    return { items: [], continuationToken: null };
  }

  const { filterShorts = true } = options;
  const items = [];
  const seenIds = new Set();
  const continuationToken = extractContinuationToken(rawJson);

  function walk(node) {
    if (!node) return;

    if (Array.isArray(node)) {
      for (const item of node) walk(item);
      return;
    }

    if (typeof node === 'object') {
      // Reel item renderer support when filterShorts is false
      if (!filterShorts && node.reelItemRenderer) {
        const reel = node.reelItemRenderer;
        const id = reel.videoId;
        if (id && !seenIds.has(id)) {
          seenIds.add(id);
          const views = extractRunsText(reel.viewCountText);
          items.push({
            id,
            title: extractRunsText(reel.headline || reel.title),
            channelTitle: '',
            channelId: null,
            duration: '0:30',
            durationSeconds: 30,
            views,
            viewCount: parseViewCount(views),
            publishedAt: '',
            publishedTime: '',
            thumbnailUrl: reel.thumbnail?.thumbnails?.[0]?.url || `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
            channelThumbnailUrl: null,
            isWatched: false,
            percentDurationWatched: null,
            videoDescription: '',
            badge: 'SHORTS'
          });
        }
        return;
      }

      // Direct video items or wrappers
      const video = parseVideoNode(node, options);
      if (video) {
        if (!seenIds.has(video.id)) {
          seenIds.add(video.id);
          items.push(video);
        }
        return;
      }

      if (node.richItemRenderer?.content) {
        // Also check if richItemRenderer has reelItemRenderer
        if (!filterShorts && node.richItemRenderer.content.reelItemRenderer) {
          walk(node.richItemRenderer.content);
          return;
        }

        const richVideo = parseVideoNode(node.richItemRenderer.content, options);
        if (richVideo) {
          if (!seenIds.has(richVideo.id)) {
            seenIds.add(richVideo.id);
            items.push(richVideo);
          }
          return;
        }
      }

      // Drop known non-video shelves / ad slots early
      if (
        node.adSlotRenderer ||
        node.inFeedAdRenderer ||
        node.promotedSparklesWebRenderer ||
        node.statementBannerRenderer
      ) {
        return;
      }

      if (filterShorts) {
        if (
          node.reelShelfRenderer ||
          (node.richShelfRenderer && (extractRunsText(node.richShelfRenderer.title).toLowerCase().includes('shorts') || node.richShelfRenderer.isShorts))
        ) {
          return;
        }
      }

      for (const key in node) {
        // Skip responseContext and headers
        if (key === 'responseContext' || key === 'frameworkUpdates') continue;
        walk(node[key]);
      }
    }
  }

  walk(rawJson);

  return {
    items,
    continuationToken
  };
}

/**
 * Normalizes Watch Next response into primary video details, related videos list, and continuation.
 */
export function normalizeWatchNextResponse(rawJson) {
  if (!rawJson || typeof rawJson !== 'object') {
    return { details: null, items: [], continuationToken: null };
  }

  let details = null;
  const items = [];
  const seenIds = new Set();
  let continuationToken = extractContinuationToken(rawJson);

  // 1. Extract Primary Video Details from videoPrimaryInfoRenderer & videoSecondaryInfoRenderer
  let primaryInfo = null;
  let secondaryInfo = null;
  let videoMetadata = null;

  function findWatchMetadata(node) {
    if (!node || typeof node !== 'object') return;
    if (node.videoPrimaryInfoRenderer) primaryInfo = node.videoPrimaryInfoRenderer;
    if (node.videoSecondaryInfoRenderer) secondaryInfo = node.videoSecondaryInfoRenderer;
    if (node.videoMetadataRenderer && !primaryInfo) videoMetadata = node.videoMetadataRenderer;
    if (primaryInfo && secondaryInfo) return;

    for (const key in node) {
      if (primaryInfo && secondaryInfo) return;
      findWatchMetadata(node[key]);
    }
  }

  findWatchMetadata(rawJson);

  if (primaryInfo) {
    const currentVideoId =
      rawJson.currentVideoEndpoint?.watchEndpoint?.videoId ||
      primaryInfo.navigationEndpoint?.watchEndpoint?.videoId ||
      '';

    const title = extractRunsText(primaryInfo.title);
    const views =
      extractRunsText(primaryInfo.viewCount?.videoViewCountRenderer?.shortViewCount) ||
      extractRunsText(primaryInfo.viewCount?.videoViewCountRenderer?.viewCount);
    const rawDate =
      extractRunsText(primaryInfo.relativeDateText) ||
      primaryInfo.relativeDateText?.accessibility?.accessibilityData?.label ||
      primaryInfo.dateText?.accessibility?.accessibilityData?.label ||
      extractRunsText(primaryInfo.dateText);
    const publishedAt = formatRelativeDate(rawDate);

    let channelTitle = '';
    let channelId = null;
    let subscriberCount = '';
    let channelThumbnailUrl = null;
    let videoDescription = '';

    if (secondaryInfo) {
      const owner = secondaryInfo.owner?.videoOwnerRenderer;
      if (owner) {
        channelTitle = extractRunsText(owner.title);
        channelId = owner.navigationEndpoint?.browseEndpoint?.browseId || null;
        subscriberCount =
          owner.subscriberCountText?.accessibility?.accessibilityData?.label ||
          extractRunsText(owner.subscriberCountText);
        channelThumbnailUrl = extractChannelThumbnailURL(owner.thumbnail);
      }
      videoDescription = extractRunsText(secondaryInfo.description);
    }

    if (currentVideoId || title) {
      details = {
        id: currentVideoId,
        title,
        channelTitle,
        channelId,
        duration: '',
        durationSeconds: null,
        views,
        viewCount: parseViewCount(views),
        publishedAt,
        thumbnailUrl: currentVideoId ? `https://i.ytimg.com/vi/${currentVideoId}/hqdefault.jpg` : '',
        channelThumbnailUrl,
        isWatched: false,
        percentDurationWatched: null,
        videoDescription,
        subscriberCount,
        badge: null
      };
      if (currentVideoId) seenIds.add(currentVideoId);
    }
  } else if (videoMetadata) {
    const currentVideoId =
      videoMetadata.videoId ||
      rawJson.currentVideoEndpoint?.watchEndpoint?.videoId ||
      '';
    const title = extractRunsText(videoMetadata.title);
    const views =
      extractRunsText(videoMetadata.viewCount?.videoViewCountRenderer?.shortViewCount) ||
      extractRunsText(videoMetadata.viewCount?.videoViewCountRenderer?.viewCount);
    const rawDate =
      videoMetadata.dateText?.accessibility?.accessibilityData?.label ||
      extractRunsText(videoMetadata.dateText);
    const publishedAt = formatRelativeDate(rawDate);

    let channelTitle = '';
    let channelId = null;
    let subscriberCount = '';
    let channelThumbnailUrl = null;

    const owner = videoMetadata.owner?.videoOwnerRenderer;
    if (owner) {
      channelTitle = extractRunsText(owner.title);
      channelId = owner.navigationEndpoint?.browseEndpoint?.browseId || null;
      subscriberCount =
        owner.subscriberCountText?.accessibility?.accessibilityData?.label ||
        extractRunsText(owner.subscriberCountText);
      channelThumbnailUrl = extractChannelThumbnailURL(owner.thumbnail);
    }

    if (currentVideoId || title) {
      details = {
        id: currentVideoId,
        title,
        channelTitle,
        channelId,
        duration: '',
        durationSeconds: null,
        views,
        viewCount: parseViewCount(views),
        publishedAt,
        thumbnailUrl: currentVideoId ? `https://i.ytimg.com/vi/${currentVideoId}/hqdefault.jpg` : '',
        channelThumbnailUrl,
        isWatched: false,
        percentDurationWatched: null,
        videoDescription: '',
        subscriberCount,
        badge: null
      };
      if (currentVideoId) seenIds.add(currentVideoId);
    }
  }

  // 2. Extract Related / Secondary Videos
  const feed = normalizeFeedResponse(rawJson);
  for (const item of feed.items) {
    if (!seenIds.has(item.id)) {
      seenIds.add(item.id);
      items.push(item);
    }
  }

  if (!continuationToken) {
    continuationToken = feed.continuationToken;
  }

  return {
    details,
    items,
    continuationToken
  };
}
