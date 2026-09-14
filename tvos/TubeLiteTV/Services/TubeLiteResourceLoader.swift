import Foundation
import AVFoundation

/// Serves a filtered H.264-only HLS master playlist over a custom URL scheme.
/// Media playlist / segment URIs stay absolute `https://` googlevideo URLs so CoreMedia
/// fetches real YouTube HLS (not progressive MP4 wrapped as fake segments — that causes -12660).
public final class TubeLiteResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    public static let urlScheme = "tubelite-hls"
    
    public let masterURL: URL
    public let queue = DispatchQueue(label: "com.tubelite.tv.resource-loader")
    
    private let masterPlaylistData: Data
    private let videoPlaylistData: Data?
    private let audioPlaylistData: Data?
    private let subtitlePlaylists: [String: Data]
    private let subtitleTracks: [String: TubeLiteGatewayClient.SubtitleTrack]
    
    public init(
        masterPlaylist: String,
        videoPlaylist: String? = nil,
        audioPlaylist: String? = nil,
        subtitlePlaylists: [String: String] = [:],
        subtitleTracks: [TubeLiteGatewayClient.SubtitleTrack] = []
    ) {
        self.masterPlaylistData = Data(masterPlaylist.utf8)
        self.videoPlaylistData = videoPlaylist.map { Data($0.utf8) }
        self.audioPlaylistData = audioPlaylist.map { Data($0.utf8) }
        
        var subMap: [String: Data] = [:]
        for (name, playlist) in subtitlePlaylists {
            subMap[name.lowercased()] = Data(playlist.utf8)
        }
        self.subtitlePlaylists = subMap
        
        var trackMap: [String: TubeLiteGatewayClient.SubtitleTrack] = [:]
        for track in subtitleTracks {
            trackMap["subtitles_\(track.id).vtt".lowercased()] = track
        }
        self.subtitleTracks = trackMap
        
        self.masterURL = URL(string: "\(Self.urlScheme)://local/master.m3u8")!
        super.init()
    }
    
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme == Self.urlScheme else {
            loadingRequest.finishLoading(with: Self.error("Unsupported resource URL"))
            return true
        }
        
        let path = requestURL.lastPathComponent.lowercased()
        
        // 1. Playlists (Master, Video, Audio, or Subtitle media playlists)
        var data: Data? = nil
        if path.isEmpty || path == "master.m3u8" {
            data = masterPlaylistData
        } else if path == "video.m3u8", let vData = videoPlaylistData {
            data = vData
        } else if path == "audio.m3u8", let aData = audioPlaylistData {
            data = aData
        } else if let subData = subtitlePlaylists[path] {
            data = subData
        }
        
        if let playlistData = data {
            if let contentInfo = loadingRequest.contentInformationRequest {
                contentInfo.contentType = "application/vnd.apple.mpegurl"
                contentInfo.contentLength = Int64(playlistData.count)
                contentInfo.isByteRangeAccessSupported = true
            }
            if let dataRequest = loadingRequest.dataRequest {
                respond(to: dataRequest, with: playlistData)
            }
            loadingRequest.finishLoading()
            return true
        }
        
        // 2. Media segments with custom scheme: CoreMedia strictly requires an HTTP redirect
        if path.hasSuffix(".vtt"), let track = subtitleTracks[path] {
            let dest = track.vttURL
            loadingRequest.redirect = URLRequest(url: dest)
            loadingRequest.response = HTTPURLResponse(
                url: requestURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": dest.absoluteString]
            )
            loadingRequest.finishLoading()
            return true
        }
        
        loadingRequest.finishLoading(with: Self.error("Unknown playlist path: \(path)"))
        return true
    }
    
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Handled gracefully
    }
    
    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest, with data: Data) {
        let offset = Int(dataRequest.requestedOffset)
        guard offset < data.count else {
            dataRequest.respond(with: Data())
            return
        }
        let end = dataRequest.requestsAllDataToEndOfResource
            ? data.count
            : min(data.count, offset + dataRequest.requestedLength)
        dataRequest.respond(with: data.subdata(in: offset..<end))
    }
    
    /// Keep AVPlayer-safe variants: always `avc1`, plus `av01` when `allowAV1`.
    /// Drops VP9 (CoreMedia can't decode). Sorts by bandwidth ascending (HLS ABR).
    /// Resolves relative URLs to absolute against baseURL, injects subtitle tracks, and returns subtitle playlists.
    public static func filterHLSMaster(
        _ master: String,
        baseURL: URL? = nil,
        subtitleTracks: [TubeLiteGatewayClient.SubtitleTrack] = [],
        duration: Double = 0,
        allowAV1: Bool = false
    ) -> (playlist: String, subtitlePlaylists: [String: String], variantCount: Int, maxHeight: Int)? {
        let lines = master.components(separatedBy: .newlines)
        var header: [String] = []
        var mediaTags: [String] = []
        var variants: [(info: String, uri: String, bandwidth: Int, height: Int)] = []
        
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                i += 1
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let info = line
                // Skip blank lines between STREAM-INF and URI.
                var j = i + 1
                while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                }
                let rawUri = (j < lines.count) ? lines[j].trimmingCharacters(in: .whitespaces) : ""
                i = j + 1
                guard !rawUri.isEmpty, !rawUri.hasPrefix("#") else { continue }
                
                let resolvedUri: String
                if let base = baseURL, !rawUri.hasPrefix("http") {
                    resolvedUri = URL(string: rawUri, relativeTo: base)?.absoluteString ?? rawUri
                } else {
                    resolvedUri = rawUri
                }
                
                let lower = info.lowercased()
                let isAVC = lower.contains("avc1")
                let isAV1 = lower.contains("av01")
                let isVP9 = lower.contains("vp09") || lower.contains("vp9")
                let allowed = (isAVC || (allowAV1 && isAV1)) && !isVP9
                guard allowed else { continue }
                variants.append((
                    info,
                    resolvedUri,
                    attributeInt(from: info, name: "BANDWIDTH") ?? 0,
                    resolutionHeight(from: info) ?? 0
                ))
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                mediaTags.append(line)
                i += 1
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                i += 1
                continue
            }
            if variants.isEmpty && mediaTags.isEmpty {
                header.append(line)
            }
            i += 1
        }
        
        guard !variants.isEmpty else { return nil }
        
        // One variant per height — keep the highest bandwidth (sharper encode / better audio).
        var bestByHeight: [Int: (info: String, uri: String, bandwidth: Int, height: Int)] = [:]
        for v in variants {
            let key = v.height
            if let existing = bestByHeight[key] {
                if v.bandwidth > existing.bandwidth { bestByHeight[key] = v }
            } else {
                bestByHeight[key] = v
            }
        }
        
        let rawMaxHeight = bestByHeight.keys.max() ?? 0
        // Prefer the top rung: when 1080+ exists, play that only (no soft 144–480 ABR crawl).
        // Otherwise keep ≥360 so mid-tier videos still have a small ladder.
        let pool: [ (info: String, uri: String, bandwidth: Int, height: Int) ]
        if rawMaxHeight >= 1080, let top = bestByHeight[rawMaxHeight] {
            pool = [top]
        } else {
            let minKeep = rawMaxHeight >= 720 ? 360 : 0
            let trimmed = bestByHeight.values.filter { $0.height >= minKeep }
            pool = trimmed.isEmpty ? Array(bestByHeight.values) : Array(trimmed)
        }
        
        // HLS authoring: ascending bandwidth; AVPlayer still ramps, but without 144/240 filler.
        let sorted = pool.sorted { $0.bandwidth < $1.bandwidth }
        let maxHeight = sorted.map(\.height).max() ?? 0
        
        var neededAudioGroups = Set<String>()
        for v in sorted {
            if let group = attributeValue(from: v.info, name: "AUDIO") {
                neededAudioGroups.insert(group)
            }
        }
        
        let keptMedia = mediaTags.compactMap { tag -> String? in
            let type = attributeValue(from: tag, name: "TYPE")?.uppercased()
            guard type == "AUDIO" else { return nil }
            guard let group = attributeValue(from: tag, name: "GROUP-ID") else { return nil }
            guard neededAudioGroups.contains(group) else { return nil }
            if let base = baseURL, let rawURI = attributeValue(from: tag, name: "URI"), !rawURI.hasPrefix("http") {
                let resolved = URL(string: rawURI, relativeTo: base)?.absoluteString ?? rawURI
                return replaceAttribute(in: tag, name: "URI", with: "\"\(resolved)\"")
            }
            return tag
        }
        
        var subtitlePlaylists: [String: String] = [:]
        var subMediaTags: [String] = []
        if !subtitleTracks.isEmpty {
            let targetDur = max(1, Int(ceil(duration)))
            let durStr = String(format: "%.5f", duration)
            for (idx, track) in subtitleTracks.enumerated() {
                let escapedName = track.name
                    .replacingOccurrences(of: "\"", with: "'")
                    .trimmingCharacters(in: .whitespaces)
                let autoselect = (idx == 0) ? "YES" : "NO"
                subMediaTags.append(
                    "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subtitles-default\",NAME=\"\(escapedName)\",DEFAULT=NO,AUTOSELECT=\(autoselect),FORCED=NO,LANGUAGE=\"\(track.languageCode)\",URI=\"\(Self.urlScheme)://local/subtitles_\(track.id).m3u8\""
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
        
        var out: [String] = header.isEmpty ? ["#EXTM3U", "#EXT-X-INDEPENDENT-SEGMENTS"] : header
        out.append(contentsOf: keptMedia)
        out.append(contentsOf: subMediaTags)
        for v in sorted {
            var info = stripAttribute(from: v.info, name: "SUBTITLES")
            if !subtitleTracks.isEmpty {
                info += ",SUBTITLES=\"subtitles-default\""
            }
            out.append(info)
            out.append(v.uri)
        }
        return (
            playlist: out.joined(separator: "\n") + "\n",
            subtitlePlaylists: subtitlePlaylists,
            variantCount: sorted.count,
            maxHeight: maxHeight
        )
    }
    
    /// Backward-compatible alias.
    public static func filterHLSMasterForAVC1(_ master: String) -> (playlist: String, variantCount: Int)? {
        guard let r = filterHLSMaster(master, allowAV1: false) else { return nil }
        return (r.playlist, r.variantCount)
    }
    
    private static func resolutionHeight(from streamInf: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"RESOLUTION=\d+x(\d+)"#),
              let match = regex.firstMatch(in: streamInf, range: NSRange(streamInf.startIndex..<streamInf.endIndex, in: streamInf)),
              let r = Range(match.range(at: 1), in: streamInf) else {
            return nil
        }
        return Int(streamInf[r])
    }
    
    private static func attributeInt(from line: String, name: String) -> Int? {
        attributeValue(from: line, name: name).flatMap(Int.init)
    }
    
    private static func mediaGroupID(from streamInf: String, attribute: String) -> String? {
        attributeValue(from: streamInf, name: attribute)
    }
    
    private static func attributeValue(from line: String, name: String) -> String? {
        // AUDIO="233" or AUDIO=233
        let pattern = #"\#(name)=(?:"([^"]+)"|([^,\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        if let r = Range(match.range(at: 1), in: line), !r.isEmpty { return String(line[r]) }
        if let r = Range(match.range(at: 2), in: line), !r.isEmpty { return String(line[r]) }
        return nil
    }
    
    private static func stripAttribute(from line: String, name: String) -> String {
        guard line.hasPrefix("#EXT-X-STREAM-INF:") else { return line }
        let prefix = "#EXT-X-STREAM-INF:"
        let body = String(line.dropFirst(prefix.count))
        let parts = splitHLSAttributes(body).filter {
            !$0.uppercased().hasPrefix("\(name.uppercased())=")
        }
        return prefix + parts.joined(separator: ",")
    }
    
    private static func replaceAttribute(in line: String, name: String, with newValue: String) -> String {
        let pattern = #"\#(name)=(?:"[^"]*"|[^,\s]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let nsrange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsrange),
              let range = Range(match.range, in: line) else {
            return line
        }
        return line.replacingCharacters(in: range, with: "\(name)=\(newValue)")
    }
    
    private static func splitHLSAttributes(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in body {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { parts.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }
    
    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "TubeLiteResourceLoader",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
