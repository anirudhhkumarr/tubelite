// sanitizer.js

export function isShortVideo(item) {
  if (!item || typeof item !== 'object') return false;
  if (item.isShort === true) return true;
  // Check for reelItemRenderer (always a short)
  if (item.reelItemRenderer || item.shortsLockupViewModel) return true;

  // For standard videoRenderers, compactVideoRenderers, gridVideoRenderer, or tileRenderer
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
    const style = (ov?.thumbnailOverlayTimeStatusRenderer?.style || '').toUpperCase();
    const timeText = (
      ov?.thumbnailOverlayTimeStatusRenderer?.text?.simpleText ||
      ov?.thumbnailOverlayTimeStatusRenderer?.text?.runs?.[0]?.text ||
      ''
    ).toUpperCase();
    if (style === 'SHORTS' || timeText === 'SHORTS') {
      return true;
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
    durationStr = target.lengthText.simpleText || target.lengthText.runs?.[0]?.text || '';
  }

  if (durationStr && durationStr.split(':').length === 2) {
    const parts = durationStr.split(':');
    const m = parseInt(parts[0], 10);
    const s = parseInt(parts[1], 10);
    if (!isNaN(m) && !isNaN(s) && (m * 60 + s) < 60) {
      return true;
    }
  }

  return false;
}

export function isValidVideo(item) {
  if (!item || typeof item !== 'object') return false;

  // 1. Explicit non-video renderers returned by YouTube
  if (
    item.playlistRenderer ||
    item.compactPlaylistRenderer ||
    item.radioRenderer ||
    item.compactStationRenderer ||
    item.channelRenderer ||
    item.reelItemRenderer
  ) {
    return false;
  }

  // 2. Identify the target renderer
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

  if (!renderer) return false;

  // 3. YouTube contentType semantics
  const contentType = String(
    item.contentType ||
    renderer.contentType ||
    item.tileRenderer?.contentType ||
    item.lockupViewModel?.contentType ||
    ''
  ).toUpperCase();

  if (contentType) {
    // Playlists, channels, albums, mixes, and shorts
    if (
      contentType.includes('PLAYLIST') ||
      contentType.includes('CHANNEL') ||
      contentType.includes('ALBUM') ||
      contentType.includes('RADIO') ||
      contentType.includes('MIX') ||
      contentType.includes('SHORT') ||
      contentType.includes('REEL')
    ) {
      return false;
    }
    // Accept valid video/music/movie lockups
    if (
      contentType !== 'LOCKUP_CONTENT_TYPE_VIDEO' &&
      contentType !== 'LOCKUP_CONTENT_TYPE_MUSIC' &&
      contentType !== 'LOCKUP_CONTENT_TYPE_MOVIE' &&
      contentType !== 'TILE_CONTENT_TYPE_VIDEO' &&
      contentType !== 'TILE_CONTENT_TYPE_MOVIE' &&
      !contentType.includes('MOVIE') &&
      !contentType.includes('VIDEO')
    ) {
      return false;
    }
  }

  // 4. Validate navigation command: real videos target playback (watchEndpoint), not collection browse pages
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
    const ghostState = browseEndpoint.pageAnimation?.preloadPageConfig?.ghostState || '';
    if (ghostState === 'GHOST_STATE_EPISODIC_SHOW_PAGE') {
      return false;
    }
    // If the select action navigates to browse without any watchEndpoint, it is not a playable video
    if (!onSelect.watchEndpoint) {
      return false;
    }
  }

  // 5. Extract video identifier across YouTube schemas
  const id =
    onSelect?.watchEndpoint?.videoId ||
    renderer.videoId ||
    renderer.contentId ||
    item.contentId ||
    '';

  if (!id || typeof id !== 'string') return false;

  // YouTube identifier prefix invariants:
  // - VL: View List / Playlist browse identifier
  // - PL: Standard Playlists
  // - RD: Radio / Mix Playlists
  // - UU: Channel Uploads Playlists
  // - LL: Liked Videos Playlists
  // - FL: Favorites Playlists
  // - OLAK: Music Album Playlists
  // - UC: Channel IDs
  // - @: Channel Handles
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

  // 6. YouTube collection thumbnail & card stack invariants:
  // - Web: contentImage.collectionThumbnailViewModel (stacked cards)
  // - TV: thumbnailOverlayStackingEffectRenderer (stacked cards behind tile)
  if (renderer.contentImage?.collectionThumbnailViewModel) {
    return false;
  }

  const overlays =
    renderer.thumbnailOverlays ||
    renderer.header?.tileHeaderRenderer?.thumbnailOverlays ||
    [];

  for (const ov of overlays) {
    if (ov?.thumbnailOverlayStackingEffectRenderer) {
      return false;
    }
    const timeText = (
      ov?.thumbnailOverlayTimeStatusRenderer?.text?.simpleText ||
      ov?.thumbnailOverlayTimeStatusRenderer?.text?.runs?.map(r => r.text).join('') ||
      ''
    ).toLowerCase();
    if (timeText.includes('episode') || timeText.includes('video')) {
      return false;
    }
  }

  // 7. Check duration and shorts indicators
  if (isShortVideo(item) || isShortVideo(renderer)) {
    return false;
  }

  return true;
}

export function sanitizeContents(contentsArray) {
    let result = [];
    let validCount = 0;
    let continuationItem = null;

    for (const item of contentsArray) {
        if (!item) continue;
        
        // Save continuation token
        if (item.continuationItemRenderer) {
            continuationItem = item;
            continue;
        }

        // If it's a valid video, keep it
        if (isValidVideo(item)) {
            result.push(item);
            validCount++;
            continue;
        }
        
        // Handle wrappers
        if (item.richItemRenderer) {
            const content = item.richItemRenderer.content;
            if (isValidVideo(content)) {
                result.push(item);
                validCount++;
            }
            continue;
        }

        // We explicitly DROP all other content (shelves, sections, channels, playlists, etc.)
    }

    if (continuationItem) {
        result.push(continuationItem);
    }

    return { contents: result, validCount, continuationItem };
}

export function recursiveSanitize(obj) {
    let totalCount = 0;
    let lastContinuationItem = null;

    function walk(node) {
        if (Array.isArray(node)) {
            // A section list (e.g. sectionListRenderer.contents) contains section containers
            // and must NOT be sanitized as a flat video list.
            const isSectionList = node.some(it => it && (it.itemSectionRenderer || it.sectionListRenderer));
            const isVideoList = !isSectionList && node.some(it => it && (
                it.videoRenderer ||
                it.compactVideoRenderer ||
                it.gridVideoRenderer ||
                it.movieRenderer ||
                it.compactMovieRenderer ||
                it.gridMovieRenderer ||
                it.lockupViewModel ||
                it.tileRenderer ||
                it.richItemRenderer ||
                it.reelItemRenderer ||
                it.playlistRenderer ||
                it.compactPlaylistRenderer ||
                it.channelRenderer ||
                it.radioRenderer ||
                it.compactStationRenderer ||
                it.metadata?.tileMetadataRenderer ||
                (it.contentType && typeof it.contentType === 'string')
            ));

            if (isVideoList) {
                // This is an array of video items, we sanitize it directly
                const { contents, validCount, continuationItem } = sanitizeContents(node);
                node.length = 0; // clear array
                for (const c of contents) node.push(c);
                totalCount += validCount;
                if (continuationItem) lastContinuationItem = continuationItem;
                return;
            }

            // Not a video list: traverse each element and capture any continuation tokens
            for (const item of node) {
                if (item?.continuationItemRenderer) {
                    lastContinuationItem = item;
                }
                if (typeof item === 'object' && item !== null) {
                    walk(item);
                }
            }
        } else if (typeof node === 'object' && node !== null) {
            for (const key in node) {
                walk(node[key]);
            }
        }
    }

    walk(obj);
    return {
        sanitizedObj: obj,
        validCount: totalCount,
        continuationToken: lastContinuationItem?.continuationItemRenderer?.continuationEndpoint?.continuationCommand?.token,
        continuationItemObj: lastContinuationItem
    };
}

export function extractContinuationToken(jsonObj) {
  let token = null;
  function walk(node) {
      if (token) return;
      if (Array.isArray(node)) {
          for (const item of node) walk(item);
      } else if (typeof node === 'object' && node !== null) {
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

// Function to replace a continuation item in the tree
export function appendContentsAndReplaceToken(baseObj, newContentsArray, newContinuationItemObj) {
    let replaced = false;

    function walk(node) {
        if (replaced) return;
        if (Array.isArray(node)) {
            // Check if this array has a continuationItemRenderer as its last element
            if (node.length > 0 && node[node.length - 1].continuationItemRenderer) {
                // Special case for search: if the array has an itemSectionRenderer, append inside its contents
                if (node[0]?.itemSectionRenderer?.contents && Array.isArray(node[0].itemSectionRenderer.contents)) {
                    for (const c of newContentsArray) {
                        if (!c.continuationItemRenderer) {
                            node[0].itemSectionRenderer.contents.push(c);
                        }
                    }
                    if (newContinuationItemObj) {
                        node[node.length - 1] = newContinuationItemObj;
                    } else {
                        node.pop();
                    }
                    replaced = true;
                    return;
                }

                node.pop(); // remove old token
                for (const c of newContentsArray) {
                    if (!c.continuationItemRenderer) {
                        node.push(c);
                    }
                }
                if (newContinuationItemObj) {
                    node.push(newContinuationItemObj);
                }
                replaced = true;
                return;
            } else {
                for (const item of node) walk(item);
            }
        } else if (typeof node === 'object' && node !== null) {
            for (const key in node) walk(node[key]);
        }
    }

    walk(baseObj);
}

export function extractVideoContents(jsonObj) {
    let contents = [];
    function walk(node) {
        if (Array.isArray(node)) {
            if (node.length > 0 && (
                node[0].videoRenderer ||
                node[0].richItemRenderer ||
                node[0].compactVideoRenderer ||
                node[0].gridVideoRenderer ||
                node[0].lockupViewModel ||
                node[0].tileRenderer
            )) {
                for (const item of node) {
                   contents.push(item);
                }
                return;
            }
            for (const item of node) walk(item);
        } else if (typeof node === 'object' && node !== null) {
            for (const key in node) walk(node[key]);
        }
    }
    walk(jsonObj);
    return contents;
}
