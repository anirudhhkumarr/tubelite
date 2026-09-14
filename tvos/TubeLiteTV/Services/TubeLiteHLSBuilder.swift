import Foundation

/// Builds compliant Apple HLS master and media playlists from YouTube fragmented MP4 (fMP4) adaptive streams.
///
/// Because YouTube InnerTube has deprecated server-side `hlsManifestUrl` generation for the vast majority
/// of catalog videos, this builder reads the fragmented MP4 SIDX (Segment Index) box from YouTube CDN using
/// small range requests (~300 bytes for video, ~180 bytes for audio), producing an RFC 8216-compliant HLS
/// presentation with `#EXT-X-MAP` and `#EXT-X-BYTERANGE` that AVPlayer natively decodes with hardware acceleration.
public enum TubeLiteHLSBuilder {
    
    public struct SynthesizedHLS {
        public let masterPlaylist: String
        public let videoPlaylist: String
        public let audioPlaylist: String
        public let subtitlePlaylists: [String: String]
        public let subtitleTracks: [TubeLiteGatewayClient.SubtitleTrack]
        public let selectedHeight: Int
        public let selectedCodec: String
        public let durationSeconds: Double
    }
    
    public struct Segment {
        public let duration: Double
        public let length: UInt32
        public let offset: UInt64
    }
    
    public struct ParsedStream {
        public let segments: [Segment]
        public let maxDuration: Int
        public let initLength: Int
        public let totalDuration: Double
    }
    
    /// Synthesizes HLS playlists from InnerTube `adaptiveFormats`.
    public static func build(
        from streamingData: [String: Any],
        subtitleTracks: [TubeLiteGatewayClient.SubtitleTrack] = [],
        session: URLSession = .shared,
        allowAV1: Bool = false,
        userAgent: String = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)"
    ) async -> SynthesizedHLS? {
        guard let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] else {
            return nil
        }
        
        // 1. Select best video format with initRange & indexRange
        var candidates: [[String: Any]] = []
        for format in adaptive {
            guard let mime = (format["mimeType"] as? String)?.lowercased(),
                  mime.hasPrefix("video/mp4"),
                  format["url"] is String,
                  format["initRange"] is [String: Any],
                  format["indexRange"] is [String: Any] else {
                continue
            }
            let isAV1 = mime.contains("av01")
            let isAVC = mime.contains("avc1")
            if (isAV1 && allowAV1) || isAVC {
                candidates.append(format)
            }
        }
        
        guard !candidates.isEmpty else { return nil }
        
        // Sort: highest height first, then bitrate
        candidates.sort { a, b in
            let ha = (a["height"] as? Int) ?? 0
            let hb = (b["height"] as? Int) ?? 0
            if ha != hb { return ha > hb }
            let ba = (a["bitrate"] as? Int) ?? 0
            let bb = (b["bitrate"] as? Int) ?? 0
            return ba > bb
        }
        
        let vFormat = candidates[0]
        
        // 2. Select best audio format (AAC mp4a) - ALWAYS ORIGINAL AUDIO, NEVER DUBBED
        var audioCandidates: [[String: Any]] = []
        for format in adaptive {
            guard let mime = (format["mimeType"] as? String)?.lowercased(),
                  mime.hasPrefix("audio/mp4") && mime.contains("mp4a"),
                  format["url"] is String,
                  format["initRange"] is [String: Any],
                  format["indexRange"] is [String: Any] else {
                continue
            }
            audioCandidates.append(format)
        }
        
        guard !audioCandidates.isEmpty else { return nil }
        
        // Strictly filter for original audio tracks (never dubbed or descriptive)
        let originalAudios = audioCandidates.filter { isOriginalAudioTrack(format: $0) }
        let candidatesToUse = !originalAudios.isEmpty ? originalAudios : audioCandidates
        
        let sortedAudios = candidatesToUse.sorted { a, b in
            // 1. Prefer non-DRC (standard dynamic range)
            let drcA = (a["isDrc"] as? Bool) == true ? 1 : 0
            let drcB = (b["isDrc"] as? Bool) == true ? 1 : 0
            if drcA != drcB { return drcA < drcB }
            
            // 2. Prefer higher bitrate (e.g. 130kbps itag 140 over 48kbps itag 139)
            let ba = (a["bitrate"] as? Int) ?? 0
            let bb = (b["bitrate"] as? Int) ?? 0
            return ba > bb
        }
        
        let aFormat = sortedAudios[0]
        
        guard let vURLString = vFormat["url"] as? String,
              let vURL = URL(string: vURLString),
              let aURLString = aFormat["url"] as? String,
              let aURL = URL(string: aURLString) else {
            return nil
        }
        
        guard let vInit = parseRange(vFormat["initRange"]),
              let vIndex = parseRange(vFormat["indexRange"]),
              let aInit = parseRange(aFormat["initRange"]),
              let aIndex = parseRange(aFormat["indexRange"]) else {
            return nil
        }
        
        // 3. Fetch SIDX boxes in parallel
        do {
            async let vData = fetchRange(url: vURL, start: vIndex.start, end: vIndex.end, session: session, userAgent: userAgent)
            async let aData = fetchRange(url: aURL, start: aIndex.start, end: aIndex.end, session: session, userAgent: userAgent)
            
            let (vSidx, aSidx) = try await (vData, aData)
            
            guard let vParsed = parseSIDX(data: vSidx, indexEnd: vIndex.end, initEnd: vInit.end),
                  let aParsed = parseSIDX(data: aSidx, indexEnd: aIndex.end, initEnd: aInit.end) else {
                return nil
            }
            
            let vHeight = (vFormat["height"] as? Int) ?? 720
            let vWidth = (vFormat["width"] as? Int) ?? (vHeight * 16 / 9)
            let vBitrate = (vFormat["bitrate"] as? Int) ?? 2_500_000
            let aBitrate = (aFormat["bitrate"] as? Int) ?? 128_000
            let totalBitrate = vBitrate + aBitrate
            let vAvgBitrate = (vFormat["averageBitrate"] as? Int) ?? vBitrate
            let vFps = (vFormat["fps"] as? Int) ?? 30
            
            let vMime = (vFormat["mimeType"] as? String) ?? ""
            let vCodec = extractCodec(from: vMime) ?? (vMime.contains("av01") ? "av01.0.08M.08" : "avc1.4D401F")
            let aMime = (aFormat["mimeType"] as? String) ?? ""
            let aCodec = extractCodec(from: aMime) ?? "mp4a.40.2"
            
            // Audio track display name (e.g. "English (US) original" or "Original Audio")
            let audioTrackName: String
            if let track = aFormat["audioTrack"] as? [String: Any],
               let name = track["displayName"] as? String, !name.isEmpty {
                audioTrackName = name
            } else {
                audioTrackName = "Original"
            }
            
            let duration = max(vParsed.totalDuration, aParsed.totalDuration)
            
            // 4. Generate Master Playlist & Subtitle Playlists
            let scheme = "tubelite-hls"
            var masterLines: [String] = [
                "#EXTM3U",
                "#EXT-X-VERSION:6",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio-default\",NAME=\"\(audioTrackName)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(scheme)://local/audio.m3u8\""
            ]
            
            var subtitlePlaylists: [String: String] = [:]
            var subtitlesAttr = ""
            if !subtitleTracks.isEmpty {
                subtitlesAttr = ",SUBTITLES=\"subtitles-default\""
                let targetDur = max(1, Int(ceil(duration)))
                let durStr = String(format: "%.5f", duration)
                
                for (idx, track) in subtitleTracks.enumerated() {
                    let escapedName = track.name
                        .replacingOccurrences(of: "\"", with: "'")
                        .trimmingCharacters(in: .whitespaces)
                    // Priority track (English or original audio) is AUTOSELECT=YES
                    let autoselect = (idx == 0) ? "YES" : "NO"
                    masterLines.append(
                        "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subtitles-default\",NAME=\"\(escapedName)\",DEFAULT=NO,AUTOSELECT=\(autoselect),FORCED=NO,LANGUAGE=\"\(track.languageCode)\",URI=\"\(scheme)://local/subtitles_\(track.id).m3u8\""
                    )
                    
                    let subPlaylist = """
                    #EXTM3U
                    #EXT-X-VERSION:3
                    #EXT-X-TARGETDURATION:\(targetDur)
                    #EXT-X-MEDIA-SEQUENCE:0
                    #EXT-X-PLAYLIST-TYPE:VOD
                    #EXTINF:\(durStr),
                    \(track.vttURL.absoluteString)
                    #EXT-X-ENDLIST
                    
                    """
                    subtitlePlaylists["subtitles_\(track.id).m3u8"] = subPlaylist
                }
            }
            
            masterLines.append(
                "#EXT-X-STREAM-INF:BANDWIDTH=\(totalBitrate),AVERAGE-BANDWIDTH=\(vAvgBitrate + aBitrate),RESOLUTION=\(vWidth)x\(vHeight),FRAME-RATE=\(vFps),CODECS=\"\(vCodec),\(aCodec)\",AUDIO=\"audio-default\"\(subtitlesAttr)"
            )
            masterLines.append("\(scheme)://local/video.m3u8\n")
            let masterPlaylist = masterLines.joined(separator: "\n")
            
            // 5. Generate Video Media Playlist
            var videoLines: [String] = [
                "#EXTM3U",
                "#EXT-X-VERSION:6",
                "#EXT-X-TARGETDURATION:\(vParsed.maxDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MAP:URI=\"\(vURLString)\",BYTERANGE=\"\(vParsed.initLength)@0\""
            ]
            for seg in vParsed.segments {
                videoLines.append(String(format: "#EXTINF:%.5f,", seg.duration))
                videoLines.append("#EXT-X-BYTERANGE:\(seg.length)@\(seg.offset)")
                videoLines.append(vURLString)
            }
            videoLines.append("#EXT-X-ENDLIST\n")
            let videoPlaylist = videoLines.joined(separator: "\n")
            
            // 6. Generate Audio Media Playlist
            var audioLines: [String] = [
                "#EXTM3U",
                "#EXT-X-VERSION:6",
                "#EXT-X-TARGETDURATION:\(aParsed.maxDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MAP:URI=\"\(aURLString)\",BYTERANGE=\"\(aParsed.initLength)@0\""
            ]
            for seg in aParsed.segments {
                audioLines.append(String(format: "#EXTINF:%.5f,", seg.duration))
                audioLines.append("#EXT-X-BYTERANGE:\(seg.length)@\(seg.offset)")
                audioLines.append(aURLString)
            }
            audioLines.append("#EXT-X-ENDLIST\n")
            let audioPlaylist = audioLines.joined(separator: "\n")
            
            return SynthesizedHLS(
                masterPlaylist: masterPlaylist,
                videoPlaylist: videoPlaylist,
                audioPlaylist: audioPlaylist,
                subtitlePlaylists: subtitlePlaylists,
                subtitleTracks: subtitleTracks,
                selectedHeight: vHeight,
                selectedCodec: vCodec,
                durationSeconds: duration
            )
        } catch {
            return nil
        }
    }
    
    // MARK: - SIDX Parsing
    
    public static func parseSIDX(data: Data, indexEnd: Int, initEnd: Int) -> ParsedStream? {
        guard data.count >= 24 else { return nil }
        guard let version = data.readUInt8(at: 8),
              let timescale = data.readUInt32BE(at: 16),
              timescale > 0 else {
            return nil
        }
        
        var offset = 20
        var firstOffset: UInt64 = 0
        if version == 0 {
            offset += 4 // earliestPresentationTime
            firstOffset = UInt64(data.readUInt32BE(at: offset) ?? 0)
            offset += 4
        } else {
            offset += 8 // earliestPresentationTime
            firstOffset = data.readUInt64BE(at: offset) ?? 0
            offset += 8
        }
        offset += 2 // reserved
        guard let refCount = data.readUInt16BE(at: offset) else { return nil }
        offset += 2
        
        var segments: [Segment] = []
        var maxDur = 0.0
        var totalDur = 0.0
        var currentByteOffset = UInt64(indexEnd + 1) + firstOffset
        
        for _ in 0..<Int(refCount) {
            guard offset + 12 <= data.count else { break }
            let field1 = data.readUInt32BE(at: offset) ?? 0
            offset += 4
            let size = field1 & 0x7FFFFFFF
            let durationTicks = data.readUInt32BE(at: offset) ?? 0
            offset += 4
            offset += 4 // flags
            
            let durSec = Double(durationTicks) / Double(timescale)
            if durSec > maxDur { maxDur = durSec }
            totalDur += durSec
            
            segments.append(Segment(
                duration: durSec,
                length: size,
                offset: currentByteOffset
            ))
            currentByteOffset += UInt64(size)
        }
        
        guard !segments.isEmpty else { return nil }
        
        return ParsedStream(
            segments: segments,
            maxDuration: max(1, Int(ceil(maxDur))),
            initLength: initEnd + 1,
            totalDuration: totalDur
        )
    }
    
    private static func fetchRange(url: URL, start: Int, end: Int, session: URLSession, userAgent: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw NSError(domain: "TubeLiteHLSBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed HTTP range fetch"])
        }
        return data
    }
    
    private static func parseRange(_ dict: Any?) -> (start: Int, end: Int)? {
        guard let d = dict as? [String: Any],
              let sStr = d["start"] as? String, let start = Int(sStr),
              let eStr = d["end"] as? String, let end = Int(eStr) else {
            return nil
        }
        return (start, end)
    }
    
    private static func extractCodec(from mime: String) -> String? {
        guard let r1 = mime.range(of: "codecs=\"") else { return nil }
        let sub = mime[r1.upperBound...]
        guard let r2 = sub.range(of: "\"") else { return nil }
        return String(sub[..<r2.lowerBound])
    }
    
    /// Determines whether an audio format is the original audio track (never dubbed or descriptive).
    public static func isOriginalAudioTrack(format: [String: Any]) -> Bool {
        guard let track = format["audioTrack"] as? [String: Any] else {
            // No audioTrack dictionary provided: standard single-audio video, always original
            return true
        }
        
        let displayName = (track["displayName"] as? String)?.lowercased() ?? ""
        let trackId = (track["id"] as? String)?.lowercased() ?? ""
        
        // Exclude descriptive audio tracks (Audio Description / DVS for visually impaired)
        if displayName.contains("descriptive") || trackId.contains("descriptive") {
            return false
        }
        
        // Exclude explicit dubbed markers
        if displayName.contains("dubbed") || displayName.contains("(dub)") || trackId.contains("dub") {
            return false
        }
        
        // Explicitly marked default by YouTube
        if let isDefault = track["audioIsDefault"] as? Bool, isDefault {
            return true
        }
        if let isDefault = format["isDefaultAudioTrack"] as? Bool, isDefault {
            return true
        }
        
        // Explicitly contains "original" keyword in displayName or id
        if displayName.contains("original") || trackId.contains("original") {
            return true
        }
        
        // If audioTrack metadata is present and audioIsDefault is false / not original, it is a dubbed track!
        return false
    }
}

// MARK: - Binary Data Extensions

private extension Data {
    func readUInt8(at offset: Int) -> UInt8? {
        guard offset + 1 <= count else { return nil }
        return self[offset]
    }
    
    func readUInt16BE(at offset: Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        return withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
        }
    }
    
    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
    }
    
    func readUInt64BE(at offset: Int) -> UInt64? {
        guard offset + 8 <= count else { return nil }
        return withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
    }
}
