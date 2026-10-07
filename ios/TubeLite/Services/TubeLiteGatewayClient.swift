import Foundation
import VideoToolbox
import SwiftUI

/// Network service communicating with the LiteTube Cloudflare Worker Gateway
@MainActor
public class TubeLiteGatewayClient: ObservableObject {
    public static let shared = TubeLiteGatewayClient()
    
    public static let defaultGatewayUrl = "https://litetube-gateway.anirudhkumar.workers.dev"
    
    @Published public var homeVideos: [VideoItem] = []
    @Published public var searchResults: [VideoItem] = []
    @Published public var isLoading: Bool = false
    @Published public var isLoadingMore: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var activeErrorBubble: String? = nil
    
    @Published public var homeContinuationToken: String? = nil
    @Published public var searchContinuationToken: String? = nil
    @Published public var hasBridgedToSubscriptions: Bool = false
    
    private var errorBubbleDismissTask: Task<Void, Never>? = nil

    public func showErrorBubble(_ message: String) {
        errorBubbleDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.activeErrorBubble = message
        }
        errorBubbleDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                if self.activeErrorBubble == message {
                    self.activeErrorBubble = nil
                }
            }
        }
    }

    public func dismissErrorBubble() {
        errorBubbleDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            self.activeErrorBubble = nil
        }
    }

    public func sendFeedback(video: VideoItem) {
        Task {
            await sendFeedback(videoId: video.id, feedbackToken: video.feedbackToken)
        }
    }

    @discardableResult
    public func sendChannelFeedback(video: VideoItem) async -> Bool {
        guard let token = video.channelFeedbackToken, !token.isEmpty else { return false }
        return await sendFeedback(videoId: video.id, feedbackToken: token)
    }

    public func recordWatchStatus(video: VideoItem) {
        Task {
            await recordWatchStatus(videoId: video.id, durationSec: video.durationSeconds)
        }
    }

    @discardableResult
    public func markVideoAsWatched(video: VideoItem) async -> Bool {
        return await recordWatchStatus(videoId: video.id, durationSec: video.durationSeconds)
    }

    /// Fetches the authentic InnerTube player tracking session for a video.
    /// Returns the authentic videostatsPlaybackUrl, videostatsWatchtimeUrl, and video duration in seconds.
    public func fetchPlaybackTracking(videoId: String, accessToken: String?) async -> (playbackUrl: String, watchtimeUrl: String, duration: Double)? {
        guard !videoId.isEmpty else { return nil }

        let isAuth = accessToken != nil && !accessToken!.isEmpty
        let endpoint = isAuth
            ? "https://youtubei.googleapis.com/youtubei/v1/player?key=AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8"
            : "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"

        // Primary: Direct YouTube InnerTube Player endpoint
        if let direct = await _fetchPlayerTracking(
            endpoint: endpoint,
            videoId: videoId,
            accessToken: accessToken,
            isAuth: isAuth
        ) {
            return direct
        }

        // Fallback: Through Worker Gateway
        let gatewayEndpoint = "\(Self.defaultGatewayUrl)/api/innertube/player"
        return await _fetchPlayerTracking(
            endpoint: gatewayEndpoint,
            videoId: videoId,
            accessToken: accessToken,
            isAuth: isAuth
        )
    }

    private func _fetchPlayerTracking(
        endpoint: String,
        videoId: String,
        accessToken: String?,
        isAuth: Bool
    ) async -> (playbackUrl: String, watchtimeUrl: String, duration: Double)? {
        guard let url = URL(string: endpoint) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let clientName = isAuth ? "TVHTML5" : "VISIONOS"
        let clientHeader = isAuth ? "7" : "101"
        let clientVersion = isAuth ? "7.20240901.00.00" : "1.02"
        let ua = isAuth
            ? "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36"
            : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(clientHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if isAuth, let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVersion
                ]
            ],
            "videoId": videoId
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: req)
            guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pt = json["playbackTracking"] as? [String: Any],
                  let pb = (pt["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String,
                  let wt = (pt["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String else {
                return nil
            }
            let duration = Self.parseDurationSeconds(json: json, streamingData: [:])
            return (playbackUrl: pb, watchtimeUrl: wt, duration: duration)
        } catch {
            return nil
        }
    }

    @discardableResult
    public func recordWatchStatus(videoId: String, durationSec: Double? = nil) async -> Bool {
        guard !videoId.isEmpty else { return false }

        guard let token = await DeviceAuthService.shared.getValidAccessToken() else {
            showErrorBubble("Sign in to sync YouTube watch history")
            return false
        }

        // 1. Immediately hide card temporarily in memory state (until page refresh)
        withAnimation(.easeInOut(duration: 0.25)) {
            homeVideos.removeAll { $0.id == videoId }
            searchResults.removeAll { $0.id == videoId }
        }

        // 2. Resolve authentic player tracking info containing valid plid session
        let trackingInfo: (playbackUrl: String, watchtimeUrl: String, duration: Double)?
        if let cached = await PlaybackPreloadCache.shared.cachedTracking(for: videoId) {
            trackingInfo = cached
        } else {
            trackingInfo = await fetchPlaybackTracking(videoId: videoId, accessToken: token)
        }

        guard let tracking = trackingInfo,
              !tracking.playbackUrl.isEmpty,
              !tracking.watchtimeUrl.isEmpty else {
            print("[TubeLite Telemetry] Unable to retrieve playback tracking for \(videoId)")
            return false
        }

        let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        let cpn = String((0..<16).compactMap { _ in charset.randomElement() })
        let clientVer = "7.20240901.00.00"
        let effectiveDuration = tracking.duration > 0 ? tracking.duration : max(durationSec ?? 60.0, 1.0)
        let durationFormatted = String(format: "%.3f", max(effectiveDuration - 1.0, 1.0))

        // Genuine session parameters appended to YouTube's plid-authenticated baseUrl
        let pbQuery = "&cpn=\(cpn)&ver=2&c=tvhtml5&cver=\(clientVer)&cbrver=\(clientVer)&cmt=\(durationFormatted)&fmt=251&rtn=0&rt=0"
        let wtQuery = "&cpn=\(cpn)&ver=2&c=tvhtml5&cver=\(clientVer)&cbrver=\(clientVer)&state=playing&cmt=\(durationFormatted)&st=0.000&et=\(durationFormatted)&final=1"

        let pbFullS = tracking.playbackUrl + pbQuery
        let pbFullWww = tracking.playbackUrl.replacingOccurrences(of: "https://s.youtube.com", with: "https://www.youtube.com") + pbQuery

        let wtFullS = tracking.watchtimeUrl + wtQuery
        let wtFullWww = tracking.watchtimeUrl.replacingOccurrences(of: "https://s.youtube.com", with: "https://www.youtube.com") + wtQuery

        @Sendable func sendPing(_ urlString: String) async -> Bool {
            guard let url = URL(string: urlString) else { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            req.setValue("https://www.youtube.com/tv", forHTTPHeaderField: "Referer")
            req.setValue("Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            req.setValue("7", forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(clientVer, forHTTPHeaderField: "X-YouTube-Client-Version")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                let (_, res) = try await session.data(for: req)
                let status = (res as? HTTPURLResponse)?.statusCode ?? 0
                return (200...299).contains(status) || status == 204
            } catch {
                return false
            }
        }

        // Send playback init ping (both www and s endpoints)
        async let pbWwwSuccess = sendPing(pbFullWww)
        async let pbSSuccess = sendPing(pbFullS)
        _ = await (pbWwwSuccess, pbSSuccess)

        // Send watch completion ping (both www and s endpoints)
        async let wtWwwSuccess = sendPing(wtFullWww)
        async let wtSSuccess = sendPing(wtFullS)
        let (w1, w2) = await (wtWwwSuccess, wtSSuccess)

        let ok = w1 || w2
        if ok {
            print("[TubeLite Telemetry] Synced watch progress to account history for \(videoId) (\(durationFormatted)s)")
        } else {
            showErrorBubble("YouTube watch status failed to sync")
        }
        return ok
    }

    @discardableResult
    public func sendFeedback(videoId: String, feedbackToken: String? = nil) async -> Bool {
        guard !videoId.isEmpty else { return false }

        // Require a valid feedback token from YouTube AST
        guard let ft = feedbackToken, !ft.isEmpty else {
            return false
        }

        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/feedback"
        guard let url = URL(string: endpoint) else {
            showErrorBubble("Invalid feedback endpoint")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let token = await DeviceAuthService.shared.getValidAccessToken()
        let isAuth = token != nil
        let clientName = isAuth ? "TVHTML5" : "WEB"
        let clientVer = isAuth ? "7.20240901.00.00" : "2.20240901.00.00"

        request.setValue(clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVer, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVer,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "feedbackTokens": [ft]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(statusCode) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    homeVideos.removeAll { $0.id == videoId }
                    searchResults.removeAll { $0.id == videoId }
                }
                return true
            } else {
                let serverMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                let msg = serverMsg ?? "Status \(statusCode)"
                showErrorBubble("YouTube feedback failed: \(msg)")
                return false
            }
        } catch {
            showErrorBubble("YouTube feedback network error: \(error.localizedDescription)")
            return false
        }
    }
    
    private var lastHomeFeedAt: Date? = nil
    
    public func fetchHomeFeedIfNeeded() async {
        guard homeVideos.isEmpty || Date().timeIntervalSince(lastHomeFeedAt ?? .distantPast) >= 30 else { return }
        await fetchHomeFeed()
    }
    
    private let session: URLSession
    
    public init(session: URLSession = .shared) {
        self.session = session
    }
    
    // MARK: - Playback Resolution
    
    public struct PlaybackDiagnostics: Identifiable {
        public let id = UUID()
        public var timestamp: Date = Date()
        public var videoId: String
        
        public var primaryEndpoint: String = ""
        public var primaryHttpStatus: Int? = nil
        public var primaryPlayabilityStatus: String? = nil
        public var primaryPlayabilityReason: String? = nil
        
        public var resolvedUrl: String? = nil
        public var failureStage: String? = nil
        public var audioChannels: Int = 2
        public var isSurroundAvailable: Bool = false
        public var isSurroundActive: Bool = false
        public var isUpmixingSelected: Bool = false
        public var audioStatusDescription: String = "Stereo 2.0 (iOS Hardware Spatial Audio)"
        public var audioRenderingMode: String = "Stereo 2.0 (iOS Hardware Spatial Upmixing: ACTIVE)"
        public var executionTimeline: [String] = []
        
        public init(videoId: String) {
            self.videoId = videoId
        }
        
        public mutating func log(_ message: String) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeStr = formatter.string(from: Date())
            executionTimeline.append("[\(timeStr)] \(message)")
        }
    }
    
    /// H.264 / AAC / multichannel adaptive stream extracted from YouTube `adaptiveFormats`.
    public struct AdaptiveStream: Identifiable {
        public var id: String { "\(itag ?? 0)-\(url.absoluteString)" }
        public let url: URL
        public let itag: Int?
        public let mimeType: String
        public let codecs: String?
        public let bandwidth: Int
        public let averageBitrate: Int?
        public let width: Int?
        public let height: Int?
        public let fps: Int?
        public let approxDurationMs: Double?
        public let audioChannels: Int?
        
        public init(
            url: URL,
            itag: Int? = nil,
            mimeType: String,
            codecs: String? = nil,
            bandwidth: Int,
            averageBitrate: Int? = nil,
            width: Int? = nil,
            height: Int? = nil,
            fps: Int? = nil,
            approxDurationMs: Double? = nil,
            audioChannels: Int? = nil
        ) {
            self.url = url
            self.itag = itag
            self.mimeType = mimeType
            self.codecs = codecs
            self.bandwidth = bandwidth
            self.averageBitrate = averageBitrate
            self.width = width
            self.height = height
            self.fps = fps
            self.approxDurationMs = approxDurationMs
            self.audioChannels = audioChannels
        }
    }
    
    /// A single subtitle / caption track from YouTube.
    public struct SubtitleTrack: Equatable, Identifiable {
        public let id: String
        public let languageCode: String
        public let name: String
        public let isAutoGenerated: Bool
        public let url: URL
        
        public var vttURL: URL {
            var str = url.absoluteString
            if str.contains("fmt=vtt") {
                return url
            }
            if str.contains("fmt=") {
                if let regex = try? NSRegularExpression(pattern: #"fmt=[^&]+"#) {
                    let range = NSRange(str.startIndex..<str.endIndex, in: str)
                    str = regex.stringByReplacingMatches(in: str, range: range, withTemplate: "fmt=vtt")
                    return URL(string: str) ?? url
                }
            }
            let separator = str.contains("?") ? "&" : "?"
            return URL(string: str + separator + "fmt=vtt") ?? url
        }
        
        public init(
            id: String,
            languageCode: String,
            name: String,
            isAutoGenerated: Bool,
            url: URL
        ) {
            self.id = id
            self.languageCode = languageCode
            self.name = name
            self.isAutoGenerated = isAutoGenerated
            self.url = url
        }
    }
    
    public struct PlaybackTrackingInfo {
        public let playbackUrl: String?
        public let watchtimeUrl: String?
        public let clientName: String
        public let clientVersion: String
        
        public init(
            playbackUrl: String? = nil,
            watchtimeUrl: String? = nil,
            clientName: String = "TVHTML5",
            clientVersion: String = "7.20240901.00.00"
        ) {
            self.playbackUrl = playbackUrl
            self.watchtimeUrl = watchtimeUrl
            self.clientName = clientName
            self.clientVersion = clientVersion
        }
    }
    
    /// Playback package: native HLS (master + video + audio + subtitles) or progressive MP4 fallback.
    public struct PlaybackResolution {
        public let hlsURL: URL?
        public let filteredHLSMaster: String?
        public let videoPlaylist: String?
        public let audioPlaylist: String?
        public let subtitlePlaylists: [String: String]
        public let subtitleTracks: [SubtitleTrack]
        public let progressiveURL: URL?
        public let selectedHeight: Int
        public let selectedCodec: String?
        public let durationSeconds: Double
        public let error: String?
        public let requiresAuth: Bool
        public let trackingInfo: PlaybackTrackingInfo?
        public let diagnostics: PlaybackDiagnostics
        
        public var isPlayable: Bool {
            error == nil && (
                hlsURL != nil
                || filteredHLSMaster != nil
                || progressiveURL != nil
            )
        }
        
        public init(
            hlsURL: URL? = nil,
            filteredHLSMaster: String? = nil,
            videoPlaylist: String? = nil,
            audioPlaylist: String? = nil,
            subtitlePlaylists: [String: String] = [:],
            subtitleTracks: [SubtitleTrack] = [],
            progressiveURL: URL? = nil,
            selectedHeight: Int = 0,
            selectedCodec: String? = nil,
            durationSeconds: Double = 0,
            error: String? = nil,
            requiresAuth: Bool = false,
            trackingInfo: PlaybackTrackingInfo? = nil,
            diagnostics: PlaybackDiagnostics
        ) {
            self.hlsURL = hlsURL
            self.filteredHLSMaster = filteredHLSMaster
            self.videoPlaylist = videoPlaylist
            self.audioPlaylist = audioPlaylist
            self.subtitlePlaylists = subtitlePlaylists
            self.subtitleTracks = subtitleTracks
            self.progressiveURL = progressiveURL
            self.selectedHeight = selectedHeight
            self.selectedCodec = selectedCodec
            self.durationSeconds = durationSeconds
            self.error = error
            self.requiresAuth = requiresAuth
            self.trackingInfo = trackingInfo
            self.diagnostics = diagnostics
        }
    }
    
    /// Manages non-blocking watch time telemetry and history synchronization for video playback.
    public final class WatchTelemetrySession {
        public let videoId: String
        public let trackingInfo: PlaybackTrackingInfo
        public let cpn: String
        
        private var lastReportedTime: Double = 0.0
        private var lastFlushTimestamp: Date = .distantPast
        private let sessionStartTime: Date = Date()
        private var isInitialized: Bool = false
        private var isDisposed: Bool = false
        private let flushInterval: TimeInterval = 15.0
        private let session: URLSession
        
        /// Invoked when telemetry pings succeed or fail.
        public var onLog: ((_ message: String, _ isError: Bool) -> Void)? = nil
        
        public init(
            videoId: String,
            trackingInfo: PlaybackTrackingInfo,
            session: URLSession = .shared
        ) {
            self.videoId = videoId
            self.trackingInfo = trackingInfo
            self.session = session
            
            let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
            self.cpn = String((0..<16).compactMap { _ in charset.randomElement() })
        }
        
        public func start(accessToken: String?) {
            guard !isInitialized, !isDisposed, let pbBase = trackingInfo.playbackUrl else { return }
            isInitialized = true
            lastFlushTimestamp = Date()
            
            let clientName = (accessToken != nil && !accessToken!.isEmpty) ? "tvhtml5" : trackingInfo.clientName
            let clientVersion = (accessToken != nil && !accessToken!.isEmpty) ? "7.20240901.00.00" : trackingInfo.clientVersion
            let urlStr = "\(pbBase)&cpn=\(cpn)&ver=2&cmt=0&c=\(clientName)&cver=\(clientVersion)&el=detailpage"
            dispatchPing(urlString: urlStr, pingType: "Session init", currentTime: 0.0, accessToken: accessToken)
        }
        
        public func reportProgress(currentTime: Double, isPlaying: Bool, accessToken: String?) {
            guard isInitialized, !isDisposed, let wtBase = trackingInfo.watchtimeUrl else { return }
            let now = Date()
            guard now.timeIntervalSince(lastFlushTimestamp) >= flushInterval else { return }
            
            let rt = Int(now.timeIntervalSince(sessionStartTime))
            let cmt = String(format: "%.1f", currentTime)
            let st = String(format: "%.1f", lastReportedTime)
            let et = String(format: "%.1f", currentTime)
            let state = isPlaying ? "playing" : "paused"
            let clientName = (accessToken != nil && !accessToken!.isEmpty) ? "tvhtml5" : trackingInfo.clientName
            let clientVersion = (accessToken != nil && !accessToken!.isEmpty) ? "7.20240901.00.00" : trackingInfo.clientVersion
            
            let urlStr = "\(wtBase)&cpn=\(cpn)&ver=2&cmt=\(cmt)&st=\(st)&et=\(et)&state=\(state)&rt=\(rt)&c=\(clientName)&cver=\(clientVersion)&el=detailpage"
            
            lastReportedTime = currentTime
            lastFlushTimestamp = now
            
            dispatchPing(urlString: urlStr, pingType: "Watch progress", currentTime: currentTime, accessToken: accessToken)
        }
        
        public func reportState(state: String, currentTime: Double, accessToken: String?) {
            guard isInitialized, !isDisposed, let wtBase = trackingInfo.watchtimeUrl else { return }
            let now = Date()
            let rt = Int(now.timeIntervalSince(sessionStartTime))
            let cmt = String(format: "%.1f", currentTime)
            let st = String(format: "%.1f", lastReportedTime)
            let et = cmt
            let clientName = (accessToken != nil && !accessToken!.isEmpty) ? "tvhtml5" : trackingInfo.clientName
            let clientVersion = (accessToken != nil && !accessToken!.isEmpty) ? "7.20240901.00.00" : trackingInfo.clientVersion
            
            let urlStr = "\(wtBase)&cpn=\(cpn)&ver=2&cmt=\(cmt)&st=\(st)&et=\(et)&state=\(state)&rt=\(rt)&c=\(clientName)&cver=\(clientVersion)&el=detailpage"
            
            lastReportedTime = currentTime
            lastFlushTimestamp = now
            
            let actionLabel = state == "playing" ? "Playback resumed" : "Playback paused"
            dispatchPing(urlString: urlStr, pingType: actionLabel, currentTime: currentTime, accessToken: accessToken)
        }
        
        public func teardown(finalTime: Double, accessToken: String?) {
            guard !isDisposed else { return }
            if isInitialized {
                reportState(state: "paused", currentTime: finalTime, accessToken: accessToken)
            }
            isDisposed = true
        }
        
        private func dispatchPing(urlString: String, pingType: String = "Watch progress", currentTime: Double? = nil, accessToken: String?) {
            let wwwUrlString = urlString.replacingOccurrences(of: "https://s.youtube.com", with: "https://www.youtube.com")
            guard let url = URL(string: wwwUrlString) ?? URL(string: urlString) else { return }
            
            Task.detached(priority: .utility) { [session, weak self] in
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                req.setValue("https://www.youtube.com/tv", forHTTPHeaderField: "Referer")
                req.setValue("Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                req.setValue("7", forHTTPHeaderField: "X-YouTube-Client-Name")
                req.setValue("7.20240901.00.00", forHTTPHeaderField: "X-YouTube-Client-Version")
                
                if let token = accessToken, !token.isEmpty {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                
                do {
                    let (_, response) = try await session.data(for: req)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if statusCode >= 200 && statusCode < 300 {
                        let timeStr = currentTime.map { " @ \(String(format: "%.1f", $0))s" } ?? ""
                        let msg = "Telemetry: \(pingType) synced\(timeStr) (HTTP \(statusCode))"
                        print("[TubeLite Telemetry] \(msg)")
                        self?.onLog?(msg, false)
                    } else {
                        let msg = "Telemetry: ⚠️ Watchtime request failed (HTTP \(statusCode))"
                        print("[TubeLite Telemetry] \(msg)")
                        self?.onLog?(msg, true)
                    }
                } catch {
                    let msg = "Telemetry: ⚠️ Watchtime request failed: \(error.localizedDescription)"
                    print("[TubeLite Telemetry] \(msg)")
                    self?.onLog?(msg, true)
                }
            }
        }
    }
    
    /// Resolves AVPlayer-compatible playback at the highest safe quality.
    /// Primary: Native Google HLS master manifest via VisionOS client (1080p, verified continuous playback).
    /// Sole Proven Fallback: Android progressive MP4 (itag 18, verified >60s).
    /// Zero unverified fallbacks.
    ///
    /// Off-main playback resolution: does all network, HTML parsing, manifest filtering,
    /// and fallback probing on background threads without touching MainActor.
    nonisolated public static func resolvePlayback(videoId: String) async -> PlaybackResolution {
        let signedIn = await MainActor.run { DeviceAuthService.shared.isSignedIn }
        return await _resolveOffMain(videoId: videoId, session: .shared, signedIn: signedIn)
    }
    
    public func resolvePlaybackItem(videoId: String) async -> PlaybackResolution {
        let sess = session
        let signedIn = DeviceAuthService.shared.isSignedIn
        return await Self._resolveOffMain(videoId: videoId, session: sess, signedIn: signedIn)
    }
    
    /// All network I/O, JSON deserialization, and HLS manifest filtering runs here — off MainActor.
    nonisolated private static func _resolveOffMain(
        videoId: String,
        session: URLSession,
        signedIn: Bool
    ) async -> PlaybackResolution {
        var diagnostics = PlaybackDiagnostics(videoId: videoId)
        diagnostics.log("Resolving streams for \(videoId). Signed in for feeds: \(signedIn)")
        
        // 1. Primary Engine: VisionOS Native HLS
        diagnostics.primaryEndpoint = "https://www.youtube.com/youtubei/v1/player (VISIONOS)"
        diagnostics.log("Attempting Primary Engine: VisionOS Native HLS")
        if let hls = await resolveVisionOSHLS(videoId: videoId, session: session, diagnostics: &diagnostics) {
            diagnostics.log("Resolved VisionOS HLS: \(hls.url.host ?? "") duration: \(hls.duration)s, \(hls.subtitles.count) subs")
            diagnostics.resolvedUrl = hls.filteredMaster != nil ? "tubelite-hls://local/master.m3u8" : hls.url.absoluteString
            return PlaybackResolution(
                hlsURL: hls.url,
                filteredHLSMaster: hls.filteredMaster,
                subtitlePlaylists: hls.subtitlePlaylists,
                subtitleTracks: hls.subtitles,
                selectedHeight: hls.selectedHeight,
                selectedCodec: "H.264/AAC",
                durationSeconds: hls.duration,
                trackingInfo: hls.tracking,
                diagnostics: diagnostics
            )
        }
        
        guard !Task.isCancelled else {
            diagnostics.failureStage = "Cancelled"
            return PlaybackResolution(error: "Preload cancelled", diagnostics: diagnostics)
        }
        
        // 2. Sole Proven Fallback: ANDROID muxed progressive MP4 (itag 18, verified >60s)
        diagnostics.log("VisionOS HLS unavailable — attempting Sole Proven Fallback: Android progressive MP4")
        let androidFallback = await resolveAndroidProgressive(videoId: videoId, session: session)
        if let progressive = androidFallback.progressive {
            diagnostics.log(
                "Fallback progressive mp4 itag=\(progressive.itag ?? 0) \(progressive.height ?? 0)p"
            )
            diagnostics.resolvedUrl = progressive.url.absoluteString
            diagnostics.isSurroundAvailable = false
            diagnostics.isSurroundActive = false
            diagnostics.isUpmixingSelected = true
            diagnostics.audioChannels = 2
            diagnostics.audioStatusDescription = "Stereo 2.0 (Spatial Upmixing)"
            diagnostics.audioRenderingMode = "Spatial Upmixing"
            return PlaybackResolution(
                progressiveURL: progressive.url,
                selectedHeight: progressive.height ?? 360,
                selectedCodec: progressive.codecs,
                durationSeconds: progressive.approxDurationMs.map { $0 / 1000 } ?? 0,
                trackingInfo: androidFallback.tracking,
                diagnostics: diagnostics
            )
        }
        
        diagnostics.failureStage = "No Playable Stream"
        return PlaybackResolution(
            error: diagnostics.primaryPlayabilityReason ?? "Unable to resolve playable video stream",
            requiresAuth: diagnostics.primaryPlayabilityStatus == "LOGIN_REQUIRED",
            diagnostics: diagnostics
        )
    }
    
    /// Resolves native HLS master manifest via YouTube's VisionOS client.
    /// This is empirically verified across full video durations (zero 403 cutoffs).
    nonisolated private static func resolveVisionOSHLS(
        videoId: String,
        session: URLSession,
        diagnostics: inout PlaybackDiagnostics
    ) async -> (
        url: URL,
        filteredMaster: String?,
        subtitlePlaylists: [String: String],
        subtitles: [SubtitleTrack],
        selectedHeight: Int,
        duration: Double,
        tracking: PlaybackTrackingInfo?
    )? {
        guard let watchUrl = URL(string: "https://www.youtube.com/watch?v=\(videoId)&bpctr=9999999999&has_verified=1") else {
            diagnostics.log("VisionOS: Invalid watch URL")
            return nil
        }
        var watchReq = URLRequest(url: watchUrl)
        watchReq.timeoutInterval = 8
        watchReq.setValue("PREF=hl=en&tz=UTC; SOCS=CAI", forHTTPHeaderField: "Cookie")
        watchReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        watchReq.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        
        var visitorData = ""
        var sts = 20702
        
        do {
            let (htmlData, _) = try await session.data(for: watchReq)
            let html = String(decoding: htmlData, as: UTF8.self)
            if let r1 = html.range(of: "\"VISITOR_DATA\":\"") {
                let sub = html[r1.upperBound...]
                if let r2 = sub.range(of: "\"") {
                    visitorData = String(sub[..<r2.lowerBound])
                }
            }
            if let r1 = html.range(of: "\"signatureTimestamp\":") {
                let sub = html[r1.upperBound...]
                let digits = sub.prefix(while: { $0.isNumber })
                if let parsed = Int(digits) {
                    sts = parsed
                }
            }
        } catch {
            diagnostics.log("VisionOS: Watch page fetch error: \(error.localizedDescription)")
        }
        
        guard let playerUrl = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            return nil
        }
        var playerReq = URLRequest(url: playerUrl)
        playerReq.timeoutInterval = 8
        playerReq.httpMethod = "POST"
        playerReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        playerReq.setValue(ua, forHTTPHeaderField: "User-Agent")
        playerReq.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
        playerReq.setValue("1.02", forHTTPHeaderField: "X-YouTube-Client-Version")
        playerReq.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if !visitorData.isEmpty {
            playerReq.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "VISIONOS",
                    "clientVersion": "1.02",
                    "deviceMake": "Apple",
                    "deviceModel": "RealityDevice17,1",
                    "userAgent": ua,
                    "osName": "visionOS",
                    "osVersion": "26.5.23O471",
                    "hl": "en",
                    "timeZone": "UTC",
                    "utcOffsetMinutes": 0
                ]
            ],
            "videoId": videoId,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": sts
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        
        do {
            playerReq.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: playerReq)
            guard let httpRes = response as? HTTPURLResponse else {
                diagnostics.log("VisionOS: No HTTP response")
                return nil
            }
            diagnostics.primaryHttpStatus = httpRes.statusCode
            guard httpRes.statusCode == 200 else {
                diagnostics.log("VisionOS: HTTP \(httpRes.statusCode)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                diagnostics.log("VisionOS: Invalid JSON")
                return nil
            }
            
            if let playability = json["playabilityStatus"] as? [String: Any] {
                let status = playability["status"] as? String ?? ""
                diagnostics.primaryPlayabilityStatus = status
                if status != "OK" {
                    let reason = playability["reason"] as? String ?? "Video unavailable (\(status))"
                    diagnostics.primaryPlayabilityReason = reason
                    diagnostics.log("VisionOS playability: \(status) - \(reason)")
                    return nil
                }
            }
            
            var tracking: PlaybackTrackingInfo? = nil
            if let pt = json["playbackTracking"] as? [String: Any] {
                let pbUrl = (pt["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String
                let wtUrl = (pt["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String
                tracking = PlaybackTrackingInfo(playbackUrl: pbUrl, watchtimeUrl: wtUrl, clientName: "VISIONOS", clientVersion: "1.02")
            }
            
            guard let streamingData = json["streamingData"] as? [String: Any],
                  let hlsUrlStr = streamingData["hlsManifestUrl"] as? String,
                  let hlsUrl = URL(string: hlsUrlStr) else {
                diagnostics.log("VisionOS: No hlsManifestUrl in streamingData")
                return nil
            }
            
            let duration = parseDurationSeconds(json: json, streamingData: streamingData)
            let subtitles = parseCaptionTracks(from: json)
            
            var filteredMaster: String? = nil
            var subPlaylists: [String: String] = [:]
            var selectedHeight = 1080
            
            do {
                var manifestReq = URLRequest(url: hlsUrl)
                manifestReq.timeoutInterval = 8
                manifestReq.setValue(ua, forHTTPHeaderField: "User-Agent")
                let (manifestData, manifestRes) = try await session.data(for: manifestReq)
                if let http = manifestRes as? HTTPURLResponse, http.statusCode == 200 {
                    let rawMaster = String(decoding: manifestData, as: UTF8.self)
                    let allowAV1 = Self.deviceSupportsAV1()
                    if let filtered = TubeLiteResourceLoader.filterHLSMaster(
                        rawMaster,
                        baseURL: hlsUrl,
                        subtitleTracks: subtitles,
                        duration: duration,
                        allowAV1: allowAV1
                    ) {
                        filteredMaster = filtered.playlist
                        subPlaylists = filtered.subtitlePlaylists
                        selectedHeight = filtered.maxHeight
                        diagnostics.log("Filtered VisionOS HLS: \(filtered.variantCount) variants (up to \(filtered.maxHeight)p) · \(subtitles.count) subs")
                        
                        diagnostics.isSurroundAvailable = filtered.surroundAvailable
                        diagnostics.isSurroundActive = filtered.surroundAvailable
                        diagnostics.isUpmixingSelected = !filtered.surroundAvailable
                        diagnostics.audioChannels = filtered.surroundAvailable ? 6 : 2
                        diagnostics.audioStatusDescription = filtered.surroundAvailable
                            ? "5.1 Surround (6ch)"
                            : "Stereo 2.0 (Spatial Upmixing)"
                        diagnostics.audioRenderingMode = filtered.surroundAvailable
                            ? "5.1 Pass-Through"
                            : "Spatial Upmixing"
                    }
                }
            } catch {
                diagnostics.log("VisionOS master manifest fetch warning: \(error.localizedDescription)")
            }
            
            return (
                url: hlsUrl,
                filteredMaster: filteredMaster,
                subtitlePlaylists: subPlaylists,
                subtitles: subtitles,
                selectedHeight: selectedHeight,
                duration: duration,
                tracking: tracking
            )
        } catch {
            diagnostics.log("VisionOS player fetch error: \(error.localizedDescription)")
            return nil
        }
    }
    
    nonisolated private static func deviceSupportsAV1() -> Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
    
    nonisolated private static func pickBestAdaptivePair(
        from streamingData: [String: Any],
        allowAV1: Bool
    ) -> (video: AdaptiveStream, audio: AdaptiveStream)? {
        let parsed = parseCompatibleAdaptiveStreams(from: streamingData, allowAV1: allowAV1)
        guard let video = parsed.videos.first, let audio = parsed.audios.first else { return nil }
        return (video, audio)
    }
    
    nonisolated private static func resolveAndroidProgressive(
        videoId: String,
        session: URLSession
    ) async -> (progressive: AdaptiveStream?, tracking: PlaybackTrackingInfo?) {
        let res = await resolveAndroidStreams(videoId: videoId, session: session, allowAV1: false)
        return (res.progressive, res.tracking)
    }
    
    /// One ANDROID player fetch → best adaptive A/V pair + best muxed progressive.
    nonisolated private static func resolveAndroidStreams(
        videoId: String,
        session: URLSession,
        allowAV1: Bool
    ) async -> (
        adaptive: (video: AdaptiveStream, audio: AdaptiveStream)?,
        progressive: AdaptiveStream?,
        tracking: PlaybackTrackingInfo?
    ) {
        let key = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
        let ver = "20.10.38"
        let ua = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(key)&prettyPrint=false") else {
            return (nil, nil, nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("3", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(ver, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": ver,
                    "androidSdkVersion": 34,
                    "osName": "Android",
                    "osVersion": "14",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streamingData = json["streamingData"] as? [String: Any] else {
                return (nil, nil, nil)
            }
            
            var tracking: PlaybackTrackingInfo? = nil
            if let pt = json["playbackTracking"] as? [String: Any] {
                let pbUrl = (pt["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String
                let wtUrl = (pt["videostatsWatchtimeUrl"] as? [String: Any])?["baseUrl"] as? String
                tracking = PlaybackTrackingInfo(playbackUrl: pbUrl, watchtimeUrl: wtUrl, clientName: "ANDROID", clientVersion: ver)
            }
            
            let adaptive = pickBestAdaptivePair(from: streamingData, allowAV1: allowAV1)
            
            var bestProgressive: AdaptiveStream?
            if let formats = streamingData["formats"] as? [[String: Any]] {
                for format in formats {
                    let mime = (format["mimeType"] as? String)?.lowercased() ?? ""
                    guard mime.contains("avc1"), mime.contains("mp4a"),
                          let streamURL = resolveFormatURL(from: format) else { continue }
                    let approx: Double? = {
                        if let s = format["approxDurationMs"] as? String { return Double(s) }
                        if let n = format["approxDurationMs"] as? Double { return n }
                        if let n = format["approxDurationMs"] as? Int { return Double(n) }
                        return nil
                    }()
                    let candidate = AdaptiveStream(
                        url: streamURL,
                        itag: format["itag"] as? Int,
                        mimeType: format["mimeType"] as? String ?? mime,
                        codecs: extractCodecs(from: format["mimeType"] as? String ?? ""),
                        bandwidth: intValue(format["bitrate"]) ?? 0,
                        averageBitrate: intValue(format["averageBitrate"]),
                        width: intValue(format["width"]),
                        height: intValue(format["height"]),
                        fps: intValue(format["fps"]),
                        approxDurationMs: approx
                    )
                    let candidateH = candidate.height ?? 0
                    let bestH = bestProgressive?.height ?? -1
                    if candidateH > bestH
                        || (candidateH == bestH && candidate.bandwidth > (bestProgressive?.bandwidth ?? 0)) {
                        bestProgressive = candidate
                    }
                }
            }
            return (adaptive, bestProgressive, tracking)
        } catch {
            return (nil, nil, nil)
        }
    }
    
    // MARK: - Adaptive Format Parsing
    
    nonisolated private static let classicAvc1Itags: Set<Int> = [
        160, 133, 134, 135, 136, 137, 264, 266, 298, 299, 304, 305
    ]
    
    nonisolated private static let aacItags: Set<Int> = [139, 140, 141, 256, 258, 327]
    
    private struct AdaptiveParseResult {
        let videos: [AdaptiveStream]
        let audios: [AdaptiveStream]
        let totalAdaptive: Int
        let summary: String
    }
    
    nonisolated public static func parseCaptionTracks(from json: [String: Any]) -> [SubtitleTrack] {
        guard let captions = json["captions"] as? [String: Any],
              let tracklist = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let captionTracks = tracklist["captionTracks"] as? [[String: Any]] else {
            return []
        }
        
        let originalAudioLang: String? = {
            if let details = json["videoDetails"] as? [String: Any] {
                if let lang = details["audioLanguage"] as? String, !lang.isEmpty { return lang.lowercased() }
                if let lang = details["defaultAudioLanguage"] as? String, !lang.isEmpty { return lang.lowercased() }
            }
            return nil
        }()
        
        var tracks: [SubtitleTrack] = []
        for (index, track) in captionTracks.enumerated() {
            guard let urlString = track["baseUrl"] as? String,
                  let url = URL(string: urlString) else {
                continue
            }
            let lang = (track["languageCode"] as? String) ?? "und"
            let vssId = track["vssId"] as? String
            let kind = track["kind"] as? String
            let isAsr = (kind == "asr")
            
            var displayName = ""
            if let nameObj = track["name"] as? [String: Any] {
                if let runs = nameObj["runs"] as? [[String: Any]],
                   let firstRun = runs.first,
                   let text = firstRun["text"] as? String, !text.isEmpty {
                    displayName = text
                } else if let simpleText = nameObj["simpleText"] as? String, !simpleText.isEmpty {
                    displayName = simpleText
                }
            }
            if displayName.isEmpty {
                displayName = Locale.current.localizedString(forIdentifier: lang) ?? lang.uppercased()
                if isAsr {
                    displayName += " (auto-generated)"
                }
            }
            
            let rawId = (vssId ?? "\(lang)_\(index)")
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let safeId = "\(rawId)_\(index)"
            
            tracks.append(SubtitleTrack(
                id: safeId,
                languageCode: lang,
                name: displayName,
                isAutoGenerated: isAsr,
                url: url
            ))
        }
        
        // Priority ordering: English (manual, then asr), then Original Audio (manual, then asr), then remaining
        return tracks.sorted { a, b in
            let aLang = a.languageCode.lowercased()
            let bLang = b.languageCode.lowercased()
            
            let aIsEn = aLang.hasPrefix("en")
            let bIsEn = bLang.hasPrefix("en")
            if aIsEn != bIsEn { return aIsEn }
            
            if aIsEn && bIsEn {
                if a.isAutoGenerated != b.isAutoGenerated {
                    return !a.isAutoGenerated && b.isAutoGenerated
                }
            }
            
            if let orig = originalAudioLang {
                let aIsOrig = aLang.hasPrefix(orig)
                let bIsOrig = bLang.hasPrefix(orig)
                if aIsOrig != bIsOrig { return aIsOrig }
                if aIsOrig && bIsOrig {
                    if a.isAutoGenerated != b.isAutoGenerated {
                        return !a.isAutoGenerated && b.isAutoGenerated
                    }
                }
            }
            
            if a.isAutoGenerated != b.isAutoGenerated {
                return !a.isAutoGenerated && b.isAutoGenerated
            }
            
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    
    nonisolated private static func parseDurationSeconds(json: [String: Any], streamingData: [String: Any]) -> Double {
        if let details = json["videoDetails"] as? [String: Any] {
            if let length = details["lengthSeconds"] as? String, let secs = Double(length), secs > 0 {
                return secs
            }
            if let lengthNum = details["lengthSeconds"] as? Double, lengthNum > 0 {
                return lengthNum
            }
            if let lengthInt = details["lengthSeconds"] as? Int, lengthInt > 0 {
                return Double(lengthInt)
            }
        }
        if let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] {
            for format in adaptive {
                if let ms = format["approxDurationMs"] as? String, let value = Double(ms), value > 0 {
                    return value / 1000.0
                }
                if let msNum = format["approxDurationMs"] as? Double, msNum > 0 {
                    return msNum / 1000.0
                }
                if let msInt = format["approxDurationMs"] as? Int, msInt > 0 {
                    return Double(msInt) / 1000.0
                }
            }
        }
        return 0
    }
    
    nonisolated private static func parseCompatibleAdaptiveStreams(
        from streamingData: [String: Any],
        allowAV1: Bool = false
    ) -> AdaptiveParseResult {
        let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
        
        var videos: [AdaptiveStream] = []
        var rawAudios: [(stream: AdaptiveStream, isOriginal: Bool, isDrc: Bool)] = []
        var skippedCipher = 0
        var skippedIncompatible = 0
        
        for format in adaptive {
            guard let streamURL = resolveFormatURL(from: format) else {
                if format["signatureCipher"] != nil || format["cipher"] != nil {
                    skippedCipher += 1
                }
                continue
            }
            
            let mimeType = (format["mimeType"] as? String) ?? ""
            let mimeLower = mimeType.lowercased()
            let codecs = extractCodecs(from: mimeType) ?? (format["codecs"] as? String)
            let codecsLower = codecs?.lowercased() ?? ""
            let itag = format["itag"] as? Int
            
            let isAvc1 = mimeLower.contains("avc1")
                || codecsLower.contains("avc1")
                || (itag.map { classicAvc1Itags.contains($0) } ?? false)
            let isAV1 = mimeLower.contains("av01") || codecsLower.contains("av01")
            let isMp4a = mimeLower.contains("mp4a")
                || codecsLower.contains("mp4a")
                || (itag.map { aacItags.contains($0) } ?? false)
            let isEac3 = mimeLower.contains("ec-3") || codecsLower.contains("ec-3")
            let isAc3 = mimeLower.contains("ac-3") || codecsLower.contains("ac-3")
            let isSupportedAudio = isMp4a || isEac3 || isAc3
            
            // VP9 / Opus / webm never work in AVPlayer. AV1 only when HW decode exists.
            let isVP9 = mimeLower.contains("vp9") || mimeLower.contains("vp09")
                || codecsLower.contains("vp9") || codecsLower.contains("vp09")
                || mimeLower.contains("webm")
            let isOpus = codecsLower.contains("opus") || mimeLower.contains("opus")
            
            if isVP9 || isOpus || (isAV1 && !allowAV1) {
                skippedIncompatible += 1
                continue
            }
            
            let bitrate = intValue(format["bitrate"])
                ?? intValue(format["averageBitrate"])
                ?? 0
            let averageBitrate = intValue(format["averageBitrate"])
            let width = intValue(format["width"])
            let height = intValue(format["height"])
            let fps = intValue(format["fps"])
            let audioChannels = intValue(format["audioChannels"]) ?? 2
            let approxDurationMs: Double? = {
                if let s = format["approxDurationMs"] as? String { return Double(s) }
                if let n = format["approxDurationMs"] as? Double { return n }
                if let n = format["approxDurationMs"] as? Int { return Double(n) }
                return nil
            }()
            
            let stream = AdaptiveStream(
                url: streamURL,
                itag: itag,
                mimeType: mimeType,
                codecs: codecs,
                bandwidth: bitrate,
                averageBitrate: averageBitrate,
                width: width,
                height: height,
                fps: fps,
                approxDurationMs: approxDurationMs,
                audioChannels: audioChannels
            )
            
            let isVideo = (mimeLower.hasPrefix("video/") || height != nil) && (isAvc1 || (allowAV1 && isAV1))
            if isVideo {
                videos.append(stream)
            } else if (mimeLower.hasPrefix("audio/") || height == nil) && isSupportedAudio {
                let isOriginal = TubeLiteHLSBuilder.isOriginalAudioTrack(format: format)
                let isDrc = (format["isDrc"] as? Bool) == true
                rawAudios.append((stream: stream, isOriginal: isOriginal, isDrc: isDrc))
            } else {
                skippedIncompatible += 1
            }
        }
        
        // Prefer taller first; at same height prefer AV1 over avc1, then bitrate.
        var bestByHeight: [Int: AdaptiveStream] = [:]
        for video in videos {
            let key = video.height ?? 0
            if let existing = bestByHeight[key] {
                let newIsAV1 = (video.codecs ?? video.mimeType).lowercased().contains("av01")
                let oldIsAV1 = (existing.codecs ?? existing.mimeType).lowercased().contains("av01")
                if newIsAV1 != oldIsAV1 {
                    if newIsAV1 { bestByHeight[key] = video }
                } else if video.bandwidth > existing.bandwidth {
                    bestByHeight[key] = video
                }
            } else {
                bestByHeight[key] = video
            }
        }
        let sortedVideos = bestByHeight.values.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        
        // Strictly prioritize original audio tracks, never dubbed
        let originalAudios = rawAudios.filter { $0.isOriginal }
        let eligibleAudios = !originalAudios.isEmpty ? originalAudios : rawAudios
        let sortedAudios = eligibleAudios.sorted { a, b in
            // 1. Prefer 5.1 surround sound (6 channels) over stereo (2 channels)
            let chA = a.stream.audioChannels ?? 2
            let chB = b.stream.audioChannels ?? 2
            if chA != chB { return chA > chB }
            
            // 2. Prefer standard dynamic range (non-DRC)
            if a.isDrc != b.isDrc { return !a.isDrc }
            
            // 3. Prefer higher bitrate
            let ba = a.stream.averageBitrate ?? a.stream.bandwidth
            let bb = b.stream.averageBitrate ?? b.stream.bandwidth
            return ba > bb
        }.map { $0.stream }
        
        let summary = "adaptive=\(adaptive.count) video=\(sortedVideos.count) audio=\(sortedAudios.count) skippedCipher=\(skippedCipher) skippedOther=\(skippedIncompatible) av1Allowed=\(allowAV1)"
        return AdaptiveParseResult(
            videos: sortedVideos,
            audios: sortedAudios,
            totalAdaptive: adaptive.count,
            summary: summary
        )
    }
    
    /// Prefer direct `url`; otherwise unwrap `signatureCipher`/`cipher` query (`url` + `sig`/`signature`).
    nonisolated private static func resolveFormatURL(from format: [String: Any]) -> URL? {
        if let urlStr = format["url"] as? String, let url = URL(string: urlStr) {
            return url
        }
        
        let cipher = (format["signatureCipher"] as? String) ?? (format["cipher"] as? String)
        guard let cipher else { return nil }
        
        var components = URLComponents()
        components.percentEncodedQuery = cipher
        
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                params[item.name] = value
            }
        }
        guard var urlStr = params["url"], !urlStr.isEmpty else { return nil }
        
        if let sig = params["sig"] ?? params["signature"] {
            let separator = urlStr.contains("?") ? "&" : "?"
            urlStr += "\(separator)signature=\(sig)"
        } else if params["s"] != nil {
            // Encrypted `s` requires player JS decryption — unusable here.
            return nil
        }
        
        return URL(string: urlStr)
    }
    
    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }
    
    nonisolated private static func extractCodecs(from mimeType: String) -> String? {
        // e.g. video/mp4; codecs="avc1.640028"
        guard let range = mimeType.range(of: #"codecs="([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let matched = String(mimeType[range])
        guard let open = matched.firstIndex(of: "\""),
              let close = matched.lastIndex(of: "\""),
              open < close else {
            return nil
        }
        let start = matched.index(after: open)
        return String(matched[start..<close])
    }
    
    nonisolated private static func googleAPIErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }
        if let message = error["message"] as? String, !message.isEmpty {
            let status = error["status"] as? String
            return status.map { "\($0): \(message)" } ?? message
        }
        return nil
    }


    
    // MARK: - Browse Home Feed
    
    public func fetchHomeFeed(browseId: String = "FEwhat_to_watch") async {
        isLoading = true
        errorMessage = nil
        homeContinuationToken = nil
        hasBridgedToSubscriptions = false
        
        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/browse"
        guard let url = URL(string: endpoint) else {
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let token = await DeviceAuthService.shared.getValidAccessToken()
        let isAuth = token != nil
        let clientName = isAuth ? "TVHTML5" : "WEB"
        let clientVer = isAuth ? "7.20240901.00.00" : "2.20240901.00.00"
        
        request.setValue(clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVer, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVer,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "browseId": browseId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let feed = try await Self.decodeFeed(from: data)
                self.homeContinuationToken = feed.continuationToken
                self.homeVideos = feed.items
                self.lastHomeFeedAt = Date()

                // Seamless auto-extend via Subscriptions: if signed in and recommendation pool is small (< 12),
                // bridge to latest subscriptions immediately so the TV grid has a rich selection.
                if isAuth && self.homeVideos.count < 12 && !self.hasBridgedToSubscriptions {
                    await self.bridgeToSubscriptions()
                }
            } else if (response as? HTTPURLResponse)?.statusCode == 401 && isAuth {
                print("[TubeLiteTV] 401 received with auth token. Signing out and retrying unauthenticated guest browse.")
                DeviceAuthService.shared.signOut()
                await self.fetchHomeFeedGuest(url: url)
            } else {
                self.errorMessage = "Failed to load home feed (status: \((response as? HTTPURLResponse)?.statusCode ?? 0))"
            }
        } catch {
            self.errorMessage = "Network error: \(error.localizedDescription)"
        }
        
        self.isLoading = false
    }

    private func fetchHomeFeedGuest(url: URL) async {
        var guestRequest = URLRequest(url: url)
        guestRequest.timeoutInterval = 10
        guestRequest.httpMethod = "POST"
        guestRequest.cachePolicy = .reloadIgnoringLocalCacheData
        guestRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guestRequest.setValue("WEB", forHTTPHeaderField: "X-YouTube-Client-Name")
        guestRequest.setValue("2.20240901.00.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        
        let guestPayload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240901.00.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "browseId": "FEwhat_to_watch"
        ]
        
        do {
            guestRequest.httpBody = try JSONSerialization.data(withJSONObject: guestPayload)
            let (data, response) = try await session.data(for: guestRequest)
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let feed = try await Self.decodeFeed(from: data)
                self.homeContinuationToken = feed.continuationToken
                self.homeVideos = feed.items
                self.lastHomeFeedAt = Date()
            } else {
                self.errorMessage = "Failed to load home feed (status: \((response as? HTTPURLResponse)?.statusCode ?? 0))"
            }
        } catch {
            self.errorMessage = "Network error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Infinite Scroll (Load More Home)
    
    public func fetchMoreHomeFeed() async {
        guard !isLoadingMore else { return }
        let token = await DeviceAuthService.shared.getValidAccessToken()
        let isAuth = token != nil

        // If recommendations continuation ran out, seamlessly extend via Subscriptions
        if homeContinuationToken == nil {
            if isAuth && !hasBridgedToSubscriptions {
                isLoadingMore = true
                await bridgeToSubscriptions()
                isLoadingMore = false
            }
            return
        }

        guard let currentContinuationToken = homeContinuationToken else { return }
        isLoadingMore = true
        
        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/browse"
        guard let url = URL(string: endpoint) else {
            isLoadingMore = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let clientName = isAuth ? "TVHTML5" : "WEB"
        let clientVer = isAuth ? "7.20260301.12.00" : "2.20240901.00.00"
        request.setValue(clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVer, forHTTPHeaderField: "X-YouTube-Client-Version")
        
        if isAuth, let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": clientName,
                    "clientVersion": clientVer,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "continuation": currentContinuationToken
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let feed = try await Self.decodeFeed(from: data)
                self.homeContinuationToken = feed.continuationToken
                
                let existingIds = Set(self.homeVideos.map { $0.id })
                let uniqueNew = feed.items.filter { !existingIds.contains($0.id) }
                self.homeVideos.append(contentsOf: uniqueNew)

                // If recommendations continuation just ran out, auto-extend to Subscriptions
                if feed.continuationToken == nil && isAuth && !self.hasBridgedToSubscriptions {
                    await self.bridgeToSubscriptions()
                }
            } else if (response as? HTTPURLResponse)?.statusCode == 401 && isAuth {
                print("[TubeLiteTV] 401 on continuation. Signing out and retrying as unauthenticated guest.")
                DeviceAuthService.shared.signOut()
                var guestRequest = URLRequest(url: url)
                guestRequest.timeoutInterval = 10
                guestRequest.httpMethod = "POST"
                guestRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                guestRequest.setValue("WEB", forHTTPHeaderField: "X-YouTube-Client-Name")
                guestRequest.setValue("2.20240901.00.00", forHTTPHeaderField: "X-YouTube-Client-Version")
                let guestPayload: [String: Any] = [
                    "context": [
                        "client": [
                            "clientName": "WEB",
                            "clientVersion": "2.20240901.00.00",
                            "hl": "en",
                            "gl": "US"
                        ]
                    ],
                    "continuation": currentContinuationToken
                ]
                guestRequest.httpBody = try? JSONSerialization.data(withJSONObject: guestPayload)
                if let (guestData, guestRes) = try? await session.data(for: guestRequest),
                   (guestRes as? HTTPURLResponse)?.statusCode == 200,
                   let guestFeed = try? await Self.decodeFeed(from: guestData) {
                    self.homeContinuationToken = guestFeed.continuationToken
                    let existingIds = Set(self.homeVideos.map { $0.id })
                    let uniqueNew = guestFeed.items.filter { !existingIds.contains($0.id) }
                    self.homeVideos.append(contentsOf: uniqueNew)
                }
            }
        } catch {
            print("[TubeLiteTV] Continuation error: \(error)")
        }
        
        self.isLoadingMore = false
    }

    // MARK: - Auto-Extend via Subscriptions
    
    /// Fetches the authenticated user's Subscriptions feed (`FEsubscriptions`) and appends
    /// its videos to the home screen so the user never encounters a depleted grid.
    public func bridgeToSubscriptions() async {
        guard !hasBridgedToSubscriptions else { return }
        self.hasBridgedToSubscriptions = true
        
        guard let token = await DeviceAuthService.shared.getValidAccessToken() else { return }
        
        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/browse"
        guard let url = URL(string: endpoint) else { return }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TVHTML5", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("7.20260301.12.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "TVHTML5",
                    "clientVersion": "7.20260301.12.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "browseId": "FEsubscriptions"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let feed = try await Self.decodeFeed(from: data)
                let existingIds = Set(self.homeVideos.map { $0.id })
                let uniqueNew = feed.items.filter { !existingIds.contains($0.id) }
                self.homeVideos.append(contentsOf: uniqueNew)
                if self.homeContinuationToken == nil {
                    self.homeContinuationToken = feed.continuationToken
                }
            } else if (response as? HTTPURLResponse)?.statusCode == 401 {
                print("[TubeLiteTV] 401 on bridgeToSubscriptions. Signing out.")
                DeviceAuthService.shared.signOut()
            }
        } catch {
            print("[TubeLiteTV] Bridge to subscriptions failed: \(error)")
        }
    }
    
    // MARK: - Search
    
    public func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.searchResults = []
            return
        }
        
        isLoading = true
        errorMessage = nil
        searchContinuationToken = nil
        
        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/search"
        guard let url = URL(string: endpoint) else {
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WEB", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20240901.00.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240901.00.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "query": query,
            "params": "EgIQAQ=="
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let feed = try await Self.decodeFeed(from: data)
                self.searchContinuationToken = feed.continuationToken
                self.searchResults = feed.items
            } else {
                self.errorMessage = "Search failed"
            }
        } catch {
            self.errorMessage = "Search error: \(error.localizedDescription)"
        }
        
        self.isLoading = false
    }
    
    public func fetchMoreSearchResults() async {
        guard !isLoadingMore, let token = searchContinuationToken else { return }
        isLoadingMore = true
        
        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/search"
        guard let url = URL(string: endpoint) else {
            isLoadingMore = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WEB", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20240901.00.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240901.00.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "continuation": token
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let feed = try await Self.decodeFeed(from: data)
                searchContinuationToken = feed.continuationToken
                let existing = Set(searchResults.map(\.id))
                searchResults.append(contentsOf: feed.items.filter { !existing.contains($0.id) })
            }
        } catch {
            print("[TubeLiteTV] Search continuation error: \(error)")
        }
        
        isLoadingMore = false
    }
    
    // MARK: - Watch Next & Recommendations API
    
    public func fetchWatchNext(videoId: String) async -> (details: VideoItem?, related: [VideoItem]) {
        let endpoint = "\(Self.defaultGatewayUrl)/api/innertube/next"
        guard let url = URL(string: endpoint) else { return (nil, []) }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WEB", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("2.20240901.00.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240901.00.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "videoId": videoId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                let resp = try await Self.decodeWatchNext(from: data)
                return (resp.details, resp.items)
            }
        } catch {
            print("[TubeLiteTV] Watch next error: \(error)")
        }
        
        return (nil, [])
    }
    

    
    // MARK: - SponsorBlock Segments
    
    public struct SponsorSegment: Codable {
        public let start: Double
        public let end: Double
    }
    
    public func fetchSponsorSegments(videoId: String) async -> [SponsorSegment] {
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&categories=%5B%22sponsor%22%2C%22selfpromo%22%2C%22interaction%22%2C%22intro%22%2C%22outro%22%5D") else {
            return []
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            
            return items.compactMap { item in
                guard let seg = item["segment"] as? [Double], seg.count >= 2 else { return nil }
                return SponsorSegment(start: seg[0], end: seg[1])
            }
        } catch {
            return []
        }
    }
    
    // MARK: - Background JSON Decoding
    
    /// Decode FeedResponse off MainActor to avoid blocking the UI thread during JSON parsing.
    nonisolated private static func decodeFeed(from data: Data) async throws -> FeedResponse {
        try JSONDecoder().decode(FeedResponse.self, from: data)
    }
    
    /// Decode WatchNextResponse off MainActor.
    nonisolated private static func decodeWatchNext(from data: Data) async throws -> WatchNextResponse {
        try JSONDecoder().decode(WatchNextResponse.self, from: data)
    }
}
